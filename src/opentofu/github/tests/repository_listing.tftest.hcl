# tofu test cannot run import blocks, so each run plans only the listing and the conditions on it.
# Proves docs/github-settings.md GH-1.
mock_provider "github" {}

run "a_listing_that_agrees_with_the_declarations_passes" {
  command = plan

  plan_options {
    target = [data.github_rest_api.organisation_repositories]
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
          {"name": "figure", "archived": false, "private": false, "fork": false},
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
}

run "an_unmanaged_repository_listed_as_public_and_not_a_fork_passes" {
  command = plan

  plan_options {
    target = [data.github_rest_api.organisation_repositories]
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
          {"name": "figure", "archived": false, "private": false, "fork": false},
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
          {"name": "scratch-landing-drive", "archived": false, "private": false, "fork": false}
        ]
      JSON
    }
  }
}

run "an_undeclared_listed_repository_fails" {
  command = plan

  plan_options {
    target = [data.github_rest_api.organisation_repositories]
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
          {"name": "figure", "archived": false, "private": false, "fork": false},
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
          {"name": "undeclared", "archived": false, "private": false, "fork": false}
        ]
      JSON
    }
  }

  expect_failures = [output.managed_repositories]
}

run "a_managed_repository_missing_from_the_listing_fails" {
  command = plan

  plan_options {
    target = [data.github_rest_api.organisation_repositories]
  }

  override_data {
    target = data.github_rest_api.organisation_repositories
    values = {
      code    = 200
      headers = "{}"
      body    = <<-JSON
        [
          {"name": "agents", "archived": false, "private": false, "fork": false},
          {"name": "design", "archived": false, "private": false, "fork": false},
          {"name": "figure", "archived": false, "private": false, "fork": false},
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
          {"name": "ACE-Step-1.5", "archived": false, "private": false, "fork": true}
        ]
      JSON
    }
  }

  expect_failures = [output.managed_repositories]
}

run "a_managed_repository_listed_as_archived_fails" {
  command = plan

  plan_options {
    target = [data.github_rest_api.organisation_repositories]
  }

  override_data {
    target = data.github_rest_api.organisation_repositories
    values = {
      code    = 200
      headers = "{}"
      body    = <<-JSON
        [
          {"name": "aco", "archived": true, "private": false, "fork": false},
          {"name": "agents", "archived": false, "private": false, "fork": false},
          {"name": "design", "archived": false, "private": false, "fork": false},
          {"name": "figure", "archived": false, "private": false, "fork": false},
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
          {"name": "ACE-Step-1.5", "archived": false, "private": false, "fork": true}
        ]
      JSON
    }
  }

  expect_failures = [output.managed_repositories]
}

run "a_managed_repository_listed_as_a_fork_fails" {
  command = plan

  plan_options {
    target = [data.github_rest_api.organisation_repositories]
  }

  override_data {
    target = data.github_rest_api.organisation_repositories
    values = {
      code    = 200
      headers = "{}"
      body    = <<-JSON
        [
          {"name": "aco", "archived": false, "private": false, "fork": true},
          {"name": "agents", "archived": false, "private": false, "fork": false},
          {"name": "design", "archived": false, "private": false, "fork": false},
          {"name": "figure", "archived": false, "private": false, "fork": false},
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
          {"name": "ACE-Step-1.5", "archived": false, "private": false, "fork": true}
        ]
      JSON
    }
  }

  expect_failures = [output.managed_repositories]
}

run "a_listing_with_a_next_page_cannot_be_judged" {
  command = plan

  plan_options {
    target = [data.github_rest_api.organisation_repositories]
  }

  override_data {
    target = data.github_rest_api.organisation_repositories
    values = {
      code    = 200
      headers = "{\"Link\": [\"<https://api.github.com/organizations/1/repos?per_page=100&page=2>; rel=\\\"next\\\"\"]}"
      body    = <<-JSON
        [
          {"name": "aco", "archived": false, "private": false, "fork": false},
          {"name": "agents", "archived": false, "private": false, "fork": false},
          {"name": "design", "archived": false, "private": false, "fork": false},
          {"name": "figure", "archived": false, "private": false, "fork": false},
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
          {"name": "ACE-Step-1.5", "archived": false, "private": false, "fork": true}
        ]
      JSON
    }
  }

  expect_failures = [output.managed_repositories]
}

run "a_listing_read_without_status_200_cannot_be_judged" {
  command = plan

  plan_options {
    target = [data.github_rest_api.organisation_repositories]
  }

  override_data {
    target = data.github_rest_api.organisation_repositories
    values = {
      code    = 404
      headers = "{}"
      body    = "{\"message\": \"Not Found\"}"
    }
  }

  expect_failures = [output.managed_repositories]
}
