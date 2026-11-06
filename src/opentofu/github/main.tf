terraform {
  required_version = ">= 1.13.0"

  required_providers {
    github = {
      source  = "integrations/github"
      version = "= 6.13.0"
    }
  }

  # The command passes the state path outside the checkout at init.
  backend "local" {}
}

provider "github" {
  owner = "overnightworks"
}

# Fails without a token, so a plan never renders as anonymous.
data "github_user" "current" {
  username = ""
}
