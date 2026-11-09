#!/usr/bin/env bash
# print_ready_times.sh <step start, epoch seconds>: when each Kustomization, pod and Job turned ready and how long
# each image pull took, as seconds after the start. It only reads and always exits 0; a failed read prints its name.
set -uo pipefail
step_started_at="${1:?the start of the step as epoch seconds}"

# Prefix of every filter: t turns an RFC 3339 time into seconds after the start, dur a Go duration into seconds.
filter_prelude="$(
  cat <<'JQ'
  def t: if . == null then null else (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) - $start end;
  def dur: [scan("([0-9.]+)(ms|s|m|h)") | (.[0] | tonumber) * ({"ms": 0.001, "s": 1, "m": 60, "h": 3600}[.[1]])] | add // 0;
  def seconds: if . == null then "-" else tostring end;
  def sort_nulls_last: sort_by(.[0] // 1e12);
JQ
)"

# report <title> <header> <filter> <kubectl get arguments...>: one aligned table, the filter emits arrays of columns.
report() {
  local title="$1" header="$2" filter="$3" json table
  shift 3
  echo "== $title (seconds after the step's start)"
  if ! json="$(kubectl get "$@" --output json 2>/dev/null)"; then
    echo "the read 'kubectl get $*' failed"
    return 0
  fi
  if ! table="$(jq --raw-output --argjson start "$step_started_at" "$filter_prelude $filter" <<<"$json" 2>/dev/null)"; then
    echo "the table of 'kubectl get $*' could not be formatted"
    return 0
  fi
  { printf '%s\n' "$header"; printf '%s\n' "$table"; } | column --table --separator $'\t' ||
    echo "the table of 'kubectl get $*' could not be aligned"
}

kustomization_filter="$(
  cat <<'JQ'
  [.items[] | (.status.conditions // [] | map(select(.type == "Ready")) | first) as $ready
    | [($ready.lastTransitionTime | t), ($ready.status // "-"), (.metadata.namespace + "/" + .metadata.name)]]
  | sort_nulls_last[] | [(.[0] | seconds), .[1], .[2]] | @tsv
JQ
)"
pod_filter="$(
  cat <<'JQ'
  [.items[] | (.status.conditions // [] | map(select(.type == "Ready" and .status == "True")) | first) as $ready
    | [($ready.lastTransitionTime | t), (.metadata.creationTimestamp | t), .status.phase,
       (.metadata.namespace + "/" + .metadata.name),
       ((.metadata.ownerReferences // [] | first | if . then .kind + "/" + .name else "-" end))]]
  | sort_nulls_last[] | [(.[0] | seconds), (.[1] | seconds), .[2], .[3], .[4]] | @tsv
JQ
)"
job_filter="$(
  cat <<'JQ'
  [.items[] | [(.status.startTime | t), (.status.completionTime | t), (.status.active // 0), (.status.succeeded // 0),
       (.metadata.namespace + "/" + .metadata.name)]]
  | sort_nulls_last[] | [(.[0] | seconds), (.[1] | seconds), .[2], .[3], .[4]] | @tsv
JQ
)"
pull_filter="$(
  cat <<'JQ'
  [.items[] | [((.lastTimestamp // .eventTime // .metadata.creationTimestamp) | t),
       (.involvedObject.namespace + "/" + .involvedObject.name), .message]]
  | sort_by(-(.[2] | dur))[] | [(.[0] | seconds), .[1], .[2]] | @tsv
JQ
)"

report "Kustomizations by Ready change" $'READY_AT\tREADY\tNAMESPACE/NAME' "$kustomization_filter" \
  kustomizations.kustomize.toolkit.fluxcd.io --all-namespaces
report "Pods by Ready time, not ready last" $'READY_AT\tCREATED\tPHASE\tNAMESPACE/NAME\tOWNER' "$pod_filter" \
  pods --all-namespaces
report "Jobs by start" $'STARTED\tCOMPLETED\tACTIVE\tSUCCEEDED\tNAMESPACE/NAME' "$job_filter" \
  jobs --all-namespaces
report "Image pulls by duration, slowest first" $'PULLED_AT\tNAMESPACE/POD\tKUBELET MESSAGE' "$pull_filter" \
  events --all-namespaces --field-selector reason=Pulled
exit 0
