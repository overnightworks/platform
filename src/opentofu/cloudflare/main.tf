terraform {
  required_version = ">= 1.13.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "= 5.28.0"
    }
  }

  # The command passes the state path outside the checkout at init.
  backend "local" {}
}

variable "api_token_file" {
  type        = string
  description = "The file holding the read-only API token, which the command names and never reads."
}

provider "cloudflare" {
  api_token = sensitive(trimspace(file(var.api_token_file)))
}

data "cloudflare_zone" "hallucinai" {
  filter = {
    name = "hallucinai.de"
  }
}

# The data source carries the deprecated `connections`, whose origin_ip is the public address of the host running
# cloudflared; it lands in the state and in the kept plan, both 0600 under the operator's home.
data "cloudflare_zero_trust_tunnel_cloudflared" "platform" {
  account_id = data.cloudflare_zone.hallucinai.account.id
  filter = {
    name       = "platform"
    is_deleted = false
  }
}
