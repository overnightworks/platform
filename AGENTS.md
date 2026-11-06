# AGENTS.md

## Commands

- `quality hygiene .` runs the repository rules of quality at the release `.github/workflows/ci.yml` pins and must print `hygiene: clean`. Install it as
  quality's README says, at that release.

## Layout

- `.github/workflows/ci.yml`: the `checks` job and the `quality` job that calls quality's `gate.yml`.
- `.github/workflows/code-scanning.yml`: CodeQL through quality's `codeql.yml`.
- `quality/config.toml`: the gate's mandatory jobs; a root entry outside quality's base list is declared here.
- `sonar-project.properties`: the SonarCloud project.

## Owners

- quality owns the gate, its workflows and its docs; the jobs and pins here follow its README and `docs/`.
- overnightworks/platform#1 holds the plan.
