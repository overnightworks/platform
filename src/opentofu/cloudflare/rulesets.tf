# The zone's three rulesets, as hal's OpenTofu declared them; the expressions are hal's, word for word. Cloudflare keeps
# one entry point per phase, so the one the zone already holds is imported, never created beside it, and a phase the zone
# holds none for is created.

# Cloudflare-only facts, keyed by hostname. Every hostname of the tunnel's lines has an entry, an empty list for a host
# with no denied path, so a new host never silently gets no deny rule; the output below fails the plan otherwise.
locals {
  denied_paths_by_host = {
    "hallucinai.de"                  = []
    "auth.hallucinai.de"             = []
    "hopin.hallucinai.de"            = ["/auth/backchannel-logout"]
    "presentator.hallucinai.de"      = ["/auth/backchannel-logout"]
    "presentator-talk.hallucinai.de" = ["/auth/backchannel-logout"]
    "skat.hallucinai.de"             = ["/auth/backchannel-logout"]
    "songmaker.hallucinai.de"        = ["/auth/backchannel-logout", "/metrics"]
  }

  # The names that answer 302 at the edge and never reach the tunnel; the apex also has a line, and the pages it serves
  # and the prefix of its files are left to the tunnel.
  redirect = {
    hostnames = [local.zone_name, "www.${local.zone_name}"]
    target    = "https://auth.${local.zone_name}/"
    serve = {
      pages = ["/impressum", "/datenschutz", "/nutzungsbedingungen", "/favicon.ico"]
      files = "/_rechtliches/"
    }
  }

  ruleset_phases = {
    client_address = "http_request_late_transform"
    deny_public    = "http_request_firewall_custom"
    apex_redirect  = "http_request_dynamic_redirect"
  }
  zone_rulesets = {
    for name, phase in local.ruleset_phases : name => [
      for ruleset in data.cloudflare_rulesets.zone.rulesets : ruleset if ruleset.kind == "zone" && ruleset.phase == phase
    ]
  }
  ruleset_ids_to_import = {
    for name, found in local.zone_rulesets : name => "zones/${local.zone_id}/${found[0].id}" if length(found) == 1
  }
}

# All the zone's rulesets, managed ones included; the entry point of a phase is the one of kind zone.
data "cloudflare_rulesets" "zone" {
  zone_id = local.zone_id

  lifecycle {
    postcondition {
      condition = alltrue([
        for phase in values(local.ruleset_phases) :
        length([for ruleset in self.rulesets : ruleset if ruleset.kind == "zone" && ruleset.phase == phase]) <= 1
      ])
      error_message = "The zone holds more than one ruleset of kind zone in one of the phases ${join(", ", sort(values(local.ruleset_phases)))}; Cloudflare keeps one entry point per phase."
    }
  }
}

# The visitor's address as Cloudflare saw it, in `Forwarded` (RFC 7239): a header the visitor sent
# is overwritten, which `X-Forwarded-For` cannot be (Cloudflare appends to it and forbids setting
# it). Keycloak reads only this header (KC_PROXY_HEADERS=forwarded). RFC 7239 quotes an IPv6
# address in brackets, so the two families are two rules.
resource "cloudflare_ruleset" "client_address" {
  zone_id = local.zone_id
  name    = "client address"
  kind    = "zone"
  phase   = local.ruleset_phases.client_address
  rules = [
    {
      description = "Forwarded carries the IPv4 address Cloudflare saw"
      action      = "rewrite"
      expression  = "ip.src in {0.0.0.0/0}"
      action_parameters = {
        headers = {
          "Forwarded" = {
            operation  = "set"
            expression = "concat(\"for=\", to_string(ip.src), \";proto=https\")"
          }
        }
      }
    },
    {
      description = "Forwarded carries the IPv6 address Cloudflare saw"
      action      = "rewrite"
      expression  = "ip.src in {::/0}"
      action_parameters = {
        headers = {
          "Forwarded" = {
            operation  = "set"
            expression = "concat(\"for=\\\"[\", to_string(ip.src), \"]\\\";proto=https\")"
          }
        }
      }
    },
  ]
}

