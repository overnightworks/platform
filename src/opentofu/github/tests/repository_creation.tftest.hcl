# tofu test cannot run import blocks, so the run plans only the two resources of the one name that has none.
mock_provider "github" {}

run "a_repository_to_create_is_public_with_issues_and_a_first_commit" {
  command = plan

  plan_options {
    target = [
      github_repository.managed["figure"],
      github_repository_vulnerability_alerts.managed["figure"],
    ]
  }

  override_data {
    target = data.github_rest_api.organisation_repositories
    values = {
      code    = 200
      headers = "{}"
      body    = <<-JSON
        [
          {"name": "aco", "archived": false, "private": false, "fork": false},
          {"name": "agents", "archived": false, "private": false, "fork": false},
          {"name": "design", "archived": false, "private": false, "fork": false},
          {"name": "hal", "archived": false, "private": false, "fork": false},
          {"name": "hopin", "archived": false, "private": false, "fork": false},
          {"name": "marketplace", "archived": false, "private": false, "fork": false},
          {"name": "personas", "archived": false, "private": false, "fork": false},
          {"name": "platform", "archived": false, "private": false, "fork": false},
          {"name": "platform-secrets", "archived": false, "private": true, "fork": false},
          {"name": "presentator", "archived": false, "private": false, "fork": false},
          {"name": "quality", "archived": false, "private": false, "fork": false},
          {"name": "skat", "archived": false, "private": false, "fork": false},
          {"name": "songmaker", "archived": false, "private": false, "fork": false},
          {"name": "speech", "archived": false, "private": false, "fork": false},
          {"name": "webauth", "archived": false, "private": false, "fork": false},
          {"name": "ACE-Step-1.5", "archived": false, "private": false, "fork": true},
          {"name": "retired-project", "archived": true, "private": false, "fork": false}
        ]
      JSON
    }
  }

  assert {
    condition     = github_repository.managed["figure"].visibility == "public"
    error_message = "A created repository must be public."
  }

  assert {
    condition     = github_repository.managed["figure"].has_issues && github_repository.managed["figure"].auto_init
    error_message = "A created repository must have issues and a first commit."
  }

  assert {
    condition     = github_repository.managed["figure"].description == local.created["figure"]
    error_message = "A created repository must carry the description of created."
  }

  assert {
    condition = (
      github_repository.managed["figure"].security_and_analysis[0].secret_scanning[0].status == "enabled" &&
      github_repository.managed["figure"].security_and_analysis[0].secret_scanning_push_protection[0].status == "enabled"
    )
    error_message = "A created public repository must have secret scanning and push protection."
  }

  assert {
    condition     = github_repository_vulnerability_alerts.managed["figure"].enabled
    error_message = "A created repository must have Dependabot alerts."
  }
}
