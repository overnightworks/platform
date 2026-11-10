#!/usr/bin/env bash
# The command behind `mise run cutover:preflight [--live] [--evidence <new file>]`: it reads whether the cutover's
# preconditions hold, in the PC's cluster, in hal's host and in GitHub, and writes nothing but the evidence file.
#   ok <id>: <fact>                          FAIL <id>: <fact>; owner <who>
#   UNKNOWN <id>: <why>; owner <who>         note <id>: not read here: <what>; owner <who>
# Exit 0 when every required condition is ok, 1 when one FAILs, 3 when none FAILs and one is UNKNOWN, 2 on a usage error
# before any read. A FAIL needs a fact the script read; a reader that fails or answers what it cannot read is UNKNOWN.
# Every call is a read: no write verb of kubectl, flux, gh, git or curl, and psql runs in a read-only transaction. No
# line prints a secret, a token or a row.
set -uo pipefail
export LC_ALL=C

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
hal_checkout="$HOME/srv/hal"
edge_state="$HOME/.local/state/edge"
local_edge=http://127.0.0.1:8081
hal_admin=http://127.0.0.1:8090
# How far ahead of now a hal backup timer must not fire; the rehearsal's measured outage replaces it.
outage_window_seconds=14400
# Room per filesystem is this many times the database: its copy, what the load writes beside it (WAL, indexes,
# temporary files) and as much headroom. One filesystem that holds both the dump and the database needs twice that.
room_factor=3
usage_limit_percent=85
sep=$'\x1f'

