# Proves docs/cloudflare-zone.md: the root declares the zone's three rulesets as hal's OpenTofu does, adopts the one the
# zone holds for a phase by import and fails the plan on a host without deny facts, a fact for a non-host or two
# rulesets in one phase. The expressions are hal's, word for word. tofu test cannot plan a resource an import block
# names, so the runs that read the import map plan only the lookup.
mock_provider "cloudflare" {}

variables {
  api_token_file = "tests/synthetic_token.txt"
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

run "the_deny_ruleset_blocks_each_denied_path_for_the_hosts_that_list_it" {
  command = plan

  plan_options {
    target = [cloudflare_ruleset.deny_public]
  }

  assert {
    condition     = cloudflare_ruleset.deny_public.zone_id == data.cloudflare_zone.hallucinai.id && cloudflare_ruleset.deny_public.kind == "zone" && cloudflare_ruleset.deny_public.phase == "http_request_firewall_custom"
    error_message = "The deny ruleset is not the zone's entry point of the custom firewall phase."
  }

  assert {
    condition     = alltrue([for rule in cloudflare_ruleset.deny_public.rules : rule.action == "block"])
    error_message = "A deny rule does not block."
  }

  assert {
    condition = [for rule in cloudflare_ruleset.deny_public.rules : { description = rule.description, expression = rule.expression }] == [
      {
        description = "/auth/backchannel-logout is never reachable from outside"
        expression  = "( lower(http.host) eq \"hopin.hallucinai.de\" or starts_with(lower(http.host), \"hopin.hallucinai.de:\") or lower(http.host) eq \"presentator-talk.hallucinai.de\" or starts_with(lower(http.host), \"presentator-talk.hallucinai.de:\") or lower(http.host) eq \"presentator.hallucinai.de\" or starts_with(lower(http.host), \"presentator.hallucinai.de:\") or lower(http.host) eq \"skat.hallucinai.de\" or starts_with(lower(http.host), \"skat.hallucinai.de:\") or lower(http.host) eq \"songmaker.hallucinai.de\" or starts_with(lower(http.host), \"songmaker.hallucinai.de:\") ) and url_decode(http.request.uri.path, \"r\") wildcard \"/*auth/*backchannel-logout*\""
      },
      {
        description = "/metrics is never reachable from outside"
        expression  = "( lower(http.host) eq \"songmaker.hallucinai.de\" or starts_with(lower(http.host), \"songmaker.hallucinai.de:\") ) and url_decode(http.request.uri.path, \"r\") wildcard \"/*metrics*\""
      },
    ]
    error_message = "A deny rule differs from hal's."
  }
}

run "the_transform_ruleset_sets_forwarded_to_the_address_cloudflare_saw" {
  command = plan

  plan_options {
    target = [cloudflare_ruleset.client_address]
  }

  assert {
    condition     = cloudflare_ruleset.client_address.zone_id == data.cloudflare_zone.hallucinai.id && cloudflare_ruleset.client_address.kind == "zone" && cloudflare_ruleset.client_address.phase == "http_request_late_transform"
    error_message = "The transform ruleset is not the zone's entry point of the late transform phase."
  }

  assert {
    condition = [for rule in cloudflare_ruleset.client_address.rules : {
      description = rule.description
      action      = rule.action
      expression  = rule.expression
      headers     = { for name, header in rule.action_parameters.headers : name => { operation = header.operation, expression = header.expression } }
      }] == [
      {
        description = "Forwarded carries the IPv4 address Cloudflare saw"
        action      = "rewrite"
        expression  = "ip.src in {0.0.0.0/0}"
        headers     = { "Forwarded" = { operation = "set", expression = "concat(\"for=\", to_string(ip.src), \";proto=https\")" } }
      },
      {
        description = "Forwarded carries the IPv6 address Cloudflare saw"
        action      = "rewrite"
        expression  = "ip.src in {::/0}"
        headers     = { "Forwarded" = { operation = "set", expression = "concat(\"for=\\\"[\", to_string(ip.src), \"]\\\";proto=https\")" } }
      },
    ]
    error_message = "A transform rule differs from hal's."
  }
}

run "the_redirect_ruleset_serves_the_legal_pages_and_sends_the_rest_to_the_login" {
  command = plan

  plan_options {
    target = [cloudflare_ruleset.apex_redirect]
  }

  assert {
    condition     = cloudflare_ruleset.apex_redirect.zone_id == data.cloudflare_zone.hallucinai.id && cloudflare_ruleset.apex_redirect.kind == "zone" && cloudflare_ruleset.apex_redirect.phase == "http_request_dynamic_redirect"
    error_message = "The redirect ruleset is not the zone's entry point of the dynamic redirect phase."
  }

  assert {
    condition = alltrue([
      for rule in cloudflare_ruleset.apex_redirect.rules :
      rule.action == "redirect" && rule.action_parameters.from_value.status_code == 302 && rule.action_parameters.from_value.preserve_query_string == false
    ])
    error_message = "A redirect rule is not a 302 that drops the query."
  }

  assert {
    condition = [for rule in cloudflare_ruleset.apex_redirect.rules : {
      description = rule.description
      expression  = rule.expression
      target_url  = rule.action_parameters.from_value.target_url.value
      }] == [
      {
        description = "/impressum is served at hallucinai.de"
        expression  = "ssl and ( lower(http.host) eq \"hallucinai.de\" or starts_with(lower(http.host), \"hallucinai.de:\") or lower(http.host) eq \"www.hallucinai.de\" or starts_with(lower(http.host), \"www.hallucinai.de:\") ) and lower(http.request.uri.path) in {\"/impressum\" \"/impressum/\"} and not ( ( lower(http.host) eq \"hallucinai.de\" or starts_with(lower(http.host), \"hallucinai.de:\") ) and http.request.uri.path eq \"/impressum\" )"
        target_url  = "https://hallucinai.de/impressum"
      },
      {
        description = "/datenschutz is served at hallucinai.de"
        expression  = "ssl and ( lower(http.host) eq \"hallucinai.de\" or starts_with(lower(http.host), \"hallucinai.de:\") or lower(http.host) eq \"www.hallucinai.de\" or starts_with(lower(http.host), \"www.hallucinai.de:\") ) and lower(http.request.uri.path) in {\"/datenschutz\" \"/datenschutz/\"} and not ( ( lower(http.host) eq \"hallucinai.de\" or starts_with(lower(http.host), \"hallucinai.de:\") ) and http.request.uri.path eq \"/datenschutz\" )"
        target_url  = "https://hallucinai.de/datenschutz"
      },
      {
        description = "/nutzungsbedingungen is served at hallucinai.de"
        expression  = "ssl and ( lower(http.host) eq \"hallucinai.de\" or starts_with(lower(http.host), \"hallucinai.de:\") or lower(http.host) eq \"www.hallucinai.de\" or starts_with(lower(http.host), \"www.hallucinai.de:\") ) and lower(http.request.uri.path) in {\"/nutzungsbedingungen\" \"/nutzungsbedingungen/\"} and not ( ( lower(http.host) eq \"hallucinai.de\" or starts_with(lower(http.host), \"hallucinai.de:\") ) and http.request.uri.path eq \"/nutzungsbedingungen\" )"
        target_url  = "https://hallucinai.de/nutzungsbedingungen"
      },
      {
        description = "/favicon.ico is served at hallucinai.de"
        expression  = "ssl and ( lower(http.host) eq \"hallucinai.de\" or starts_with(lower(http.host), \"hallucinai.de:\") or lower(http.host) eq \"www.hallucinai.de\" or starts_with(lower(http.host), \"www.hallucinai.de:\") ) and lower(http.request.uri.path) in {\"/favicon.ico\" \"/favicon.ico/\"} and not ( ( lower(http.host) eq \"hallucinai.de\" or starts_with(lower(http.host), \"hallucinai.de:\") ) and http.request.uri.path eq \"/favicon.ico\" )"
        target_url  = "https://hallucinai.de/favicon.ico"
      },
      {
        description = "everything else goes to https://auth.hallucinai.de/"
        expression  = "ssl and ( lower(http.host) eq \"hallucinai.de\" or starts_with(lower(http.host), \"hallucinai.de:\") or lower(http.host) eq \"www.hallucinai.de\" or starts_with(lower(http.host), \"www.hallucinai.de:\") ) and not ( ( lower(http.host) eq \"hallucinai.de\" or starts_with(lower(http.host), \"hallucinai.de:\") ) and ( http.request.uri.path in {\"/impressum\" \"/datenschutz\" \"/nutzungsbedingungen\" \"/favicon.ico\"} or starts_with(http.request.uri.path, \"/_rechtliches/\") ) )"
        target_url  = "https://auth.hallucinai.de/"
    }, ]
    error_message = "A redirect rule differs from hal's."
  }
}

run "the_rulesets_the_zone_holds_are_imported_by_phase_and_kind" {
  command = plan

  plan_options {
    target = [data.cloudflare_rulesets.zone]
  }

  override_data {
    target = data.cloudflare_rulesets.zone
    values = {
      rulesets = [
        { id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", kind = "zone", phase = "http_request_firewall_custom", name = "synthetic", description = "", last_updated = "2026-01-01T00:00:00Z", version = "1" },
        { id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", kind = "zone", phase = "http_request_late_transform", name = "synthetic", description = "", last_updated = "2026-01-01T00:00:00Z", version = "1" },
        { id = "cccccccccccccccccccccccccccccccc", kind = "zone", phase = "http_request_dynamic_redirect", name = "synthetic", description = "", last_updated = "2026-01-01T00:00:00Z", version = "1" },
        { id = "dddddddddddddddddddddddddddddddd", kind = "managed", phase = "http_request_firewall_custom", name = "synthetic", description = "", last_updated = "2026-01-01T00:00:00Z", version = "1" },
        { id = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", kind = "zone", phase = "http_request_origin", name = "synthetic", description = "", last_updated = "2026-01-01T00:00:00Z", version = "1" },
      ]
    }
  }

  assert {
    condition = output.ruleset_ids_to_import == {
      deny_public    = "zones/${data.cloudflare_zone.hallucinai.id}/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      client_address = "zones/${data.cloudflare_zone.hallucinai.id}/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      apex_redirect  = "zones/${data.cloudflare_zone.hallucinai.id}/cccccccccccccccccccccccccccccccc"
    }
    error_message = "The zone's rulesets of the three phases are not exactly the imports."
  }
}

run "only_the_phase_the_zone_holds_a_ruleset_for_is_imported" {
  command = plan

  plan_options {
    target = [data.cloudflare_rulesets.zone]
  }

  override_data {
    target = data.cloudflare_rulesets.zone
    values = {
      rulesets = [
        { id = "cccccccccccccccccccccccccccccccc", kind = "zone", phase = "http_request_dynamic_redirect", name = "synthetic", description = "", last_updated = "2026-01-01T00:00:00Z", version = "1" },
      ]
    }
  }

  assert {
    condition     = output.ruleset_ids_to_import == { apex_redirect = "zones/${data.cloudflare_zone.hallucinai.id}/cccccccccccccccccccccccccccccccc" }
    error_message = "A phase without a ruleset is imported, or the one with a ruleset is not."
  }
}

run "no_ruleset_is_imported_where_the_zone_holds_none" {
  command = plan

  plan_options {
    target = [data.cloudflare_rulesets.zone]
  }

  assert {
    condition     = length(output.ruleset_ids_to_import) == 0
    error_message = "A ruleset is imported where none exists."
  }
}

run "a_phase_without_a_ruleset_is_created_by_the_plan" {
  command = plan

  plan_options {
    target = [cloudflare_ruleset.deny_public, cloudflare_ruleset.client_address, cloudflare_ruleset.apex_redirect]
  }

  assert {
    condition     = length(output.ruleset_ids_to_import) == 0
    error_message = "The plan adopts a ruleset the zone does not hold."
  }

  assert {
    condition = (
      cloudflare_ruleset.deny_public.phase == "http_request_firewall_custom"
      && cloudflare_ruleset.client_address.phase == "http_request_late_transform"
      && cloudflare_ruleset.apex_redirect.phase == "http_request_dynamic_redirect"
    )
    error_message = "A phase the zone holds no ruleset for is not planned as a ruleset of its own."
  }
}

run "two_rulesets_in_the_deny_phase_fail_the_plan" {
  command = plan

  plan_options {
    target = [data.cloudflare_rulesets.zone]
  }

  override_data {
    target = data.cloudflare_rulesets.zone
    values = {
      rulesets = [
        { id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", kind = "zone", phase = "http_request_firewall_custom", name = "synthetic", description = "", last_updated = "2026-01-01T00:00:00Z", version = "1" },
        { id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", kind = "zone", phase = "http_request_firewall_custom", name = "synthetic", description = "", last_updated = "2026-01-01T00:00:00Z", version = "1" },
      ]
    }
  }

  expect_failures = [data.cloudflare_rulesets.zone]
}

run "two_rulesets_in_the_transform_phase_fail_the_plan" {
  command = plan

  plan_options {
    target = [data.cloudflare_rulesets.zone]
  }

  override_data {
    target = data.cloudflare_rulesets.zone
    values = {
      rulesets = [
        { id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", kind = "zone", phase = "http_request_late_transform", name = "synthetic", description = "", last_updated = "2026-01-01T00:00:00Z", version = "1" },
        { id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", kind = "zone", phase = "http_request_late_transform", name = "synthetic", description = "", last_updated = "2026-01-01T00:00:00Z", version = "1" },
      ]
    }
  }

  expect_failures = [data.cloudflare_rulesets.zone]
}

run "two_rulesets_in_the_redirect_phase_fail_the_plan" {
  command = plan

  plan_options {
    target = [data.cloudflare_rulesets.zone]
  }

  override_data {
    target = data.cloudflare_rulesets.zone
    values = {
      rulesets = [
        { id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", kind = "zone", phase = "http_request_dynamic_redirect", name = "synthetic", description = "", last_updated = "2026-01-01T00:00:00Z", version = "1" },
        { id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", kind = "zone", phase = "http_request_dynamic_redirect", name = "synthetic", description = "", last_updated = "2026-01-01T00:00:00Z", version = "1" },
      ]
    }
  }

  expect_failures = [data.cloudflare_rulesets.zone]
}

run "a_tunnel_file_the_deny_facts_do_not_cover_fails_the_plan" {
  command = plan

  variables {
    tunnel_lines_file = "tests/hosts_two.yaml"
  }

  plan_options {
    target = [data.cloudflare_rulesets.zone]
  }

  expect_failures = [output.ruleset_ids_to_import]
}

run "the_shipped_deny_facts_agree_with_the_tunnels_lines" {
  command = plan

  plan_options {
    target = [data.cloudflare_rulesets.zone]
  }

  assert {
    condition     = length(output.ruleset_ids_to_import) == 0
    error_message = "The shipped facts do not agree with the tunnel's lines."
  }
}

run "a_record_name_outside_the_zone_fails_the_plan" {
  command = plan

  variables {
    tunnel_lines_file = "tests/hosts_foreign.yaml"
  }

  plan_options {
    target = [data.cloudflare_dns_records.host]
  }

  expect_failures = [data.cloudflare_dns_records.host["foreign.example.org"]]
}
