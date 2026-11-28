# Runbook: create or replace the release App

Symptom: the release App does not exist, its name is taken or its key is lost, or it must go.
Impact: the release bump's publishing job mints its token from the App's key, which lives only in the environment
`release-bump` of platform ([the GitHub settings reference](../github-settings.md), GH-8).

## Create

1. The operator, in a checkout of platform at the landed `main`:
   `cd ~/git/platform && mise run release:create-app <name>`, the name the head gave, then a click on "Create GitHub App"
   in the page that opens (GitHub may ask for the password again). The terminal reports the key stored and the browser
   opens the installation page. The key passes nothing else: it goes from GitHub's answer into `gh secret set`'s stdin.
2. The operator, on that page: "Only select repositories", platform, "Install".
3. An agent, with its own gh login, reads and records on the item that asked for the App:
   - the installation: `gh api orgs/overnightworks/installations --jq '.installations[] | select(.app_slug == "<name>")'`
     holds `id`, `client_id`, `repository_selection` (`selected`) and `permissions`, which are exactly `contents` and
     `pull_requests` write and `metadata` read; the installation's settings page lists its repositories, exactly platform;
   - the App: `gh api apps/<name>` holds its `id` and `events`, which is empty;
   - the login `<name>[bot]`: `gh api 'users/<name>[bot]'`;
   - the stored key: `gh api repos/overnightworks/platform/environments/release-bump/secrets --jq '.secrets[]'` lists
     the name `RELEASE_BUMP_APP_PRIVATE_KEY` and its `updated_at`.

## Replace

1. The operator: step 1 and 2 of Create under a new name, since an App's name is unique on GitHub. The new key
   overwrites the secret, so no key ever lands on disk.
2. The operator, once the new installation is read back: delete the old App on
   `https://github.com/organizations/overnightworks/settings/apps/<old name>`, which voids its key.
3. An agent: the values the record of Create names change to the new App's wherever a workflow holds them.

## Revoke

The operator deletes the App on its settings page, which voids its key and removes its installation. Uninstalling it
alone leaves the key valid but useless. `gh secret delete RELEASE_BUMP_APP_PRIVATE_KEY --env release-bump --repo
overnightworks/platform` removes the stored key.

## The command did not report the key stored

The command exited non-zero after it served the page, and printed the App's settings page and "if it exists, delete it
and rerun with a new name": GitHub may have made the App although no key was stored.

1. Open the settings page the command printed. A 404 means no App was made; nothing is left to delete.
2. An agent: the secret's `updated_at` (Create, step 3) after the run's start means a key was stored by a run that did
   not report it, and the rule below holds all the same.
3. The operator: delete the App on its settings page, at the bottom ("Delete GitHub App").
4. The operator: Create under a new name; the head marks step 2 again with it.

## Escalate

GitHub refuses the manifest page's local `redirect_url`: stop. The command has no path for pasting a code, so the item
that asked for it returns for a revision.
