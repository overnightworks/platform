# Proves docs/cloudflare-zone.md: the tunnel is looked up in the zone's account. tofu test cannot plan a resource an
# import block names, so the run plans only the lookup.
mock_provider "cloudflare" {}

variables {
  api_token_file = "tests/synthetic_token.txt"
}

run "the_tunnel_is_looked_up_in_the_account_of_the_zone" {
  command = plan

  plan_options {
    target = [data.cloudflare_zero_trust_tunnel_cloudflared.platform]
  }

  override_data {
    target = data.cloudflare_zone.hallucinai
    values = {
      id      = "00000000000000000000000000000001"
      account = { id = "00000000000000000000000000000002", name = "synthetic account" }
    }
  }

  override_data {
    target = data.cloudflare_zero_trust_tunnel_cloudflared.platform
    values = {
      id = "00000000-0000-0000-0000-000000000003"
    }
  }

  assert {
    condition     = data.cloudflare_zero_trust_tunnel_cloudflared.platform.account_id == data.cloudflare_zone.hallucinai.account.id
    error_message = "The tunnel is not looked up in the zone's account."
  }
}
