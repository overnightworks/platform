# The importer recovers a lost state; an import of an id that does not exist fails the plan, so nothing is created.
module "organization" {
  source = "./organization"
}

import {
  to = module.organization.github_organization_ruleset.main_pull_request_only
  id = "25224011"
}

import {
  to = module.organization.github_organization_ruleset.quality_verdict_required
  id = "25227067"
}

import {
  to = module.organization.github_organization_ruleset.release_tags_immutable
  id = "25224012"
}

import {
  to = module.organization.github_organization_custom_properties.quality_gate
  id = "quality_gate"
}

import {
  to = module.organization.github_organization_custom_properties.code_scanning_exempt
  id = "code_scanning_exempt"
}

import {
  to = module.organization.github_repository_custom_property.platform_secrets_code_scanning_exempt
  id = "overnightworks:platform-secrets:code_scanning_exempt"
}

import {
  to = module.organization.github_organization_ruleset.code_scanning_required
  id = "26872357"
}
