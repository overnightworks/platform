# Proves docs/cloudflare-zone.md: the root declares the zone's HSTS and NEL settings. They are the resources of a module,
# since tofu test cannot plan a resource an import block names.
mock_provider "cloudflare" {}

variables {
  zone_id = "00000000000000000000000000000001"
}

run "hsts_meets_what_the_preload_list_requires" {
  command = plan

  module {
    source = "./settings"
  }

  assert {
    condition     = cloudflare_zone_setting.hsts.zone_id == var.zone_id && cloudflare_zone_setting.hsts.setting_id == "security_header"
    error_message = "HSTS is not the zone's security_header setting."
  }

  assert {
    condition = (
      cloudflare_zone_setting.hsts.value.strict_transport_security.enabled
      && cloudflare_zone_setting.hsts.value.strict_transport_security.include_subdomains
      && cloudflare_zone_setting.hsts.value.strict_transport_security.preload
      && cloudflare_zone_setting.hsts.value.strict_transport_security.max_age >= 31536000
    )
    error_message = "HSTS does not meet the preload list's requirements."
  }
}

run "network_error_logging_is_off" {
  command = plan

  module {
    source = "./settings"
  }

  assert {
    condition     = cloudflare_zone_setting.nel.zone_id == var.zone_id && cloudflare_zone_setting.nel.setting_id == "nel"
    error_message = "NEL is not the zone's nel setting."
  }

  assert {
    condition     = cloudflare_zone_setting.nel.value.enabled == false
    error_message = "Network Error Logging is on."
  }
}
