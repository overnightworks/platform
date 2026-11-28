# tofu test cannot run import blocks, so the run plans only the environment and its one policy.
# Proves docs/github-settings.md GH-8.
mock_provider "github" {}

run "the_environment_admits_only_the_branch_main_under_custom_policies" {
  command = plan

  plan_options {
    target = [
      github_repository_environment.release_bump,
      github_repository_environment_deployment_policy.release_bump_main,
    ]
  }

  assert {
    condition = (
      length(github_repository_environment.release_bump.deployment_branch_policy) == 1
      && github_repository_environment.release_bump.deployment_branch_policy[0].custom_branch_policies
      && !github_repository_environment.release_bump.deployment_branch_policy[0].protected_branches
    )
    error_message = "The environment must admit branches by custom policies and never by branch protection."
  }

  assert {
    condition = (
      github_repository_environment_deployment_policy.release_bump_main.environment == github_repository_environment.release_bump.environment
      && github_repository_environment_deployment_policy.release_bump_main.repository == github_repository_environment.release_bump.repository
      && github_repository_environment_deployment_policy.release_bump_main.branch_pattern == "main"
      && github_repository_environment_deployment_policy.release_bump_main.tag_pattern == null
    )
    error_message = "The policy must belong to the environment and admit the branch main and no tag."
  }
}
