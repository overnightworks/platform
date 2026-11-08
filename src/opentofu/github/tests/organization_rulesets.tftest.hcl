# tofu test cannot import, so it cannot plan the rulesets themselves: each run plans only the data source and judges
# the locals the rulesets read.
mock_provider "github" {}

run "the_quality_check_is_required_by_exact_name_and_pinned_to_github_actions" {
  command = plan

  plan_options {
    target = [data.github_user.current]
  }

  assert {
    condition     = output.organisation_contract.quality_verdict_check.context == "quality / verdict"
    error_message = "The required check must be exactly `quality / verdict`, with no pattern."
  }

  assert {
    condition     = output.organisation_contract.quality_verdict_check.integration_id == 15368
    error_message = "The required check must be pinned to GitHub Actions."
  }
}

run "the_quality_property_has_the_schema_the_ruleset_targets_by" {
  command = plan

  plan_options {
    target = [data.github_user.current]
  }

  assert {
    condition     = output.organisation_contract.quality_gate_property == "quality_gate"
    error_message = "The ruleset must target repositories by the quality_gate property."
  }
}

run "no_organisation_ruleset_has_a_bypass_actor" {
  command = plan

  plan_options {
    target = [data.github_user.current]
  }

  assert {
    condition     = length(output.organisation_contract.bypass_actors) == 0
    error_message = "A ruleset must have an empty bypass list."
  }
}

run "every_organisation_ruleset_is_enforced" {
  command = plan

  plan_options {
    target = [data.github_user.current]
  }

  assert {
    condition     = output.organisation_contract.enforcement == "active"
    error_message = "Every ruleset must be active."
  }
}
