# Runbook: take the platform offline

Symptom: a leak, an attack or a wrong text live, and every public name of the platform must stop answering at once.
Impact: skat, hopin, the legal pages and every other name on the tunnel answer nothing from outside; Traefik, the apps,
Keycloak and the databases keep running, so no data and no running job is lost. Someone already inside the PC is not
stopped.

## Fix

Both commands run on the PC, read neither GitHub nor the registry and are safe to repeat.

1. `mise run offline`: suspends the Kustomization `tunnel`, so that no reconcile scales `cloudflared` back, scales
   `cloudflared` to 0 and ends its Pods with a one second grace period instead of waiting out the connector's drain.
   It prints one line with its duration.
2. Check: the `tunnel` endpoint on the status page (`mise run gatus:open`) turns red within its 60 second interval,
   and a public name answers Cloudflare's 530 from outside.
3. `mise run online`: clears the suspend, asks Flux to reconcile `tunnel` and waits until it is Ready, which
   `cloudflared` grants only with an edge connection. It prints one line with its duration.
4. Check: the `tunnel` endpoint is green and a public name answers again.

Who runs them: the operator, or an agent on his word. A head runs `offline` unasked only at a credible leak or attack
and tells him at once.

A change to a tunnel line merged while the platform is offline applies at `online`, since `tunnel` is suspended.

Rollback: `mise run online`.

## Failure

`online` needs `cloudflared`'s image in the node's cache and waits on `tunnel`'s dependencies; when it times out it names
what did not happen, and running it again is safe. An offline platform raises no alert on purpose: only the red `tunnel`
endpoint shows it.
