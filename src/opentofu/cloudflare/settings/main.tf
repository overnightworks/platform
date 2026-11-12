terraform {
  required_version = ">= 1.13.0"

  required_providers {
    cloudflare = {
      source = "cloudflare/cloudflare"
    }
  }
}

variable "zone_id" {
  type        = string
  description = "The zone whose settings these are."
}

# HSTS at the zone's edge, for the apex and every subdomain: the preload list is a property of the
# domain. The origins already send nosniff, so it stays off here.
resource "cloudflare_zone_setting" "hsts" {
  zone_id    = var.zone_id
  setting_id = "security_header"
  value = {
    strict_transport_security = {
      enabled            = true
      include_subdomains = true
      max_age            = 31536000
      nosniff            = false
      preload            = true
    }
  }
}

# Network Error Logging off for the zone: with it on, every response carries `nel` and `report-to`
# headers that make the visitor's browser report its network errors to a.nel.cloudflare.com, a
# third-party request no page of ours asked for.
resource "cloudflare_zone_setting" "nel" {
  zone_id    = var.zone_id
  setting_id = "nel"
  value = {
    enabled = false
  }
}
