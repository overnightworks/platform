# The environment that holds the release App's private key. It declares no secret: `mise run release:create-app` stores
# the key, and only a job on main may read it.
resource "github_repository_environment" "release_bump" {
  repository  = "platform"
  environment = "release-bump"

  can_admins_bypass = true

  deployment_branch_policy {
    protected_branches     = false
    custom_branch_policies = true
  }

  lifecycle {
    prevent_destroy = true
    destroy         = false
  }
}

# The one policy: custom policies admit no branch without one, and "protected branches only" would admit every branch of
# a repository without classic branch protection.
resource "github_repository_environment_deployment_policy" "release_bump_main" {
  repository     = "platform"
  environment    = github_repository_environment.release_bump.environment
  branch_pattern = "main"

  lifecycle {
    prevent_destroy = true
    destroy         = false
  }
}
