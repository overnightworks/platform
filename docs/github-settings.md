# GitHub settings

This reference holds ruled sentences.

Reader: whoever changes `src/opentofu/github`, and the fleet's heads and quality, whose gate its rulesets require.

## What `src/opentofu/github` declares

`src/opentofu/github/`: the security and merge settings of the managed fleet repositories and, in the child module
`organization/`, the organisation's four rulesets (`main: PR only`, `quality / verdict required`, `release tags are
immutable`, `code scanning: high or higher blocks the merge`, each with `prevent_destroy`, no bypass actor and
enforcement `active`), the schemas of the properties `quality_gate` and `code_scanning_exempt` and platform-secrets' one
value of the latter, every resource also `destroy = false`; `organization.tf` holds the module call and the `import`
blocks by id. (GH-1)

The ruleset `quality / verdict required` reaches a repository only through `quality_gate=true`, requires the check
`quality / verdict` pinned to GitHub Actions (`integration_id` 15368) and is quality's contract; the property's values
are quality's merge command's and never declared, and the schema's `role` stays as set on GitHub. (GH-2)

The ruleset `code scanning: high or higher blocks the merge` requires CodeQL at `high_or_higher` with `alerts_threshold`
`none` on the default branch of every `quality_gate=true` repository except one whose `code_scanning_exempt` is `true`,
which only platform-secrets carries and only organisation actors set. (GH-7)

## How a change reaches GitHub (`scripts/apply_github_settings.sh`)

`scripts/apply_github_settings.sh` plans the GitHub settings `src/opentofu/github` declares, with the operator's own gh
login, on any commit and without writing state (exit 0 no change, 2 changes, 1 failure). (GH-3)

`--apply` applies that run's own plan, only from a clean `origin/main`. (GH-4)

A plan with a `delete` action, a replacement included, fails with exit 1 on both runs, names each address and applies
nothing; a deliberate removal is a `removed` block with `lifecycle { destroy = false }`, which plans a forget. (GH-5)

An imported object's state carries no `skip_destroy` until an apply writes it, so removing a block can plan a delete;
the command refuses any such plan, which closes it for every object of the root. (GH-6)
