# Every name that answers at the edge: the hostnames of the tunnel's lines and the redirected names, of which www has a
# record and no line. A hostname added to the lines adds a record. Live records are imported as found and nothing is
# converted.
locals {
  tunnel_lines     = yamldecode(file(var.tunnel_lines_file))
  tunnel_hostnames = [for rule in local.tunnel_lines.ingress : rule.hostname if contains(keys(rule), "hostname")]
  record_fqdns     = toset(concat(local.tunnel_hostnames, local.redirect.hostnames))

  zone_id   = data.cloudflare_zone.hallucinai.id
  tunnel_id = data.cloudflare_zero_trust_tunnel_cloudflared.platform.id

  # Among these types at a host's name only a single CNAME may exist (no conversion).
  address_record_types = ["A", "AAAA", "CNAME"]
  address_records = {
    for fqdn in local.record_fqdns : fqdn => [
      for record in data.cloudflare_dns_records.host[fqdn].result : record
      if contains(local.address_record_types, record.type)
    ]
  }
  record_ids_to_import = {
    for fqdn, records in local.address_records : fqdn => "${local.zone_id}/${records[0].id}" if length(records) == 1
  }
}

data "cloudflare_dns_records" "host" {
  for_each = local.record_fqdns
  zone_id  = local.zone_id
  name     = { exact = each.key }

  lifecycle {
    precondition {
      condition     = each.key == local.zone_name || endswith(each.key, ".${local.zone_name}")
      error_message = "${each.key} is not a name in the zone ${local.zone_name}."
    }

    postcondition {
      condition = (
        length([for record in self.result : record if record.type != "CNAME" && contains(local.address_record_types, record.type)]) == 0
        && length([for record in self.result : record if record.type == "CNAME"]) <= 1
      )
      error_message = join(" ", [
        "${each.key} already has ${join(", ", [for record in self.result : record.type if contains(local.address_record_types, record.type)])} records.",
        "Only a single CNAME can be adopted; converting a record is not supported."
      ])
    }
  }
}

resource "cloudflare_dns_record" "host" {
  for_each = local.record_fqdns
  zone_id  = local.zone_id
  name     = each.key
  type     = "CNAME"
  content  = "${local.tunnel_id}.cfargotunnel.com"
  proxied  = true
  ttl      = 1

  # Protection before reachability: no record exists before the deny and the redirect do.
  depends_on = [cloudflare_ruleset.deny_public, cloudflare_ruleset.apex_redirect]
}

import {
  for_each = local.record_ids_to_import
  to       = cloudflare_dns_record.host[each.key]
  id       = each.value
}

output "record_ids_to_import" {
  description = "The live single CNAMEs this plan adopts, by name."
  value       = local.record_ids_to_import
}
