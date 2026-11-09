terraform {
  required_version = ">= 1.13.0"

  required_providers {
    github = {
      source = "integrations/github"
    }
  }
}

# Only the schema is declared: quality's merge command sets the value per repository, so a value is never planned here.
# The `role` property of the same schema is not part of this module and stays as set on GitHub.
# Limit of provider 6.13.0: it returns no default for a true_false property, so the default (false) is not declared and a
# later update of this resource would send an empty one, with GitHub's answer unknown. Drift detection does not see it.
resource "github_organization_custom_properties" "quality_gate" {
  property_name      = "quality_gate"
  value_type         = "true_false"
  required           = true
  description        = "true: the repository runs the quality gate and must pass quality / verdict."
  values_editable_by = "org_actors"

  lifecycle {
    destroy = false
  }
}

# Limit of provider 6.13.0: it cannot carry `require_extra_approval_for_unattributed_changes`, which is true on GitHub.
# Import and apply leave it alone, a later update sends it not at all, and whether GitHub then keeps it is unknown.
# It takes effect only at a non-zero approval count, which stays 0 (the test holds it there); raising the count needs a
# provider release that carries the field first.
resource "github_organization_ruleset" "main_pull_request_only" {
  name        = "main: PR only (all repositories)"
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
    repository_name {
      include = ["~ALL"]
      exclude = []
    }
  }

  rules {
    deletion         = true
    non_fast_forward = true

    pull_request {
      required_approving_review_count = 0
      allowed_merge_methods           = ["merge", "squash", "rebase"]
    }
  }

  lifecycle {
    prevent_destroy = true
    destroy         = false
  }
}

# quality's merge command is the one deliberate way past a ruleset, so no ruleset has a bypass actor.
resource "github_organization_ruleset" "quality_verdict_required" {
  name        = "quality / verdict required"
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
    repository_property {
      include = [{
        name            = github_organization_custom_properties.quality_gate.property_name
        source          = "custom"
        property_values = ["true"]
      }]
    }
  }

  rules {
    deletion         = true
    non_fast_forward = true

    required_status_checks {
      required_check {
        context = "quality / verdict"
        # gate.yml is the one producer of the check, so it is pinned to GitHub Actions (app id 15368).
        integration_id = 15368
      }
    }
  }

  lifecycle {
    prevent_destroy = true
    destroy         = false
  }
}

resource "github_organization_ruleset" "release_tags_immutable" {
  name        = "release tags are immutable (all repositories)"
  target      = "tag"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["refs/tags/v*"]
      exclude = []
    }
    repository_name {
      include = ["~ALL"]
      exclude = []
    }
  }

  rules {
    deletion         = true
    update           = true
    non_fast_forward = true
  }

  lifecycle {
    prevent_destroy = true
    destroy         = false
  }
}

# Only platform-secrets carries the value: it holds encrypted files and no code to scan, and private code scanning is paid.
# Without a value a repository does not match the exclusion, so no default is declared (provider 6.13.0 reads none for
# a true_false property); only organisation actors edit a value, so no repository admin can exempt a repository.
resource "github_organization_custom_properties" "code_scanning_exempt" {
  property_name      = "code_scanning_exempt"
  value_type         = "true_false"
  required           = false
  description        = "true: the repository holds no code to scan and is outside the ruleset code scanning: high or higher blocks the merge."
  values_editable_by = "org_actors"

  lifecycle {
    destroy = false
  }
}

resource "github_repository_custom_property" "platform_secrets_code_scanning_exempt" {
  repository     = "platform-secrets"
  property_name  = github_organization_custom_properties.code_scanning_exempt.property_name
  property_type  = github_organization_custom_properties.code_scanning_exempt.value_type
  property_value = ["true"]

  lifecycle {
    destroy = false
  }
}

resource "github_organization_ruleset" "code_scanning_required" {
  name        = "code scanning: high or higher blocks the merge"
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
    repository_property {
      include = [{
        name            = github_organization_custom_properties.quality_gate.property_name
        source          = "custom"
        property_values = ["true"]
      }]
      # The value is referenced, not the schema, so the ruleset is created only after platform-secrets carries it.
      exclude = [{
        name            = github_repository_custom_property.platform_secrets_code_scanning_exempt.property_name
        source          = "custom"
        property_values = tolist(github_repository_custom_property.platform_secrets_code_scanning_exempt.property_value)
      }]
    }
  }

  rules {
    required_code_scanning {
      required_code_scanning_tool {
        tool                      = "CodeQL"
        security_alerts_threshold = "high_or_higher"
        alerts_threshold          = "none"
      }
    }
  }

  lifecycle {
    prevent_destroy = true
    destroy         = false
  }
}
