# An app on the platform

Reference for the head who moves an app onto the platform or changes how it runs there. It says what an app may rely on,
what every app offers, what its move proves, and where each rule is checked. It restates no mechanics of its owners:
`docs/ARCHITECTURE.md` (the platform's parts) and quality's release path and gate.

## Scope and trigger

This section holds ruled sentences.

- The standard covers every app that runs on the platform or moves onto it. The rules on state bind only an app that
  keeps state. Libraries are not covered; they release through quality's path alone.
- An app meets the standard with its move onto the platform; an app already there meets it in its next platform change.
  A deploy path that is leaving is never changed to conform.
- Platform owns the rule. Each rule a machine can check is checked where the checked file lives: platform's CI and
  admission for the manifests under `apps/`, quality's gate for what lives in an app repository. A check of an app
  repository cites this document.

## What an app may rely on

An app uses only the capabilities it needs; nothing obliges it to consume one.

- A host on Traefik's `web`, reached only through the platform's tunnel. A tunnel line changes in a pull request. The Service an Ingress routes
  to carries Traefik's sticky-cookie annotations, the same on every app's, so that the app can run several pods
  without a change of its own: a visitor's requests then reach one pod, by a host-only cookie that lives for the session.
- Its own Namespace with Pod Security `restricted` enforced, never pruned (presentator's enforces none, since its build
  worker's init container holds `NET_ADMIN`: `apps/presentator/worker.yaml`, #589), and a NetworkPolicy naming its
  senders. The Namespace is an entry in the platform's namespaces layer (`infrastructure/namespaces/namespaces.yaml`,
  prune disabled), added in a pull request.
- Secrets from `platform-secrets` (SOPS with age), mounted as files. An app with no Secret of its own has none.
- Its own Postgres in its Namespace, from the base `infrastructure/postgres` that `apps/<app>/kustomization.yaml`
  includes, so the app's one Kustomization owns it and `db:load-dump` can suspend it with the app.
- Its private image, pulled through the Secret `ghcr-pull`. The ref moves in a pull request.
- A pull layer, where the app has one (`apps/<app>/pull`, the Kustomization `<app>-pull`, on the base
  `infrastructure/pull`): its Job pulls every image of the release onto the node as an image volume before the app's
  layer, which waits for it, rolls them, so a `Recreate` stops the old pod only for the new one's start. The Component
  `apps/<app>/release` owns the ref, and the app and its pull layer include it. A failed or slow pull leaves the pull
  layer not Ready: the old release serves, and the app's other manifest changes wait with it. The finished Job's pod
  stays until the next release replaces the Job, so the node keeps the image.
- Provenance: platform's `images` job checks a bumped ref's tag, attestation and signer. On the PC, the admission policy
  `app-and-vendor-images` checks the ref's form and Kyverno's policy `app-attestations` (`infrastructure/app-attestations`)
  verifies the SLSA provenance attestation of every app ref of a Pod on its create and on a change of its images, for the
  apps whose repository it names, with Kyverno's own pull credential, so a Pod without `imagePullSecrets` is judged too.
  A new app's repository joins its attestors in the same pull request as its layer; an app ref of a repository without an
  attestor is refused. Kyverno is a single replica: while it is down with its Deployment at one replica (a crash, a
  restart, a drain, a lost node) its webhook configurations stay and every Pod create or image change of an app is
  refused. A Deployment scaled to 0 or deleted while Kyverno runs is its own shutdown, in which it deletes its
  webhook configurations, so the check is then open. The head's `mise run admission:pause` ends there on purpose, and
  `mise run admission:resume` restores the check.
- An S3-compatible object store, for a file that more than one pod needs: the Service `s3` in Namespace `objectstore`,
  Garage behind it, one bucket and one key per app (`infrastructure/objectstore`). The bucket is named like the app's
  Namespace and holds read and write rights for its key alone; the key neither owns the bucket nor makes another. Where
  the Namespace's Secret `object-store-backup` holds a key, the bucket holds read rights for that key too, and for it
  alone beside the app's: it is the backup's reader and can write nothing. An app
  gets a bucket in a pull request that adds its Namespace to `infrastructure/objectstore/namespaces.txt`, and the Secret
  `object-store` in `platform-secrets`, which the Job `apply` reads through its ClusterRole. The contract, in the web's
  environment:
  - `AWS_ENDPOINT_URL_S3`, the Service's address, and `AWS_DEFAULT_REGION`, the store's region, which the SDK reads by
    these names;
  - `AWS_SHARED_CREDENTIALS_FILE`, a file of the Secret `object-store`, key `credentials`, in the INI form the SDKs
    read (`[default]`, `aws_access_key_id`, `aws_secret_access_key`);
  - `<APP>_S3_BUCKET`, the bucket's name.

  A Python app's adapter uses boto3 from 1.36 on, made with no endpoint, region or key argument, since botocore reads the
  three variables above, and with `Config(s3={"addressing_style": "path"})`, as cluster DNS resolves no bucket subdomain.
  It makes one client per process, so a rotated key takes effect at the restart that reads it, and an async app calls it
  through anyio's threadpool. aiobotocore lags botocore's releases and pulls aiohttp, obstore does not read the shared
  credentials file, and minio-py reads no endpoint from the environment. An app's CI drives its adapter against the real
  Garage through the action `.github/actions/garage`, never an imitation of AWS: it starts Garage at the image and with the
  `garage.toml` that `infrastructure/objectstore` holds at the commit it is pinned at, makes the bucket named by its input
  `bucket` (default the repository's name), imports a key it generates, and exports the three variables above, with the
  bucket as its output `bucket`. An app pins it as `uses: overnightworks/platform/.github/actions/garage@<commit sha>`.
  The store has no object
  versioning and no `If-None-Match` on a write. Plain HTTP stays inside the cluster. A bucket is backed up only where
  its app's layer declares it (below), and an app may keep a file that is its only copy in such a bucket while one pre-sync stages
  the backup's first copy of the bucket within its budget (`PRE_SYNC_BUDGET`, `infrastructure/postgres/backup/files/files.yaml`). The restore command puts back each object's key and bytes,
  not its Content-Type (guessed from the extension), its user metadata or its server time, which becomes the time of the load.
- **Its names in the realm.** Keycloak's realm `hallucinai` (`infrastructure/keycloak/realm.yaml`) holds an app `<name>`'s objects under one scheme: the client `<name>`, through which it signs people in; the group `/apps/<name>` and, where the app has admins, `/apps/<name>/admin`, which mean what webauth's host contract (APP-03, APP-04) says; the group `/apps/<name>/mcp`, whose members' agents may reach its MCP endpoint; and the client scope `mcp-<name>`, which a token for that endpoint carries. Two names belong to the fleet: the group `/agents`, which holds every agent with an account of its own, and the public client `agents`, through which a person's own agent signs in. The app's Deployment hands each name the app uses to the container that checks tokens, as a plain environment value under the same key in every app: `REALM_CLIENT_ID`, `REALM_LOGIN_GROUP`, `REALM_ADMIN_GROUP`, `REALM_MCP_GROUP`, `REALM_MCP_SCOPE`, `REALM_AGENT_GROUP` and `REALM_MCP_CLIENT_ID`. Two names of services belong to the fleet too: the group `/services/litellm`, the AI gateway's right, under `REALM_AI_GROUP`, and the client scope `speech-service-audience`, the speech service's, under `REALM_SPEECH_SCOPE`; the Deployment hands them whether or not the app's code reads them yet. A service's own names (speech's client, role and group) stand in its own configuration. The app maps the keys onto its own settings and holds no literal of them. A container that hands any `REALM_` key hands every one that the realm file demands of its app, and the check judges the two service keys when handed and never demands them. No container under `apps/` takes `envFrom`. Which clients may ask for an app's scope, and which agents are members of its MCP group, is the app's choice, written in the realm file.

Provided for an app's database: a weekly k8up backup into its own repository on the platform, kept 4 weekly and 3 monthly, with a monthly `restic check` and a monthly restore test (`infrastructure/postgres/backup`, which keycloak, litellm, hopin, skat, songmaker, personas and presentator include). Where an app's layer also includes `infrastructure/postgres/backup/files` and names a claim, the backup copies that claim beside the dump. Where it also includes `infrastructure/postgres/backup/files/bucket`, the backup copies the Namespace's bucket beside them, read with its read-only backup key, in the same snapshot, and the monthly restore test reads one unchanged object of the latest snapshot and compares its sha256 with the live object's, read with the same key. `mise run db:load-dump` restores the database, the claim and the bucket of one snapshot together and refuses a bucket that holds objects unless `--empty-bucket` (restore-a-database.md). Not provided: a backup of a claim that no layer names, a database's backup without its layer including that component, a backup of a bucket that no layer declares, and a copy of anything off the PC. A dead disk loses every app's data.

## What every app offers

- **Release.** Its images come from quality's release path; their number, names and tags are that path's and the app's.
- **Description.** Its manifests live only in platform, under `apps/<app>/`. Its image ref changes only in a pull
  request; a value the image validates, such as a caller table, changes in the same pull
  request as the ref. For an app with a Component `apps/<app>/release`, `mise run release:bump <app> [version]` makes
  that pull request from the app's newest release: it sets the tag and digest, refreshes the legal copies of an app
  that has legal pages and rebuilds the legal pages, and pushes `release/<app>` only when its patch differs from the
  open branch's or the branch conflicts with main. A release that needs other settings (a changed legal page set, a
  new variable) stays an ordinary lane. The command bumps a Component whose images come from one repository of the
  owner, named by `newName` or `name`, and moves each image to the new version with the variant suffix its tag
  carries (speech-runtime's two images of one repository, the second tagged `<version>-gpu`); a Component of images
  from two repositories stays an ordinary lane.
- **Pod shape.** Each pod passes Pod Security `restricted` in its namespace and admission's image policy; presentator's
  build worker passes `baseline`, and only its init container's `NET_ADMIN` exceeds it (#589).
- **Readiness.** Each long-running process exposes a readiness check, an HTTP route or a command, that fails while it
  cannot serve. Flux reports a layer Ready only once its pods are, so a check that passes too early hides a broken start.
- **Connections.** A Deployment that opens its Postgres declares the connections one pod may hold: the pool and overflow
  variables its container sets (`DATABASE_POOL_SIZE` and `DATABASE_MAX_OVERFLOW`, counting one more for init-time
  engines), or, where the app or its vendor fixes them, the annotation `hallucinai.de/postgres-connections-per-pod`.
  The sum over the namespace's Deployments of their pods x that figure, plus the backup's dump, must stay within the
  base's `max_connections` less its reserved slots. A `Recreate` Deployment has its replicas. A `RollingUpdate` has 2 x
  replicas + surge pods, since a pod being stopped is no part of the surge and may hold its connections while the surge
  pods start, and each surge pod adds 1 connection where its init container migrates the database.
- **Configuration.** Live settings come from the manifest's environment, secrets from files `platform-secrets`
  supplies; no live secret is a plain environment value, since an environment value passes to every child process. How
  the app finds its files (`*_FILE`, a secrets directory) is the app's.
- **No second deploy path.** For the live app, its repository keeps no compose file, deploy script, systemd unit,
  backup script or monitoring stack; each leaves through an item on the app's board.

## Where each rule is checked

| Rule | Checked by |
|---|---|
| Image ref is a full app ref at a release, verified by tag, attestation and signer; the image comes from quality's path | platform's `images` job (tag, attestation, signer commit on quality's main); [quality's release path](https://github.com/overnightworks/quality/blob/main/docs/release.md) in the app's own release |
| Image form (listed vendor at a digest, or a full app ref) on every Pod create or change | admission policy `app-and-vendor-images` |
| An app ref carries a provenance attestation signed by quality's release workflow for its own repository, on every Pod create or image change | Kyverno's policy `app-attestations`; platform's `cluster` job proves a refusal by server-side dry-run and every live app ref admitted |
| Namespace enforces `restricted` (presentator's warns and audits only); Deployment is `Recreate` or a `RollingUpdate` that never takes a pod away before its replacement is Ready, Available with all its replicas Ready, every container at the Deployment's digest | platform's `cluster` job, for each Deployment under `apps/` |
| A Deployment's pods, with those still stopping in a rolling update, its surge and the backup, stay within its Postgres' `max_connections` | the `checks` job, by rendering the layers of hopin, songmaker, personas, skat, presentator, Keycloak and LiteLLM |
| A name a manifest under `apps/` hands under a `REALM_` key is a plain value, declared in `realm.yaml` as an object of that key's kind, and the layer's own app's or one of the fleet's; every key the realm file demands of the app is handed; no container there takes `envFrom` | the `checks` job, by rendering every layer under `apps/` that `clusters/pc/apps.yaml` names |
| Every Service an Ingress routes to carries the same five sticky-cookie annotations | the `checks` job, by rendering every layer of `clusters/pc` |
| A second request with the cookie reaches the same one of two pods, and the cookie is `Secure`, `HttpOnly` and host-only | the `cluster` job's part `core`, on a throwaway namespace |
| Two pods are Ready and a rollout restart keeps both available | the `cluster` job, for personas |
| Manifests live under `apps/<app>/` and reconcile | the `cluster` job through the app's own Kustomization, named like its directory, which the `checks` job requires for every directory, and for a pull layer `<app>-pull` |
| Every app ref an app renders is an image volume of its pull layer's Job, and a container mounts every volume | the `checks` job, by rendering both |
| The pull layer's Job completes before the app's ReplicaSet is created, and the app's pods find the image on the node | the `cluster` job |
| Env files and published compose ports pass quality's rules | quality's gate rules `env-file` and `compose-port`, in the app repository |
| A readiness check exists; secrets are files; no second deploy path | not machine-checked; the move checklist's answers carry them |

## The move checklist

Each app's move item answers every line with evidence before the app takes live traffic on the platform. Platform's head
checks the answers as owner; a line not yet held names its owning item and stays open on the move.

1. **Capabilities.** Which capabilities above the app uses, and which it needs that the platform does not provide yet.
2. **Open prerequisites.** Each with its owner item.
3. **Runtime and configuration interface.** Its processes and the Deployment each runs in, its images, ports, readiness
   checks, settings, secret files, writable paths and resource needs.
4. **State recovery** (an app that keeps state). Each piece of state named as truth or cache; where its truth lives
   (database kind, claims or another store, its queue) and why, against the alternatives; how database and files are
   backed up and restored into one consistent state; a restore driven once and verified at the application level (the
   app serves the restored data), not by row counts alone. What a lost queue or lock costs goes to the operator when it
   is a data loss.
5. **Rollout and migration safety.** Who runs migrations and when; whether old and new versions run side by side safely
   or writers stop first; what a failed migration leaves; how a rollback works once the schema has moved.
6. **Security boundary.** What each process runs under `restricted`, its network senders and receivers, and where it
   runs code it does not trust. A pod passes `restricted`, or the move carries an explicit operator-ruled deviation
   under marketplace's standards deviation clause; a review alone cannot authorise one.
7. **Predecessor exit.** Each part that leaves (compose files, scripts, units, monitoring, the old backups), its item,
   the proof that replaces a check it carried, and when the old path stops.

## Where it ends against quality's release path

[quality's release path](https://github.com/overnightworks/quality/blob/main/docs/release.md) ends at a released tag and a pushed, attested image. From the pull request that moves the
ref on, this standard holds. A compose file used only by CI or local runs is not covered by the no-second-deploy-path rule; quality's
gate judges it by its own rules.

Platform reports a release live when its ref's merge is on main, Flux shows the app's Kustomization (and its pull layer)
Ready at that merge or a later one, and each of the app's Deployments runs the release's digest with every replica Ready
and Available; platform's head writes that on the release item and tells the app's head. For an app where a person signs
in, the app's head then runs `mise run live:report sign-in <app>` from platform's primary checkout, which `aco land` keeps
at the landed main, and records the result line on its release item. The report reruns a red once, pushes the result to
the app's Gatus row and opens the item at the app for a red after the rerun; exit 4 means a timer or another head is
running, and the head runs it again after that run ends. A red whose line names another app's leftover goes to platform's
head.

## The GPU

The platform's node offers its one card to Kubernetes as `nvidia.com/gpu: 1`, through the RuntimeClass `nvidia` and
NVIDIA's device plugin, with no time-slicing or sharing. The card has one user at a time, songmaker's GPU worker or
speech's GPU voice, chosen live by `mise run gpu:use` and not in Git; `docs/operations.md` owns the switch and the bridge
that keeps speech answering through a GPU release.
