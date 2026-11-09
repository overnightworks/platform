# tofu test cannot plan a resource an import block names, so each run plans the module that holds the resources.
# Proves docs/github-settings.md GH-1, GH-2.
mock_provider "github" {}

run "the_quality_ruleset_requires_the_exact_check_pinned_to_github_actions" {
  command = plan

  module {
    source = "./organization"
  }

  assert {
    condition     = one(github_organization_ruleset.quality_verdict_required.rules[0].required_status_checks[0].required_check).context == "quality / verdict"
    error_message = "The required check must be exactly `quality / verdict`, with no pattern."
  }

  assert {
    condition     = one(github_organization_ruleset.quality_verdict_required.rules[0].required_status_checks[0].required_check).integration_id == 15368
    error_message = "The required check must be pinned to GitHub Actions."
  }
}

run "the_quality_ruleset_reaches_repositories_only_through_the_quality_gate_property" {
  command = plan

  module {
    source = "./organization"
  }

  assert {
    condition     = length(github_organization_ruleset.quality_verdict_required.conditions[0].repository_property) == 1 && length(github_organization_ruleset.quality_verdict_required.conditions[0].repository_property[0].include) == 1
    error_message = "The ruleset must have exactly one property inclusion."
  }

  assert {
    condition = (
      github_organization_ruleset.quality_verdict_required.conditions[0].repository_property[0].include[0].name == "quality_gate"
      && github_organization_ruleset.quality_verdict_required.conditions[0].repository_property[0].include[0].source == "custom"
      && github_organization_ruleset.quality_verdict_required.conditions[0].repository_property[0].include[0].property_values == tolist(["true"])
    )
    error_message = "The ruleset must include repositories with the custom property quality_gate set to true."
  }

  assert {
    condition     = github_organization_ruleset.quality_verdict_required.conditions[0].repository_property[0].exclude == null || length(github_organization_ruleset.quality_verdict_required.conditions[0].repository_property[0].exclude) == 0
    error_message = "The property condition must have no exclusion."
  }

  assert {
    condition = (
      (github_organization_ruleset.quality_verdict_required.conditions[0].repository_name == null || length(github_organization_ruleset.quality_verdict_required.conditions[0].repository_name) == 0)
      && (github_organization_ruleset.quality_verdict_required.conditions[0].repository_id == null || length(github_organization_ruleset.quality_verdict_required.conditions[0].repository_id) == 0)
    )
    error_message = "The ruleset must not target by repository name or id."
  }
}

run "the_quality_property_schema_is_true_false_and_editable_by_organisation_actors" {
  command = plan

  module {
    source = "./organization"
  }

  assert {
    condition     = github_organization_custom_properties.quality_gate.property_name == "quality_gate"
    error_message = "The schema must be the property quality_gate."
  }

  assert {
    condition     = github_organization_custom_properties.quality_gate.value_type == "true_false"
    error_message = "The property must be true_false."
  }

  assert {
    condition     = github_organization_custom_properties.quality_gate.values_editable_by == "org_actors"
    error_message = "Organisation actors must edit the property's values."
  }
}

run "no_organisation_ruleset_has_a_bypass_actor" {
  command = plan

  module {
    source = "./organization"
  }

  assert {
    condition = alltrue([
      for ruleset in [
        github_organization_ruleset.main_pull_request_only,
        github_organization_ruleset.quality_verdict_required,
        github_organization_ruleset.release_tags_immutable,
      ] : ruleset.bypass_actors == null || length(ruleset.bypass_actors) == 0
    ])
    error_message = "A ruleset must have an empty bypass list."
  }
}

run "every_organisation_ruleset_is_enforced" {
  command = plan

  module {
    source = "./organization"
  }

  assert {
    condition = alltrue([
      for ruleset in [
        github_organization_ruleset.main_pull_request_only,
        github_organization_ruleset.quality_verdict_required,
        github_organization_ruleset.release_tags_immutable,
      ] : ruleset.enforcement == "active"
    ])
    error_message = "Every ruleset must be active."
  }
}

run "the_pull_request_ruleset_requires_no_approving_review" {
  command = plan

  module {
    source = "./organization"
  }

  assert {
    condition     = github_organization_ruleset.main_pull_request_only.rules[0].pull_request[0].required_approving_review_count == 0
    error_message = "The approval count must stay 0: provider 6.13.0 cannot carry require_extra_approval_for_unattributed_changes, which GitHub holds as true and which takes effect only at a non-zero count."
  }
}