usage() {
  echo "cutover:preflight: $1; usage: cutover:preflight [--live] [--evidence <new file>]" >&2
  exit 2
}
live=false evidence=""
while [ $# -gt 0 ]; do
  case "$1" in
    --live) live=true ;;
    --evidence)
      { [ $# -ge 2 ] && [ -n "$2" ] && [[ $2 != --* ]]; } || usage "--evidence needs a file"
      evidence="$2"
      shift
      ;;
    *) usage "unknown argument $1" ;;
  esac
  shift
done
if [ -n "$evidence" ]; then
  { [ ! -e "$evidence" ] && [ ! -L "$evidence" ]; } || usage "$evidence exists already"
  parent="${evidence%/*}"
  [ "$parent" != "$evidence" ] || parent=.
  [ -d "$parent" ] || usage "the directory $parent does not exist"
fi

oks=0 fails=0 unknowns=0
declare -A verdict_of=()
current_id="" current_owner=""
problems=() problem_owners=() doubts=() doubt_owners=()
join_by() {
  local separator="$1" first="${2-}"
  shift
  shift || true
  printf '%s' "$first" "${@/#/$separator}"
}
# unique_owners <owner>...: each owner once, in the order first met.
unique_owners() {
  local -A seen=()
  local owner distinct=()
  for owner in "$@"; do
    [ -z "${seen[$owner]:-}" ] || continue
    seen[$owner]=1
    distinct+=("$owner")
  done
  join_by ', ' "${distinct[@]}"
}
begin() {
  current_id="$1" current_owner="$2"
  problems=() problem_owners=() doubts=() doubt_owners=()
}
bad() {
  problems+=("$1")
  problem_owners+=("${2:-$current_owner}")
}
doubt() {
  doubts+=("$1")
  doubt_owners+=("${2:-$current_owner}")
}
# finish <ok fact>: prints the condition's one line. A fact read beats a reader that failed.
finish() {
  if [ "${#problems[@]}" -gt 0 ]; then
    echo "FAIL $current_id: $(join_by '; ' "${problems[@]}"); owner $(unique_owners "${problem_owners[@]}")"
    fails=$((fails + 1))
    verdict_of[$current_id]=FAIL
  elif [ "${#doubts[@]}" -gt 0 ]; then
    echo "UNKNOWN $current_id: $(join_by '; ' "${doubts[@]}"); owner $(unique_owners "${doubt_owners[@]}")"
    unknowns=$((unknowns + 1))
    verdict_of[$current_id]=UNKNOWN
  else
    echo "ok $current_id: $1"
    oks=$((oks + 1))
    verdict_of[$current_id]=ok
  fi
}

# fetch <variable> <command>...: the command's stdout under the deadline; false when it fails. Its stderr is dropped,
# since a message may quote a value.
fetch() {
  local name="$1" captured
  shift
  captured="$(timeout 20 "$@" 2>/dev/null)" || return
  printf -v "$name" %s "$captured"
}
# http_get <curl argument>...: sets http_status, http_content_type, http_redirect and http_body; returns curl's status.
http_get() {
  local output status=0 trailer
  output="$(timeout 20 curl --silent --show-error --max-time 10 --write-out $'\n%{http_code}|%{content_type}|%{redirect_url}' "$@" 2>/dev/null)" || status=$?
  trailer="${output##*$'\n'}"
  http_body="${output%$'\n'*}"
  IFS='|' read -r http_status http_content_type http_redirect <<<"$trailer"
  return "$status"
}
# unreachable <curl status>: the host refused or did not answer, which is a fact about the host and no failed reader.
unreachable() { [ "$1" = 7 ] || [ "$1" = 28 ] || [ "$1" = 124 ]; }
# answered <curl status> <fact when refused> [<subject>]: records a failure when curl read no answer; true when one was read.
answered() {
  if unreachable "$1"; then bad "$2"
  elif [ "$1" != 0 ]; then doubt "curl could not run${3:+ for $3}"
  else return 0; fi
  return 1
}
short() { echo "${1:0:12}"; }
# repository_of <github url>: owner/repo.
repository_of() {
  [[ $1 =~ ^(https://|ssh://git@)github\.com/([^/]+)/([^/]+)$ ]] || return 1
  echo "${BASH_REMATCH[2]}/${BASH_REMATCH[3]%.git}"
}
github_sha=""
# github_head <owner/repo> <branch>: the branch's head commit.
github_head() {
  fetch github_sha gh api "repos/$1/commits/$2" --jq .sha && [[ $github_sha =~ ^[0-9a-f]{40}$ ]]
}

declare -A source_commit=() source_repository=() kustomization_path=() kustomization_revision=()

check_N1() {
  begin N1 platform
  local nodes problem_lines
  if ! fetch nodes kubectl get nodes --output json; then
    doubt "kubectl get nodes failed"
  elif ! problem_lines="$(jq -r '
      if (.items | length) == 0 then "U no node" else
        .items[] | .metadata.name as $node
        | [.status.conditions[]? | select(.type | IN("Ready", "MemoryPressure", "DiskPressure", "PIDPressure"))] as $conditions
        | if ($conditions | length) != 4 then "U \($node) lacks a condition" else
            $conditions[] | select((.type == "Ready" and .status != "True") or (.type != "Ready" and .status != "False"))
            | "F \($node) \(.type)=\(.status)" end
      end' <<<"$nodes")"; then
    doubt "the node list is unreadable"
  else
    local kind text
    while IFS=' ' read -r kind text; do
      [ -n "$kind" ] || continue
      if [ "$kind" = F ]; then bad "node $text"; else doubt "$text"; fi
    done <<<"$problem_lines"
  fi
  finish "every node is Ready with no memory, disk or PID pressure"
}

check_N2() {
  begin N2 platform
  local gitrepositories lines key ready generation observed revision url branch interval repository commit
  if ! fetch gitrepositories kubectl get gitrepositories.source.toolkit.fluxcd.io --all-namespaces --output json ||
    ! lines="$(jq -r --arg sep "$sep" '.items[] | [.metadata.namespace + "/" + .metadata.name,
        ([.status.conditions[]? | select(.type == "Ready")][0].status // ""), (.metadata.generation | tostring),
        (.status.observedGeneration // "" | tostring), (.status.artifact.revision // ""), (.spec.url // ""),
        (.spec.ref.branch // ""), (.spec.interval // "")] | join($sep)' <<<"$gitrepositories")"; then
    doubt "the GitRepositories are unreadable"
  elif [ -z "$lines" ]; then
    doubt "the cluster holds no GitRepository"
  else
    while IFS="$sep" read -r key ready generation observed revision url branch interval; do
      commit="${revision##*:}"
      source_commit[$key]="$commit"
      [ "$ready" = True ] || bad "$key is not Ready" "$key"
      [ "$generation" = "$observed" ] || bad "$key observed generation $observed of $generation" "$key"
      if ! repository="$(repository_of "$url")"; then
        doubt "$key url is not on github.com" "$key"
        continue
      fi
      source_repository[$key]="$repository"
      if [ -z "$branch" ]; then
        doubt "$key follows no branch" "$repository"
      elif ! github_head "$repository" "$branch"; then
        doubt "gh could not read the head of $repository" "$repository"
      elif [ "$commit" != "$github_sha" ]; then
        bad "$key is at $(short "$commit") but $repository $branch is at $(short "$github_sha") (interval $interval)" "$repository"
      fi
    done <<<"$lines"
  fi
  finish "${#source_commit[@]} GitRepositories are at their branch heads"
}

check_N3() {
  begin N3 platform
  local kustomizations lines key suspended ready generation observed revision path kind source_name source_namespace
  if ! fetch kustomizations kubectl get kustomizations.kustomize.toolkit.fluxcd.io --all-namespaces --output json ||
    ! lines="$(jq -r --arg sep "$sep" '.items[] | [.metadata.namespace + "/" + .metadata.name, (.spec.suspend // false | tostring),
        ([.status.conditions[]? | select(.type == "Ready")][0].status // ""), (.metadata.generation | tostring),
        (.status.observedGeneration // "" | tostring), (.status.lastAppliedRevision // ""), (.spec.path // ""),
        (.spec.sourceRef.kind // ""), (.spec.sourceRef.name // ""),
        (.spec.sourceRef.namespace // .metadata.namespace)] | join($sep)' <<<"$kustomizations")"; then
    doubt "the Kustomizations are unreadable"
  elif [ -z "$lines" ]; then
    doubt "the cluster holds no Kustomization"
  else
    while IFS="$sep" read -r key suspended ready generation observed revision path kind source_name source_namespace; do
      kustomization_path[$key]="$path"
      kustomization_revision[$key]="${revision##*:}"
      [ "$suspended" = false ] || bad "$key is suspended" "${key#*/}"
      [ "$ready" = True ] || bad "$key is not Ready" "${key#*/}"
      [ "$generation" = "$observed" ] || bad "$key observed generation $observed of $generation" "${key#*/}"
      if [ "$kind" != GitRepository ] || [ -z "${source_commit[$source_namespace/$source_name]:-}" ]; then
        doubt "$key has the source $kind $source_namespace/$source_name, which N2 did not read" "${key#*/}"
      elif [ "${revision##*:}" != "${source_commit[$source_namespace/$source_name]}" ]; then
        bad "$key applied $(short "${revision##*:}") but its source is at $(short "${source_commit[$source_namespace/$source_name]}")" "${key#*/}"
      fi
    done <<<"$lines"
  fi
  finish "${#kustomization_path[@]} Kustomizations applied their source's commit"
}

platform_commit=""
check_N4() {
  begin N4 platform
  local tree="" head="" applied="${kustomization_revision[flux-system/flux-system]:-}"
  if ! fetch tree git -C "$root" --no-optional-locks status --porcelain || ! fetch head git -C "$root" rev-parse HEAD; then
    doubt "git could not read this checkout"
  elif [ -z "$applied" ]; then
    doubt "the Kustomization flux-system has no applied commit"
  else
    [ -z "$tree" ] || bad "this checkout has $(grep -c . <<<"$tree") uncommitted paths"
    [ "$head" = "$applied" ] || bad "this checkout is at $(short "$head") but Flux applied $(short "$applied")"
    platform_commit="$head"
  fi
  finish "this checkout is clean at the applied commit $(short "$head")"
}

# render_of <Kustomization name>: the objects Flux applies for it, one JSON array, without writing into the checkout.
render_of() {
  local path="${kustomization_path[flux-system/$1]:-}"
  [ -n "$path" ] || return 1
  timeout 60 flux build kustomization "$1" --path "$root/${path#./}" --in-memory-build 2>/dev/null |
    yq --output-format json '.' | jq --slurp .
}

keycloak_render="[]"
# NetworkPolicies of one namespace by namespace/name, each .spec as the API server stores it.
policy_index='
  def normalised:
    .spec
    | with_entries(select(.value != []))
    | .policyTypes //= (["Ingress"] + (if has("egress") then ["Egress"] else [] end))
    | (.ingress[]?.ports[]?, .egress[]?.ports[]?) |= (.protocol //= "TCP");
  [.[] | select(type == "object" and .kind == "NetworkPolicy")
    | select((.metadata.namespace // $namespace) == $namespace)
    | {key: "\($namespace)/\(.metadata.name)", value: normalised}] | from_entries'
policy_differences='
  ($committed | keys) as $names | ($live | keys) as $present
  | (($names - $present)[] | "missing " + .),
    (($present - $names)[] | "extra " + .),
    ($names[] | select(. as $name | $live | has($name)) | select($committed[.] != $live[.]) | "differs " + .)'
check_I1() {
  begin I1 "platform, the layer"
  local namespace render live committed crds line names compared=()
  if [ "${verdict_of[N4]:-}" != ok ]; then
    doubt "cannot compare: checkout is not the applied commit"
  elif fetch crds kubectl get customresourcedefinitions.apiextensions.k8s.io \
    adminnetworkpolicies.policy.networking.k8s.io baselineadminnetworkpolicies.policy.networking.k8s.io \
    --ignore-not-found --output name; then
    [ -z "$crds" ] || doubt "an admin-policy CRD exists: $crds"
    for namespace in keycloak litellm hopin; do
      if ! render="$(render_of "$namespace")" ||
        ! fetch live kubectl --namespace "$namespace" get networkpolicies --output json; then
        doubt "the render or the read of namespace $namespace failed"
        continue
      fi
      [ "$namespace" != keycloak ] || keycloak_render="$render"
      if ! committed="$(jq -S --arg namespace "$namespace" "$policy_index" <<<"$render")" ||
        ! live="$(jq '.items' <<<"$live" | jq -S --arg namespace "$namespace" "$policy_index")"; then
        doubt "the policies of namespace $namespace are unreadable"
        continue
      fi
      while IFS= read -r line; do
        [ -z "$line" ] || bad "$line"
      done < <(jq -n -r --argjson committed "$committed" --argjson live "$live" "$policy_differences")
      mapfile -t names < <(jq -r 'keys[]' <<<"$committed")
      compared+=("${names[@]}")
    done
  else
    doubt "the admin-policy CRDs are unreadable"
  fi
  finish "the policies equal the committed ones: ${compared[*]}"
}

tunnel_has_auth=""
check_I2() {
  begin I2 platform
  local render live_config deployment rendered_hash live_hash empty_hash hostnames annotated
  empty_hash="$(printf '' | sha256sum)"
  if [ "${verdict_of[N4]:-}" != ok ]; then
    doubt "cannot compare: checkout is not the applied commit"
  elif ! render="$(render_of tunnel)" ||
    ! fetch live_config kubectl --namespace cloudflared get configmap cloudflared --output json ||
    ! fetch deployment kubectl --namespace cloudflared get deployment cloudflared --output json; then
    doubt "the render or the read of the tunnel failed"
  else
    rendered_hash="$(jq -j '[.[] | select(.kind == "ConfigMap" and .metadata.name == "cloudflared")][0].data["config.yaml"] // ""' <<<"$render" | sha256sum)"
    live_hash="$(jq -j '.data["config.yaml"] // ""' <<<"$live_config" | sha256sum)"
    annotated="$(jq -r '.spec.template.metadata.annotations["checksum/config"] // ""' <<<"$deployment")"
    if [ "$live_hash" = "$empty_hash" ] || [ "$rendered_hash" = "$empty_hash" ]; then
      doubt "the render or the ConfigMap holds no config.yaml"
    else
      [ "$rendered_hash" = "$live_hash" ] || bad "the ConfigMap cloudflared differs from the render of Kustomization tunnel"
      [ "$annotated" = "${live_hash%% *}" ] || bad "the Deployment's checksum/config is not the hash of the ConfigMap's lines"
      jq -e '.status.observedGeneration == .metadata.generation and .status.updatedReplicas == .spec.replicas' \
        <<<"$deployment" >/dev/null || bad "the Deployment cloudflared has not rolled out its template"
    fi
    hostnames="$(jq -j '.data["config.yaml"] // ""' <<<"$live_config" | yq '.ingress[] | select(has("hostname")) | .hostname' | paste -sd, -)"
    case ",$hostnames" in *,auth.*) tunnel_has_auth="auth is among them" ;; *) tunnel_has_auth="auth is not among them" ;; esac
  fi
  finish "the tunnel serves the committed lines for ${hostnames:-no host}; $tunnel_has_auth"
}

realm=$(yq '.realm' "$root/infrastructure/keycloak/realm.yaml")
kc_hostname=""
check_H1() {
  begin H1 "hal's head"
  local status=0
  kc_hostname="$(jq -r '[.. | objects | select(.name? == "KC_HOSTNAME") | .value?][0] // ""' <<<"$keycloak_render" 2>/dev/null)"
  if [ -e "$edge_state/stopped/keycloak" ]; then
    bad "hal's Keycloak is switched off by its marker"
  elif [ -z "$kc_hostname" ]; then
    doubt "KC_HOSTNAME is unknown, since I1 rendered no keycloak"
  else
    http_get --header "Host: ${kc_hostname#*://}" "$local_edge/realms/$realm/.well-known/openid-configuration" || status=$?
    if ! answered "$status" "hal's Keycloak does not answer at $local_edge"; then :
    elif [ "$http_status" != 200 ]; then
      bad "hal's discovery answers $http_status"
    elif [ "$(jq -r '.issuer // ""' <<<"$http_body")" != "$kc_hostname/realms/$realm" ]; then
      bad "hal's discovery names another issuer"
    fi
  fi
  finish "hal's Keycloak answers its discovery for $kc_hostname/realms/$realm and is not switched off"
}

check_H2() {
  begin H2 "hal's head"
  local zone fleet lines name ready target fqdn status checked=0
  zone="$(yq 'select(.kind == "Ingress") | .spec.rules[0].host' "$root/infrastructure/legal/legal.yaml")"
  if ! fleet="$(yq --output-format json '.' "$hal_checkout/fleet.yaml" 2>/dev/null)" ||
    ! lines="$(jq -r --arg sep "$sep" '.services[]?.hosts[]? | select(has("ready") and (has("tunnel") | not))
        | [.name, .ready, (.target // "http://127.0.0.1:8081")] | join($sep)' <<<"$fleet")"; then
    doubt "fleet.yaml is unreadable"
  else
    while IFS="$sep" read -r name ready target; do
      [ -n "$name" ] || continue
      fqdn="$name.$zone"
      [ "$name" != "@" ] || fqdn="$zone"
      status=0
      http_get --output /dev/null --header "Host: $fqdn" "$target$ready" || status=$?
      checked=$((checked + 1))
      if ! answered "$status" "$fqdn is refused or times out" "$fqdn"; then :
      elif [[ ! $http_status =~ ^2 ]]; then
        bad "$fqdn answers $http_status"
      fi
    done <<<"$lines"
    [ "$checked" -gt 0 ] || doubt "fleet.yaml names no host with a ready path"
  fi
  finish "$checked hosts answer 2xx"
}

check_H3() {
  begin H3 "hal's head"
  local status=0
  http_get --output /dev/null --header "Host: localhost:${hal_admin##*:}" "$hal_admin/admin/" || status=$?
  if ! answered "$status" "hal's admin console does not answer at $hal_admin"; then :
  elif [ "$http_status" != 200 ] && ! { [[ $http_status =~ ^3 ]] && [[ $http_redirect =~ ^https?://[^/]+/admin/ ]]; }; then
    bad "hal's admin console answers $http_status"
  fi
  finish "hal's admin console answers"
}

# discovery_of <base url> [<host header>]: sets discovery_issuer and discovery_kids (sorted); false when a read fails,
# with discovery_curl the status of the curl that failed, 0 for an answer that is no discovery.
discovery_of() {
  local base="$1" headers=() jwks_path
  [ -z "${2-}" ] || headers=(--header "Host: $2")
  discovery_curl=0
  http_get "${headers[@]}" "$base/realms/$realm/.well-known/openid-configuration" || { discovery_curl=$?; return 1; }
  [ "$http_status" = 200 ] || return 1
  discovery_issuer="$(jq -r '.issuer // ""' <<<"$http_body")" || return 1
  [[ "$(jq -r '.jwks_uri // ""' <<<"$http_body")" =~ ^https?://[^/]+(/.*)$ ]] || return 1
  jwks_path="${BASH_REMATCH[1]}"
  http_get "${headers[@]}" "$base$jwks_path" || { discovery_curl=$?; return 1; }
  [ "$http_status" = 200 ] || return 1
  discovery_kids="$(jq -r '[.keys[]?.kid] | sort[]' <<<"$http_body")" || return 1
}
evidence_issuer="" evidence_kids=""
check_H4() {
  begin H4 "hal's head"
  local public_issuer public_kids
  if [ -z "$kc_hostname" ]; then
    doubt "KC_HOSTNAME is unknown, since I1 rendered no keycloak"
  elif ! discovery_of "$kc_hostname"; then
    doubt "the public discovery or its keys are unreadable; run again"
  else
    public_issuer="$discovery_issuer" public_kids="$discovery_kids"
    if ! discovery_of "$local_edge" "${kc_hostname#*://}"; then
      if [ "$discovery_curl" = 0 ] || unreachable "$discovery_curl"; then
        bad "hal's own discovery or keys are not served at $local_edge"
      else
        doubt "curl could not run"
      fi
    elif [ -z "$public_issuer" ] || [ -z "$public_kids" ] || [ -z "$discovery_issuer" ] || [ -z "$discovery_kids" ]; then
      bad "an issuer or key set is empty"
    else
      [ "$public_issuer" = "$discovery_issuer" ] || bad "the public issuer differs from hal's own"
      [ "$public_kids" = "$discovery_kids" ] || bad "the public key ids differ from hal's own"
      evidence_issuer="$public_issuer" evidence_kids="$public_kids"
    fi
  fi
  finish "the public issuer and its $(grep -c . <<<"$evidence_kids") key ids equal hal's own"
}

hal_main=""
check_H5() {
  begin H5 "hal's head; operator"
  local tree branch head origin repository
  if ! fetch tree git -C "$hal_checkout" --no-optional-locks status --porcelain ||
    ! fetch branch git -C "$hal_checkout" symbolic-ref --short HEAD ||
    ! fetch head git -C "$hal_checkout" rev-parse HEAD ||
    ! fetch origin git -C "$hal_checkout" remote get-url origin ||
    ! repository="$(repository_of "$origin")" || ! github_head "$repository" main; then
    doubt "git or gh could not read hal's checkout or main"
  else
    [ -z "$tree" ] || bad "hal's checkout has $(grep -c . <<<"$tree") uncommitted paths"
    [ "$branch" = main ] || bad "hal's checkout is on $branch"
    [ "$head" = "$github_sha" ] || bad "hal's checkout is at $(short "$head") but $repository main is at $(short "$github_sha")"
    hal_main="$head"
  fi
  finish "hal's checkout is clean at main $hal_main"
}

check_D1() {
  begin D1 "platform; operator frees space"
  local containers size usage line lines avail percent target need same
  if ! fetch containers docker ps --all --quiet --no-trunc \
    --filter label=com.docker.compose.project=hal --filter label=com.docker.compose.service=keycloak-db \
    --filter label=com.docker.compose.oneoff=False || [ "$(grep -c . <<<"$containers")" != 1 ]; then
    doubt "docker did not list exactly one keycloak-db container"
  elif ! fetch size docker exec --env 'PGOPTIONS=-c default_transaction_read_only=on' "$containers" \
    psql --username=keycloak --dbname=keycloak --no-psqlrc -Atc 'select pg_database_size(current_database())' ||
    [[ ! $size =~ ^[0-9]+$ ]]; then
    doubt "the size of hal's keycloak database is unreadable"
  elif ! fetch usage df --block-size=1 --output=avail,pcent,target "$HOME" /opt/local-path-provisioner; then
    doubt "df failed"
  else
    mapfile -t lines < <(tail -n +2 <<<"$usage")
    same=false
    [ "${#lines[@]}" = 2 ] || { doubt "df printed ${#lines[@]} lines for two paths"; finish ""; return; }
    [ "${lines[0]##* }" != "${lines[1]##* }" ] || same=true
    need=$((size * room_factor))
    [ "$same" = false ] || need=$((need * 2))
    for line in "${lines[@]}"; do
      read -r avail percent target <<<"$line"
      percent="${percent%\%}"
      [[ $avail =~ ^[0-9]+$ && $percent =~ ^[0-9]+$ ]] || { doubt "df printed an unreadable line"; continue; }
      [ "$avail" -ge "$need" ] || bad "$target has $avail bytes free, needs $need"
      [ "$percent" -lt "$usage_limit_percent" ] || bad "$target is at $percent %"
    done
  fi
  finish "the home directory and the volume path have room for a database of ${size:-0} bytes"
}

check_B1() {
  begin B1 "k8up; the Job's layer"
  local k8up jobs line
  if ! fetch k8up kubectl get backups,restores,checks,prunes,archives.k8up.io --all-namespaces --output json ||
    ! fetch jobs kubectl get jobs --all-namespaces --output json; then
    doubt "the k8up objects or the Jobs are unreadable"
  else
    while IFS= read -r line; do
      [ -z "$line" ] || bad "$line running" "k8up"
    done < <(jq -r '.items[] | select(.status.started and (.status.finished | not)) | "\(.kind) \(.metadata.namespace)/\(.metadata.name)"' <<<"$k8up")
    while IFS= read -r line; do
      [ -z "$line" ] || bad "$line running" "the Job's layer"
    done < <(jq -r '.items[] | select((.status.active // 0) > 0) | "Job \(.metadata.namespace)/\(.metadata.name)"' <<<"$jobs")
  fi
  finish "no platform backup, restore or Job runs"
}

check_B2() {
  begin B2 "hal's head"
  local lock="$edge_state/backup.lock" identity locks entries line unit properties load state now next
  if [ -e "$lock" ]; then
    if ! fetch identity stat -c '%i %Hd:%Ld' "$lock" ||
      ! fetch locks lslocks --json --output PID,INODE,MAJ:MIN,BLOCKER; then
      doubt "stat or lslocks failed"
    elif ! entries="$(jq -r --arg inode "${identity%% *}" --arg device "${identity##* }" '
        .locks[]? | select((.inode | tostring) == $inode and .["maj:min"] == $device)
        | "pid \(.pid) \(if (.blocker | tostring) | test("^[1-9]") then "waits for" else "holds" end) the lock"' <<<"$locks")"; then
      doubt "lslocks printed what cannot be read"
    else
      while IFS= read -r line; do
        [ -z "$line" ] || bad "$line"
      done <<<"$entries"
    fi
  fi
  for unit in hal-backup.service hal-backup-restore-test.service; do
    if ! fetch properties systemctl --user show "$unit" --property=ActiveState --property=LoadState; then
      doubt "systemctl could not read $unit"
    else
      load="$(sed -n 's/^LoadState=//p' <<<"$properties")"
      state="$(sed -n 's/^ActiveState=//p' <<<"$properties")"
      if [ "$load" = not-found ]; then
        doubt "$unit is not loaded"
      elif [ "$state" = active ] || [ "$state" = activating ]; then
        bad "$unit is $state"
      fi
    fi
  done
  now="$(date +%s)"
  for unit in hal-backup.timer hal-backup-restore-test.timer; do
    if ! fetch next systemctl --user show "$unit" --property=NextElapseUSecRealtime --value --timestamp=unix; then
      doubt "systemctl could not read $unit"
    elif [ -z "$next" ]; then
      continue
    elif [[ $next =~ ^@([0-9]+)$ ]]; then
      [ "${BASH_REMATCH[1]}" -gt $((now + outage_window_seconds)) ] ||
        bad "$unit fires at $(date --utc --date="@${BASH_REMATCH[1]}" +%Y-%m-%dT%H:%M:%SZ), inside the window of $outage_window_seconds seconds"
    else
      doubt "$unit has a next time that cannot be read"
    fi
  done
  finish "no hal backup or restore holds or waits for the lock, runs or is due within $((outage_window_seconds / 3600)) hours"
}

forward_pid=""
stop_forward() {
  [ -z "$forward_pid" ] || kill "$forward_pid" 2>/dev/null
  forward_pid=""
}
trap stop_forward EXIT
check_L1() {
  begin L1 '#4'
  local redirect_uri line port="" status=0 page theme stylesheet
  redirect_uri="$(CLIENT=hopin yq '.clients[] | select(.clientId == strenv(CLIENT)) | .redirectUris[0]' "$root/infrastructure/keycloak/realm.yaml")"
  coproc FORWARD { exec kubectl --namespace keycloak port-forward --address 127.0.0.1 service/keycloak :http 2>/dev/null; }
  forward_pid="${FORWARD_PID:-}"
  if [ -n "$forward_pid" ] && [ -n "${FORWARD[0]:-}" ]; then
    while IFS= read -r -t 20 -u "${FORWARD[0]}" line; do
      [[ $line =~ 127\.0\.0\.1:([0-9]+) ]] && { port="${BASH_REMATCH[1]}"; break; }
    done
  fi
  if [ -z "$port" ]; then
    doubt "the port-forward to Keycloak did not start or ended at once"
  else
    http_get --get --data-urlencode "client_id=hopin" --data-urlencode "redirect_uri=$redirect_uri" \
      --data response_type=code --data scope=openid --data code_challenge_method=S256 \
      --data "code_challenge=$(printf '%043d' 0)" "http://127.0.0.1:$port/realms/$realm/protocol/openid-connect/auth" || status=$?
    page="$http_body"
    if [ "$status" != 0 ]; then
      doubt "curl could not read the login page"
    elif [ "$http_status" != 200 ]; then
      bad "the login page answers $http_status"
    else
      theme="$(grep -o '/resources/[a-z0-9]\{5\}/login/[^/"]*/' <<<"$page" | head -n 1)"
      if [ -z "$theme" ]; then
        bad "the login page names no theme path"
      elif [[ $theme != */login/hallucinai/ ]]; then
        bad "Keycloak serves the theme ${theme#*/login/}, not hallucinai"
      else
        stylesheet="$(grep -o "${theme}[^\"?]*\.css" <<<"$page" | head -n 1)"
        if [ -z "$stylesheet" ]; then
          bad "the login page names no stylesheet of the theme"
        elif ! http_get --output /dev/null "http://127.0.0.1:$port$stylesheet"; then
          doubt "curl could not read the stylesheet"
        elif [ "$http_status" != 200 ] || [[ $http_content_type != text/css* ]]; then
          bad "the theme's stylesheet answers $http_status as ${http_content_type:-no type}"
        fi
      fi
    fi
  fi
  stop_forward
  finish "Keycloak serves the theme hallucinai with a stylesheet"
}

check_L2() {
  begin L2 '#13'
  local repository="${source_repository[flux-system/platform-secrets]:-}" content counts
  if [ -z "$repository" ]; then
    doubt "N2 did not read the repository of platform-secrets"
  elif ! fetch content gh api "repos/$repository/contents/.sops.yaml" --jq .content ||
    ! counts="$(base64 --decode <<<"$content" | yq --output-format json '.creation_rules' |
      jq -r '[.[] | (.age // "") | split(",") | map(gsub("\\s"; "") | select(length > 0)) | length] | join(" ")')" ||
    [ -z "$counts" ]; then
    doubt "the creation rules of platform-secrets are unreadable"
  else
    local count position=0
    for count in $counts; do
      position=$((position + 1))
      [ "$count" -ge 2 ] || bad "creation rule $position has $count age recipient(s)"
    done
  fi
  finish "every creation rule of platform-secrets has at least 2 age recipients"
}

check_N1
check_N2
check_N3
check_N4
check_I1
check_I2
check_H1
check_H2
check_H3
check_H4
check_H5
check_D1
check_B1
check_B2
if [ "$live" = true ]; then
  check_L1
  check_L2
fi

note() { echo "note $1: not read here: $2; owner $3"; }
note pod-logs "mise run check:pod-logs; the head journals its exit at step 1" operator
note record "where Cloudflare's auth record points (hal check hosts)" "hal's head"
note provider-keys "whether the real keys work (step 13)" operator
note hopin-key "whether Secret hopin holds the imported key (step 3)" platform
note profile "the live user profile (slice 2's gate on the dump)" platform
note hal-plan "hal's update and apply plans (step 9's readings)" "operator; hal's head"
note recovery "whether the second age key can be recovered offline" "#13"
note docker-disk "Docker's own disk accounting" operator
note sessions "writes by real sessions" "n/a"

written=none
if [ -n "$evidence" ] && [ "$fails" = 0 ] && [ "$unknowns" = 0 ]; then
  mapfile -t evidence_kid_list <<<"$evidence_kids"
  if (
    umask 077
    set -o noclobber
    {
      printf 'issuer %s\n' "$evidence_issuer"
      printf 'kid %s\n' "${evidence_kid_list[@]}"
      printf 'hal-main %s\n' "$hal_main"
      printf 'platform %s\n' "$platform_commit"
      printf 'read-at %s\n' "$(date --utc +%Y-%m-%dT%H:%M:%SZ)"
    } >"$evidence"
  ) 2>/dev/null; then
    written="$evidence"
  else
    echo "FAIL E1: the evidence file $evidence appeared or could not be written; owner operator"
    fails=$((fails + 1))
  fi
fi

echo "cutover:preflight: $oks ok, $fails FAIL, $unknowns UNKNOWN; evidence $written"
[ "$fails" = 0 ] || exit 1
[ "$unknowns" = 0 ] || exit 3
