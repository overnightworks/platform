# The settings are resources of a module because tofu test cannot plan a resource an import block always names; the
# zone's settings always exist, so they are always adopted.
module "settings" {
  source  = "./settings"
  zone_id = local.zone_id
}

import {
  to = module.settings.cloudflare_zone_setting.hsts
  id = "${local.zone_id}/security_header"
}

import {
  to = module.settings.cloudflare_zone_setting.nel
  id = "${local.zone_id}/nel"
}
