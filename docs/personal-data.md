# Personal data

This reference holds ruled sentences.

Reader: the head who writes or checks a privacy text, and a lane that touches a log, a store, a backup or a token.

## Pod logs

The pod-log parts (`host/pod-logs/`) keep every pod log line at most 30 days, as the apps' privacy texts promise:
`pod-logs.conf` in `/etc/tmpfiles.d/` deletes each file under `/var/log/pods` 28 days after its creation, with its
emptied directories, and every `.gz` and `.tmp` in each container directory whatever its age, since the kubelet makes
none and a copy's creation time is younger than its lines; `pod-logs-clean.timer` and `.service` in
`/etc/systemd/system/` run that clean daily by the wall clock and after boot, then `scripts/check_pod_logs.sh` as
`/usr/local/sbin/check-pod-logs`; `container-log-max-files=2` in `host/k3s/config.yaml` keeps the kubelet from
compressing a rotated file. (PD-1)
The promise: [allgemein](../infrastructure/legal/sections/allgemein/datenschutz.html#server-protokolle),
[keycloak](../infrastructure/legal/sections/keycloak/datenschutz.html#anmeldung),
[speech](../infrastructure/legal/sections/speech/datenschutz.html#sprachdienst),
[hopin](../infrastructure/legal/app-texts/hopin/datenschutz.html#hopin-protokolle),
[skat](../infrastructure/legal/app-texts/skat/datenschutz.html#skat-protokolle).

## Loki (`infrastructure/loki/`)

`limits_config.retention_period` of 28 days with the compactor's retention on is the one rule for Loki's copy of every
line, which the privacy texts promise gone before 30 days; the compactor runs at start, so a PC that was off deletes
shortly after its next start. (PD-2)
The promise: [allgemein](../infrastructure/legal/sections/allgemein/datenschutz.html#server-protokolle),
[keycloak](../infrastructure/legal/sections/keycloak/datenschutz.html#anmeldung),
[speech](../infrastructure/legal/sections/speech/datenschutz.html#sprachdienst).

## The backup component (`infrastructure/postgres/backup/`)

Its Schedule runs a weekly backup (Sunday 03:00, prune keeping 4 weekly and 3 monthly, a monthly `check`) of
`pg_dump --format=custom` into `backup-repository`, the URL the including layer sets in the ConfigMap `postgres`; a
PodConfig gives k8up's Job pods the fields `restricted` requires; and the CronJob `restore-test` restores the latest
snapshot into a throwaway server each month, on the 1st at 05:00 UTC, bounded to an hour, and fails without a snapshot
or on an empty first key table. (PD-3)
The promise: [keycloak](../infrastructure/legal/sections/keycloak/datenschutz.html#anmeldung),
[litellm](../infrastructure/legal/sections/litellm/datenschutz.html#agent-dienst).

## LiteLLM, its front `litellm-front` and its egress `agent-egress` (`infrastructure/litellm/`)

LiteLLM, one pod with `Recreate` at uid 1000 with a read-only root, reads its master and provider keys from the Secret
`litellm` and builds `DATABASE_URL` from the Secret `postgres`, both from `platform-secrets`, and does not start unless
each key and the password is one non-empty printable line and the password URL-safe; it starts with core dumps off,
admits only the front and sends only to cluster DNS, its Postgres and agent-egress, which its `hostAliases` name for the
provider hosts at the fixed ClusterIP of agent-egress's Service, in k3s's default service CIDR. (PD-4)
The promise: [litellm](../infrastructure/legal/sections/litellm/datenschutz.html#agent-dienst).

The front, a Traefik on port 4000, admits only the namespaces `hopin`, `personas`, `presentator`, `songmaker` and
`gatus` and passes only `POST /v1/chat/completions`, `POST /v1/images/generations` and `GET /v1/models` without a query
string. (PD-5)
The promise: [litellm](../infrastructure/legal/sections/litellm/datenschutz.html#agent-dienst).

agent-egress, a Traefik on 443 that admits only LiteLLM, passes TLS only for the SNIs of `egress-allowed.yml` and sends
only to cluster DNS, so nothing the copy of hal's data holds leaves the cluster. (PD-6)
The promise: [litellm](../infrastructure/legal/sections/litellm/datenschutz.html#agent-dienst).

The CronJob `litellm-expire` runs at 04:00 UTC with `Forbid`, `backoffLimit` 0 and deletes in one statement,
`expire.sql` (a ConfigMap), the daily person, tool and label rows dated more than 90 days before the database's UTC day,
the tool rows last used before the moment 90 days before now, or created before it when never used, and the customer
rows without a budget, without spend and without a daily row inside the period; the period is no setting, as the privacy
text states it. (PD-7)
The promise: [litellm](../infrastructure/legal/sections/litellm/datenschutz.html#agent-dienst).

## The speech service

`apps/speech-runtime/`: speech-runtime's Deployment, Service, caller table (a ConfigMap) and NetworkPolicy, which admits
port 8080 only from the namespaces `hopin`, `presentator` and `gatus`. (PD-8)
The promise: [speech](../infrastructure/legal/sections/speech/datenschutz.html#sprachdienst).
