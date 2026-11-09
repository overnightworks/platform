locals {
  # Every non-archived non-fork repository of the organisation.
  managed = toset([
    "aco",
    "agents",
    "design",
    "hal",
    "hopin",
    "marketplace",
    "personas",
    "platform",
    "platform-secrets",
    "presentator",
    "quality",
    "skat",
    "songmaker",
    "speech",
    "webauth",
  ])

  # Listed repositories outside the contract, each with its reason.
  unmanaged = {
    "ACE-Step-1.5" = "a vendor fork that follows its upstream, not the fleet"
  }

  # Repositories this configuration creates, each with its description; a name moves to managed once it exists.
  created = {
    "figure" = "The fleet's VRM 1.0 profile, its check command and a browser library that draws and drives a figure."
  }

  declared = setunion(local.managed, keys(local.created))
}

# The importer recovers a lost state; an import of a name that does not exist fails the plan, so a name in managed is never created; only a name in created is.
import {
  for_each = local.managed
  to       = github_repository.managed[each.key]
  id       = each.key
}

import {
  for_each = local.managed
  to       = github_repository_vulnerability_alerts.managed[each.key]
  id       = each.key
}

resource "github_repository" "managed" {
  for_each = local.declared

  name                   = each.key
  description            = lookup(local.created, each.key, null)
  visibility             = contains(keys(local.created), each.key) ? "public" : null
  has_issues             = contains(keys(local.created), each.key) ? true : null
  auto_init              = contains(keys(local.created), each.key) ? true : null
  has_wiki               = contains(keys(local.created), each.key) ? true : null
  has_projects           = contains(keys(local.created), each.key) ? true : null
  allow_merge_commit     = false
  allow_squash_merge     = true
  allow_rebase_merge     = false
  delete_branch_on_merge = true
  archive_on_destroy     = true

  depends_on = [data.github_user.current]

  # Secret scanning and push protection on a private repository need paid GitHub Secret Protection, so a private one
  # relies on the free checks at commit and in CI instead. Visibility is read from the listing, where GitHub owns it.
  dynamic "security_and_analysis" {
    for_each = contains(local.listed_private, each.key) ? [] : [1]

    content {
      secret_scanning {
        status = "enabled"
      }
      secret_scanning_push_protection {
        status = "enabled"
      }
    }
  }

  lifecycle {
    # A key removed from managed is forgotten, never destroyed, so the repository stays on GitHub.
    destroy = false
    # The resource plans every unset attribute back to its default, so whatever the contract does not hold stays as set on GitHub.
    ignore_changes = [
      allow_auto_merge,
      allow_forking,
      allow_update_branch,
      archived,
      auto_init,
      default_branch,
      description,
      gitignore_template,
      has_discussions,
      has_downloads,
      has_issues,
      has_projects,
      has_wiki,
      homepage_url,
      ignore_vulnerability_alerts_during_read,
      is_template,
      license_template,
      merge_commit_message,
      merge_commit_title,
      pages,
      private,
      squash_merge_commit_message,
      squash_merge_commit_title,
      template,
      topics,
      visibility,
      vulnerability_alerts,
      web_commit_signoff_required,
    ]
  }
}

resource "github_repository_vulnerability_alerts" "managed" {
  for_each = local.declared

  repository = github_repository.managed[each.key].name
  enabled    = true

  lifecycle {
    # Disabling the alerts is a change to the repository, so a removed key leaves them as set.
    destroy = false
  }
}

data "github_rest_api" "organisation_repositories" {
  endpoint = "orgs/overnightworks/repos?per_page=100"
}

locals {
  # The data source stores an error response as success, so nothing is decoded unless the read returned 200;
  # a decoding error would print the response.
  listing_read = data.github_rest_api.organisation_repositories.code == 200
  listing      = jsondecode(local.listing_read ? data.github_rest_api.organisation_repositories.body : "[]")
  link_header  = join(",", lookup(jsondecode(local.listing_read ? data.github_rest_api.organisation_repositories.headers : "{}"), "Link", []))

  listing_judgeable       = local.listing_read && !strcontains(local.link_header, "rel=\"next\"")
  listed_names            = toset([for repository in local.listing : repository.name])
  listed_active           = toset([for repository in local.listing : repository.name if !repository.archived])
  listed_manageable       = toset([for repository in local.listing : repository.name if !repository.archived && !repository.fork])
  listed_private          = toset([for repository in local.listing : repository.name if repository.private])
  undeclared_repositories = sort(setsubtract(local.listed_active, setunion(local.declared, keys(local.unmanaged))))
  unmanageable_names      = sort(setsubtract(local.managed, local.listed_manageable))
  already_listed_created  = sort(setintersection(keys(local.created), local.listed_names))
}

# The conditions reference only names and flags, because a failed condition prints every value it references.
output "managed_repositories" {
  value = sort(tolist(local.declared))

  precondition {
    condition     = local.listing_judgeable
    error_message = "Cannot judge the organisation listing: it was not read with status 200 or it has a next page."
  }

  precondition {
    condition     = !local.listing_judgeable || length(local.undeclared_repositories) == 0
    error_message = "Listed repositories declared in neither managed nor unmanaged: ${join(", ", local.undeclared_repositories)}."
  }

  precondition {
    condition     = !local.listing_judgeable || length(local.unmanageable_names) == 0
    error_message = "Managed repositories not listed, archived or a fork: ${join(", ", local.unmanageable_names)}."
  }

  precondition {
    condition     = !local.listing_judgeable || length(local.already_listed_created) == 0
    error_message = "Repositories in created that the listing already holds, so move them to managed: ${join(", ", local.already_listed_created)}."
  }
}
