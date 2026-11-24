#!/usr/bin/env bash
# Proves the route of docs/operations.md OPS-23 with the Alertmanager image the render pins: amtool loads the rendered file
# once the init container's placeholders are filled and sends both live check alertnames to the sub-route and no other;
# a running Alertmanager holds two firing LiveCheckRed alerts of different rows in one group and another alert in a group
# of its own; and the receiver's text, rendered for one firing and one resolved row, lists the resolved row only under
# `resolved:`. A cluster-free cell: the container listens on loopback only and ends with the cell.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
scratch="$(mktemp -d)"
container="alertmanager-live-check-cell-$$"
trap 'docker rm -f "$container" >/dev/null 2>&1 || true; rm -rf "$scratch"' EXIT

image="$(yq --no-doc 'select(.kind == "StatefulSet" and .metadata.name == "prometheus-alertmanager") | .spec.template.spec.containers[].image | select(test("^quay[.]io/prometheus/alertmanager"))' \
  infrastructure/prometheus/rendered.yaml)"
[ -n "$image" ] || fail "infrastructure/prometheus/rendered.yaml holds no Alertmanager image"
# The finished file as the init container makes it, with values that name nothing.
yq 'select(.kind == "ConfigMap" and .metadata.name == "prometheus-alertmanager") | .data["alertmanager.yml"]' infrastructure/prometheus/rendered.yaml |
  sed -e 's|@SMARTHOST@|smarthost.invalid:587|g' -e 's|@USERNAME@|sender@mail.invalid|g' -e 's|@TO@|recipient@mail.invalid|g' >"$scratch/alertmanager.yml"
printf 'password' >"$scratch/password"
receiver_text="$(yq '.receivers[0].email_configs[0].text' "$scratch/alertmanager.yml")"
# The alerts of the template data: one row still red and one that turned green.
cat >"$scratch/data.json" <<'JSON'
{"receiver": "mail", "status": "firing", "groupLabels": {"alertname": "LiveCheckRed"}, "commonLabels": {"alertname": "LiveCheckRed"},
 "alerts": [
  {"status": "firing", "labels": {"alertname": "LiveCheckRed"}, "annotations": {"summary": "row still red"}},
  {"status": "resolved", "labels": {"alertname": "LiveCheckRed"}, "annotations": {"summary": "row turned green"}}]}
JSON
chmod -R a+rX "$scratch"
amtool() {
  docker run --rm --volume "$scratch:/cell:ro" --volume "$scratch/password:/run/alertmanager/password:ro" --entrypoint amtool "$image" "$@"
}

amtool check-config /cell/alertmanager.yml >/dev/null 2>&1 || fail "amtool refuses the rendered file with its placeholders filled"
for alertname in LiveCheckRed LiveCheckMissed; do
  routed="$(amtool config routes test --tree --config.file=/cell/alertmanager.yml "alertname=$alertname" 2>/dev/null)"
  grep -q '└── {' <<<"$routed" || fail "an alert of $alertname does not reach the sub-route: $routed"
done
routed="$(amtool config routes test --tree --config.file=/cell/alertmanager.yml alertname=TargetDown 2>/dev/null)"
! grep -q '└── {' <<<"$routed" || fail "an alert of another name reaches the live check sub-route"
echo "amtool loads the file, and LiveCheckRed and LiveCheckMissed reach the sub-route and TargetDown does not"

rendered="$(amtool template render --template.glob=/cell/none --template.text="$receiver_text" --template.data=/cell/data.json 2>/dev/null)" ||
  fail "amtool could not render the receiver's text"
[ "$(grep -c '^firing: row still red$' <<<"$rendered")" = 1 ] && [ "$(grep -c '^resolved: row turned green$' <<<"$rendered")" = 1 ] &&
  ! grep -q 'firing: row turned green' <<<"$rendered" || fail "the text does not list each row once under its own word: $rendered"
echo "the receiver's text lists the row that is red under firing: and the row that turned green only under resolved:, each on its own line"

docker run --detach --name "$container" --publish 127.0.0.1::9093 --volume "$scratch:/cell:ro" \
  --volume "$scratch/password:/run/alertmanager/password:ro" --entrypoint alertmanager "$image" \
  --config.file=/cell/alertmanager.yml --storage.path=/tmp >/dev/null
address="$(docker port "$container" 9093/tcp | head -n 1)"
until_ready() { curl --silent --fail --max-time 2 --output /dev/null "http://$address/-/ready"; }
for _ in $(seq 30); do until_ready && break; sleep 1; done
until_ready || fail "the Alertmanager container did not become ready"
post_alert() {
  curl --silent --fail --max-time 5 --request POST --header 'Content-Type: application/json' "http://$address/api/v2/alerts" \
    --data "[{\"labels\": {\"alertname\": \"$1\", \"name\": \"$2\"}, \"annotations\": {\"summary\": \"$2 red\"}}]"
}
post_alert LiveCheckRed "hopin sign-in"
post_alert LiveCheckRed "skat sign-in"
post_alert TargetDown "some target"
groups="$(curl --silent --fail --max-time 5 "http://$address/api/v2/alerts/groups")"
[ "$(yq -p=json '[.[] | select(.labels.alertname == "LiveCheckRed")] | length' <<<"$groups")" = 1 ] &&
  [ "$(yq -p=json '.[] | select(.labels.alertname == "LiveCheckRed") | .alerts | length' <<<"$groups")" = 2 ] ||
  fail "two firing LiveCheckRed alerts are not one group of two"
[ "$(yq -p=json '[.[] | select(.labels.alertname == "TargetDown")] | length' <<<"$groups")" = 1 ] || fail "TargetDown is not a group of its own"
echo "two firing LiveCheckRed alerts of different rows form one group, and another alert stays in its own"