# Paths the public may never reach, refused at Cloudflare's edge before the tunnel. Cloudflare
# normalizes the incoming URL first (https://developers.cloudflare.com/rules/normalization/how-it-works/),
# but leaves `%2F` encoded and only merges slashes with the zone's optional "Cloudflare" type, which
# this root does not control. So the rule decodes the path itself (`url_decode` with `r`, also
# `%252F`) and matches it with `wildcard` (https://developers.cloudflare.com/ruleset-engine/rules-language/operators/),
# which is case-insensitive and works on the Free plan; `matches` needs Business. Each `/` of the
# denied path becomes `/*`, so extra or encoded slashes, dot segments, a trailing slash and a longer
# tail are refused too: any decoded path with `auth/` followed later by `backchannel-logout`, for
# example `/oauth/backchannel-logout`, so the deny fails closed. The documentation of `http.host`
# (https://developers.cloudflare.com/ruleset-engine/rules-language/fields/reference/http.host/)
# does not promise a port-free value, so a host matches as `<fqdn>` or `<fqdn>:<port>`.
# One rule per distinct path covers every host that lists it, so Free's 5 custom rules serve five
# paths, not five hosts.
locals {
  denied_paths = distinct(sort(flatten(values(local.denied_paths_by_host))))
  deny_rule_expressions = {
    for path in local.denied_paths : path => join(" ", [
      "(",
      join(" or ", [
        for fqdn in sort([for name, paths in local.denied_paths_by_host : name if contains(paths, path)]) :
        "lower(http.host) eq \"${fqdn}\" or starts_with(lower(http.host), \"${fqdn}:\")"
      ]),
      ") and url_decode(http.request.uri.path, \"r\") wildcard \"/*${join("/*", split("/", trimprefix(path, "/")))}*\"",
    ])
  }
}

# A host's record waits for this ruleset (records.tf), so a deny that fails publishes nothing. The import keeps no rule
# of the zone's own: this resource's rules come whole from the facts above, so a plan shows each existing rule it does
# not declare as removed, and that is a stop.
resource "cloudflare_ruleset" "deny_public" {
  zone_id = local.zone_id
  name    = "public deny"
  kind    = "zone"
  phase   = local.ruleset_phases.deny_public
  rules = [
    for path in local.denied_paths : {
      description = "${path} is never reachable from outside"
      action      = "block"
      expression  = local.deny_rule_expressions[path]
    }
  ]
}

# The redirected names answer 302 at Cloudflare's edge and never reach the tunnel. Single Redirects run in the phase
# http_request_dynamic_redirect, in order, and a redirect ends the evaluation (https://developers.cloudflare.com/rules/url-forwarding/,
# which also lists the Free plan's 10 single redirects),
# so one rule per served page comes first and the last rule takes the rest.
# The target is a static URL (`from_value.target_url.value`), so the path and, with preserve_query_string off, the query of
# the request are dropped
# (https://developers.cloudflare.com/rules/url-forwarding/single-redirects/create-api/). A host
# matches as `<fqdn>` or `<fqdn>:<port>`, as in the public deny. With
# `redirect.serve` the apex answers its pages (exactly, as written) and everything under its files
# prefix from the tunnel: the rule of a page sends every other form of it (another case, a trailing
# slash, www) to the apex's exact path, and the last rule leaves the apex's served paths out. Only
# https is redirected (`ssl`): `http://` first goes to https on the same host (Always Use HTTPS), as the
# HSTS preload requires.
# A record waits for this ruleset, as for the deny.
locals {
  redirect_host_expression = join(" or ", [
    for fqdn in sort(local.redirect.hostnames) :
    "lower(http.host) eq \"${fqdn}\" or starts_with(lower(http.host), \"${fqdn}:\")"
  ])
  apex_host_expression = "lower(http.host) eq \"${local.zone_name}\" or starts_with(lower(http.host), \"${local.zone_name}:\")"
  served_pages         = local.redirect.serve.pages
  served_expression = join(" or ", [
    "http.request.uri.path in {${join(" ", [for page in local.served_pages : "\"${page}\""])}}",
    "starts_with(http.request.uri.path, \"${local.redirect.serve.files}\")",
  ])
  redirect_rules = concat(
    [
      for page in local.served_pages : {
        description = "${page} is served at ${local.zone_name}"
        expression  = "ssl and ( ${local.redirect_host_expression} ) and lower(http.request.uri.path) in {\"${page}\" \"${page}/\"} and not ( ( ${local.apex_host_expression} ) and http.request.uri.path eq \"${page}\" )"
        target_url  = "https://${local.zone_name}${page}"
      }
    ],
    [{
      description = "everything else goes to ${local.redirect.target}"
      expression  = "ssl and ( ${local.redirect_host_expression} ) and not ( ( ${local.apex_host_expression} ) and ( ${local.served_expression} ) )"
      target_url  = local.redirect.target
    }]
  )
}

resource "cloudflare_ruleset" "apex_redirect" {
  zone_id = local.zone_id
  name    = "apex redirect"
  kind    = "zone"
  phase   = local.ruleset_phases.apex_redirect
  rules = [
    for rule in local.redirect_rules : {
      description = rule.description
      action      = "redirect"
      expression  = rule.expression
      action_parameters = {
        from_value = {
          status_code           = 302
          preserve_query_string = false
          target_url            = { value = rule.target_url }
        }
      }
    }
  ]
}

import {
  for_each = { for name, id in local.ruleset_ids_to_import : name => id if name == "client_address" }
  to       = cloudflare_ruleset.client_address
  id       = each.value
}

import {
  for_each = { for name, id in local.ruleset_ids_to_import : name => id if name == "deny_public" }
  to       = cloudflare_ruleset.deny_public
  id       = each.value
}

import {
  for_each = { for name, id in local.ruleset_ids_to_import : name => id if name == "apex_redirect" }
  to       = cloudflare_ruleset.apex_redirect
  id       = each.value
}

# The facts above are judged where the plan reports the imports.
output "ruleset_ids_to_import" {
  description = "The rulesets the zone holds for the three phases, which this plan adopts, by name."
  value       = local.ruleset_ids_to_import

  precondition {
    condition     = length(setsubtract(toset(local.tunnel_hostnames), toset(keys(local.denied_paths_by_host)))) == 0
    error_message = "No entry in denied_paths_by_host for the tunnel host(s) ${join(", ", sort(setsubtract(toset(local.tunnel_hostnames), toset(keys(local.denied_paths_by_host)))))}; an empty list is an entry."
  }

  precondition {
    condition     = length(setsubtract(toset(keys(local.denied_paths_by_host)), toset(local.tunnel_hostnames))) == 0
    error_message = "denied_paths_by_host names ${join(", ", sort(setsubtract(toset(keys(local.denied_paths_by_host)), toset(local.tunnel_hostnames))))}, which is no host of the tunnel's lines."
  }
}
