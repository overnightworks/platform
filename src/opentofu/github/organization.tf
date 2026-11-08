# The importer recovers a lost state; an import of an id that does not exist fails the plan, so nothing is created.
import {
  to = github_organization_ruleset.main_pull_request_only
  id = "25224011"
}

import {
  to = github_organization_ruleset.quality_verdict_required
  id = "25227067"
}

import {
  to = github_organization_ruleset.release_tags_immutable
  id = "25224012"
}

import {
  to = github_organization_custom_properties.quality_gate
  id = "quality_gate"
}

locals {
  # The contract with quality's gate, read by the resources below and by the tests: tofu test cannot plan an imported
  # resource, so these locals are what the test can judge.
  quality_gate_property = "quality_gate"
  quality_verdict_check = {
    context = "quality / verdict"
    # gate.yml is the one producer of the check, so it is pinned to GitHub Actions (app id 15368).
    integration_id = 15368
  }

  # quality's merge command is the one deliberate way past a ruleset, so no actor bypasses any of them.
  ruleset_bypass_actors = []
  ruleset_enforcement   = "active"
}

# Only the schema is declared: quality's merge command sets the value per repository, so a value is never planned here.
# The `role` property of the same schema is not part of this root and stays as set on GitHub.
# The default value (false) is not declared: the provider reads none for a true_false property, so declaring it plans
# a change to what GitHub already holds.
resource "github_organization_custom_properties" "quality_gate" {
  property_name      = local.quality_gate_property
  value_type         = "true_false"
  required           = true
  description        = "true: the repository runs the quality gate and must pass quality / verdict."
  values_editable_by = "org_actors"
}

resource "github_organization_ruleset" "main_pull_request_only" {
  name        = "main: PR only (all repositories)"
  target      = "branch"
  enforcement = local.ruleset_enforcement

  dynamic "bypass_actors" {
    for_each = local.ruleset_bypass_actors

    content {
      actor_type  = bypass_actors.value.actor_type
      actor_id    = bypass_actors.value.actor_id
      bypass_mode = bypass_actors.value.bypass_mode
    }
  }

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
  }
}

resource "github_organization_ruleset" "quality_verdict_required" {
  name        = "quality / verdict required"
  target      = "branch"
  enforcement = local.ruleset_enforcement

  dynamic "bypass_actors" {
    for_each = local.ruleset_bypass_actors

    content {
      actor_type  = bypass_actors.value.actor_type
      actor_id    = bypass_actors.value.actor_id
      bypass_mode = bypass_actors.value.bypass_mode
    }
  }

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
    repository_property {
      include = [{
        name            = local.quality_gate_property
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
        context        = local.quality_verdict_check.context
        integration_id = local.quality_verdict_check.integration_id
      }
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "github_organization_ruleset" "release_tags_immutable" {
  name        = "release tags are immutable (all repositories)"
  target      = "tag"
  enforcement = local.ruleset_enforcement

  dynamic "bypass_actors" {
    for_each = local.ruleset_bypass_actors

    content {
      actor_type  = bypass_actors.value.actor_type
      actor_id    = bypass_actors.value.actor_id
      bypass_mode = bypass_actors.value.bypass_mode
    }
  }

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
  }
}

# What the rulesets read, so a test can judge it without planning an import, which tofu test cannot do. The
# dependency keeps the output in a plan that targets only that read.
output "organisation_contract" {
  depends_on = [data.github_user.current]

  value = {
    quality_gate_property = local.quality_gate_property
    quality_verdict_check = local.quality_verdict_check
    bypass_actors         = local.ruleset_bypass_actors
    enforcement           = local.ruleset_enforcement
  }
}
