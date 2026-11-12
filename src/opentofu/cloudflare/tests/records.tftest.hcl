# Proves docs/cloudflare-zone.md: the root declares one proxied CNAME to the platform's tunnel for each hostname of the
# tunnel's lines and for the redirected names (the apex and www), adopts a live single CNAME by import and never creates a second one.
mock_provider "cloudflare" {}

variables {
  api_token_file    = "tests/synthetic_token.txt"
  tunnel_lines_file = "tests/hosts_two.yaml"
}

# A record in a lookup carries every attribute of the provider's schema; the runs set only what they read.
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

run "each_hostname_of_the_file_and_the_redirected_names_get_a_proxied_cname_to_the_tunnel" {
  command = plan

  plan_options {
    target = [cloudflare_dns_record.host]
  }

  # The records wait for the rulesets, whose facts judge the hostnames of the file, so this run reads the shipped one.
  variables {
    tunnel_lines_file = "../../../infrastructure/cloudflared/config.yaml"
  }

  assert {
    condition = toset(keys(cloudflare_dns_record.host)) == toset(concat(
      [for rule in yamldecode(file("../../../infrastructure/cloudflared/config.yaml")).ingress : rule.hostname if contains(keys(rule), "hostname")],
      local.redirect.hostnames
    ))
    error_message = "The records are not the file's hostnames and the redirected names."
  }

  assert {
    condition = alltrue([
      for record in values(cloudflare_dns_record.host) :
      record.type == "CNAME" && record.proxied && record.content == "${data.cloudflare_zero_trust_tunnel_cloudflared.platform.id}.cfargotunnel.com"
    ])
    error_message = "A record is not a proxied CNAME to the platform tunnel."
  }

  assert {
    condition     = alltrue([for record in values(cloudflare_dns_record.host) : record.zone_id == data.cloudflare_zone.hallucinai.id])
    error_message = "A record is not in the zone."
  }
}

run "a_live_single_cname_is_imported_and_a_name_without_one_is_not" {
  command = plan

  plan_options {
    target = [data.cloudflare_dns_records.host]
  }

  override_data {
    target = data.cloudflare_dns_records.host["first.hallucinai.de"]
    values = {
      result = [{ id = "11111111111111111111111111111111", type = "CNAME", name = "first.hallucinai.de", content = "synthetic.invalid", comment = null, comment_modified_on = null, created_on = null, data = null, meta = null, modified_on = null, priority = null, private_routing = null, proxiable = true, proxied = true, settings = null, tags = [], tags_modified_on = null, ttl = 1 }]
    }
  }

  assert {
    condition     = output.record_ids_to_import == { "first.hallucinai.de" = "${data.cloudflare_zone.hallucinai.id}/11111111111111111111111111111111" }
    error_message = "Exactly the live single CNAME is not the one import."
  }
}

run "no_record_is_imported_where_none_exists" {
  command = plan

  plan_options {
    target = [data.cloudflare_dns_records.host]
  }

  assert {
    condition     = length(output.record_ids_to_import) == 0
    error_message = "A record is imported where none exists."
  }
}

run "two_cnames_for_a_name_fail_the_plan" {
  command = plan

  override_data {
    target = data.cloudflare_dns_records.host["first.hallucinai.de"]
    values = {
      result = [
        { id = "11111111111111111111111111111111", type = "CNAME", name = "first.hallucinai.de", content = "synthetic.invalid", comment = null, comment_modified_on = null, created_on = null, data = null, meta = null, modified_on = null, priority = null, private_routing = null, proxiable = true, proxied = true, settings = null, tags = [], tags_modified_on = null, ttl = 1 },
        { id = "22222222222222222222222222222222", type = "CNAME", name = "first.hallucinai.de", content = "other.invalid", comment = null, comment_modified_on = null, created_on = null, data = null, meta = null, modified_on = null, priority = null, private_routing = null, proxiable = true, proxied = true, settings = null, tags = [], tags_modified_on = null, ttl = 1 },
      ]
    }
  }

  plan_options {
    target = [data.cloudflare_dns_records.host]
  }

  expect_failures = [data.cloudflare_dns_records.host["first.hallucinai.de"]]
}

run "an_address_record_for_a_name_fails_the_plan" {
  command = plan

  override_data {
    target = data.cloudflare_dns_records.host["second.hallucinai.de"]
    values = {
      result = [{ id = "33333333333333333333333333333333", type = "A", name = "second.hallucinai.de", content = "192.0.2.1", comment = null, comment_modified_on = null, created_on = null, data = null, meta = null, modified_on = null, priority = null, private_routing = null, proxiable = true, proxied = true, settings = null, tags = [], tags_modified_on = null, ttl = 1 }]
    }
  }

  plan_options {
    target = [data.cloudflare_dns_records.host]
  }

  expect_failures = [data.cloudflare_dns_records.host["second.hallucinai.de"]]
}
