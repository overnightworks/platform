#!/usr/bin/env bash
# The commands behind `mise run litellm:keys`, `mise run litellm:key` and `mise run litellm:admin`: the first two make the
# budgets and the app keys of LiteLLM in namespace litellm equal to the table infrastructure/litellm/keys.yaml, which the
# ConfigMap litellm-keys carries.
#   scripts/litellm_keys.sh keys [--plan]  sends only the fields that differ; --plan writes nothing and exits 0 with no
#                                          change, 2 with changes, 1 on a failure or a table row without a key
#   scripts/litellm_keys.sh key <app>      registers the value of key litellm_key in Secret <app> of namespace <app> as
#                                          the key of the table's row <app>
#   scripts/litellm_keys.sh admin <user>   puts the person on the unlimited admin budget and into the admin group of
#                                          Keycloak, each step written and read back
# A key's value and the master key travel from kubectl's stdout through shell variables to curl's stdin, never into an
# argument, a URL, a file or a child's environment, and are never printed. A failure names the step and the HTTP
# status, never a reply body.
# Tracing would print every decoded value, so it ends before any is read, without a line of its own.
{ set +x; } 2>/dev/null
set -euo pipefail
# [!-~] must mean printable ASCII.
export LC_ALL=C
# shellcheck source=keycloak_kcadm.sh
source "$(dirname "${BASH_SOURCE[0]}")/keycloak_kcadm.sh"

namespace=litellm
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
# A kubectl call ends past the deadline, as a hung cluster would otherwise hold the command forever.
deadline=2m
# LiteLLM refuses a chosen key value that lacks this prefix or is shorter.
key_prefix=sk-
key_minimum_length=16

exec {kcadm_diagnostics_fd}>/dev/null {kcadm_update_output_fd}>/dev/null
command_name="" task_name=litellm:admin realm="" username="" reported=false
# The admin command's writes, each recorded before it is sent, since an answer lost on the way leaves it unknown.
attempted=()
# written_list: what the admin command wrote or may have written.
written_list() {
  local written
  written="$(printf '%s, ' "${attempted[@]}")"
  echo "${written%, }"
}
# written_text: the list as a failure reports it, with how to finish.
written_text() { echo "written or possibly written: $(written_list); run again to complete it"; }
fail() {
  local suffix=""
  if [ "$command_name" = admin ]; then
    if [ "${#attempted[@]}" = 0 ]; then suffix="; nothing changed"; else suffix="; $(written_text)"; fi
  fi
  reported=true
  echo "litellm:${command_name:-keys}: $1$suffix" >&2
  exit 1
}
# bounded <step> <command>...: runs the command under the deadline; fails naming the step when it fails or runs out.
bounded() {
  local step="$1" status=0
  shift
  timeout "$deadline" "$@" 2>/dev/null || status=$?
  [ "$status" != 124 ] || fail "$step did not end within $deadline, the local deadline"
  [ "$status" = 0 ] || fail "$step failed"
}
# in_cluster <step> <kubectl argument>...: kubectl's stdout; its stderr stays hidden, since a message may quote a value.
in_cluster() {
  local step="$1"
  shift
  bounded "$step" kubectl "$@"
}
# json <yq expression>...: yq over the last reply.
json() { printf '%s' "$reply" | yq --input-format json "$@"; }

scratch="$(mktemp -d)"
forwards=()
# on_exit: ends the port-forwards and the Keycloak sign-in; an admin run that sent a write and ends without having said
# so (a signal) names it.
on_exit() {
  local exit_status=$? pid
  if [ "$command_name" = admin ] && [ "$reported" = false ] && [ "$exit_status" != 0 ] && [ "${#attempted[@]}" != 0 ]; then
    echo "litellm:admin: interrupted; $(written_text)" >&2
  fi
  for pid in "${forwards[@]}"; do kill "$pid" 2>/dev/null || true; done
  remove_config
  rm -rf "$scratch"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# decode <base64>: sets decoded to the exact bytes, through a pipe so that no file holds them; the sentinel keeps the
# command substitution from stripping a trailing newline, which validation must see.
decoded=""
decode() {
  decoded="$(printf '%s' "$1" | base64 --decode && printf x)" || return 1
  decoded="${decoded%x}"
}
# quote_inner <text>: the text as the inside of a double-quoted curl config value or JSON string; the callers hold only
# printable ASCII.
quote_inner() {
  local text="${1//\\/\\\\}"
  printf '%s' "${text//\"/\\\"}"
}

reply="" status="" failure=""
# request <step> <path> [<body> [discard]]: a GET without a body, a POST with one, authorized by the master key on
# curl's stdin; sets status and reply, with discard the reply goes nowhere. Returns 1 with failure naming the step and
# the status when the status is not 200.
request() {
  local step="$1" path="$2" body="${3-}" config result
  local -a sink=()
  config="header = \"Authorization: Bearer $(quote_inner "$master_key")\""
  if [ -n "$body" ]; then
    config+=$'\nheader = "Content-Type: application/json"\ndata = "'"$(quote_inner "$body")"'"'
  fi
  [ -z "${4-}" ] || sink=(--output /dev/null)
  result="$(printf '%s\n' "$config" | curl --silent --max-time 60 --config - "${sink[@]}" \
    --write-out '\n%{http_code}' "http://127.0.0.1:$local_port$path")" || result=$'\n000'
  status="${result##*$'\n'}"
  reply="${result%"$status"}"
  [ "$status" = 200 ] || {
    failure="$step answered with status $status, not 200"
    return 1
  }
}
# ask <request argument>...: request, ending the command on a failure.
ask() { request "$@" || fail "$failure"; }

# start_forward <namespace> <service> <port>: port-forwards the Service to a free local port, which it sets as
# forwarded_port.
start_forward() {
  local pid log="$scratch/forward-$2.log"
  : >"$log"
  timeout 10m kubectl --namespace "$1" port-forward "service/$2" ":$3" >"$log" 2>&1 &
  pid=$!
  forwards+=("$pid")
  forwarded_port=""
  for _ in $(seq 30); do
    forwarded_port="$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9]*\) .*/\1/p' "$log" | head -n 1)"
    [ -z "$forwarded_port" ] || break
    kill -0 "$pid" 2>/dev/null || fail "kubectl port-forward to the Service $2 ended"
    sleep 1
  done
  [ -n "$forwarded_port" ] || fail "kubectl port-forward to the Service $2 did not start within 30 seconds"
}
# connect: reads the master key and starts the port-forward to LiteLLM; sets master_key and local_port.
connect() {
  local secret_data port
  secret_data="$(in_cluster "reading the Secret litellm" --namespace "$namespace" get secret litellm \
    -o jsonpath='{.data.master_key}')"
  decode "$secret_data" || fail "the Secret litellm gives no readable master_key"
  master_key="$decoded"
  [ -n "$master_key" ] || fail "the Secret litellm holds an empty master_key"
  port="$(in_cluster "reading the Service litellm" --namespace "$namespace" get service litellm \
    -o jsonpath='{.spec.ports[0].port}')"
  start_forward "$namespace" litellm "$port"
  local_port="$forwarded_port"
}

# applied_revision: the Git revision Flux applied to the layer.
applied_revision() {
  in_cluster "reading the Kustomization litellm" --namespace flux-system get kustomization litellm \
    -o jsonpath='{.status.lastAppliedRevision}'
}
# is_number <yq tag>: whether the tag names a number.
is_number() { [ "$1" = '!!int' ] || [ "$1" = '!!float' ]; }
# check_table: refuses a table whose person budget or any row's budget or parallel limit is no number, whose apps are no
# map of rows or whose names are no namespace names, naming the row; sets app_names, the rows' names in order.
check_table() {
  local rows name row_tag budget_tag parallel_tag
  app_names=()
  budget_tag="$(yq '.person_budget | tag' <<<"$table")" || fail "the table is no YAML"
  is_number "$budget_tag" || fail "the table's person_budget is no number"
  rows="$(yq '.apps | select(tag == "!!map") | to_entries | sort_by(.key) | .[] | .key + " " + (.value | tag) + " " +
    ((.value | select(tag == "!!map") | .budget | tag) // "none") + " " +
    ((.value | select(tag == "!!map") | .parallel | tag) // "none")' <<<"$table")" || fail "the table is no YAML"
  [ -n "$rows" ] || fail "the table's apps are no map with a row"
  while read -r name row_tag budget_tag parallel_tag; do
    [[ $name =~ ^[a-z0-9-]+$ ]] || fail "the table names the app '$name', which is no namespace name"
    [ "$row_tag" = '!!map' ] || fail "the table's row $name is no map"
    is_number "$budget_tag" || fail "the table's row $name has no number budget"
    [ "$parallel_tag" = '!!int' ] || fail "the table's row $name has no whole number parallel"
    app_names+=("$name")
  done <<<"$rows"
}

# read_table: sets table, the ConfigMap litellm-keys' table, checked, with the Git revision Flux applied to it, which is
# refused when absent or changed while the table was read, and the settings every row shares from their one owners:
# period, budget_id (litellm-config.yaml), routes (front-route.yml) and models (as LiteLLM lists them).
read_table() {
  local config_map config revision
  revision="$(applied_revision)"
  [ -n "$revision" ] || fail "the Kustomization litellm has applied no revision"
  table="$(in_cluster "reading the ConfigMap litellm-keys" --namespace "$namespace" get configmap litellm-keys \
    -o jsonpath='{.data.keys\.yaml}')"
  [ "$(applied_revision)" = "$revision" ] || fail "the Kustomization litellm applied another revision while the table was read"
  echo "litellm:$command_name: table of revision $revision"
  check_table
  period="$(yq '.period' <<<"$table")"
  [[ $period =~ ^[0-9]+[a-z]+$ ]] || fail "the table's period '$period' is not a LiteLLM duration"
  config_map="$(in_cluster "reading the Deployment litellm" --namespace "$namespace" get deployment litellm \
    -o jsonpath='{.spec.template.spec.volumes[?(@.name=="config")].configMap.name}')"
  config="$(in_cluster "reading LiteLLM's configuration" --namespace "$namespace" get configmap "$config_map" \
    -o jsonpath='{.data.config\.yaml}')"
  budget_id="$(yq '.litellm_settings.max_end_user_budget_id' <<<"$config")"
  [[ $budget_id =~ ^[A-Za-z0-9_-]+$ ]] || fail "LiteLLM's configuration names no person budget id"
  config_map="$(in_cluster "reading the Deployment litellm-front" --namespace "$namespace" get deployment \
    litellm-front -o jsonpath='{.spec.template.spec.volumes[?(@.name=="routes")].configMap.name}')"
  routes="$(in_cluster "reading the front's routes" --namespace "$namespace" get configmap "$config_map" \
    -o jsonpath='{.data.route\.yml}' | yq --output-format json --indent 0 \
    '[.http.routers[].rule | capture("Path[(]`(?P<path>[^`]+)`[)]").path] | sort')"
  ask "listing LiteLLM's models" /v1/models
  models="$(json --output-format json --indent 0 '[.data[].id] | sort')"
  [ "$models" != "[]" ] || fail "LiteLLM lists no model"
}

# desired_key <app>: the key fields the table row and the shared settings make, as JSON; the table is checked.
desired_key() {
  APP="$1" PERIOD="$period" ROUTES="$routes" MODELS="$models" yq --output-format json --indent 0 '
    .apps[strenv(APP)] as $row | {"max_budget": $row.budget, "budget_duration": strenv(PERIOD),
    "max_parallel_requests": $row.parallel, "models": (strenv(MODELS) | from_json),
    "allowed_routes": (strenv(ROUTES) | from_json)}' <<<"$table"
}
# flat <JSON object>: one "field value" line per field, a list sorted and joined and a number as a number, so that two
# objects compare by their lines.
flat() {
  printf '%s' "$1" | yq --input-format json 'to_entries | .[] | .key + " " +
    ((select(.value | tag == "!!seq") | .value | map(tostring) | sort | join(",")) // (.value | tostring))'
}
# differences <desired JSON> <found JSON or null>: sets change_fields to the JSON of the desired fields that differ
# and change_text to one line per difference, field old -> new.
differences() {
  local desired="$1" found="$2" field value flat_desired flat_found="" have_value=""
  local -A have=()
  change_fields="" change_text=""
  flat_desired="$(flat "$desired")"
  [ "$found" = null ] || flat_found="$(flat "$found")"
  while read -r field value; do
    [ -z "$field" ] || have["$field"]="$value"
  done <<<"$flat_found"
  while read -r field value; do
    have_value="${have[$field]-null}"
    [ "$have_value" != "$value" ] || continue
    change_fields+="${change_fields:+,}\"$field\":$(yq --input-format json --output-format json --indent 0 ".$field" <<<"$desired")"
    change_text+="${change_text:+$'\n'}$field $have_value -> $value"
  done <<<"$flat_desired"
  change_fields="{$change_fields}"
}
# found_keys <app>: sets key_count to the keys that hold the alias exactly and found_row to the first of them as JSON, or
# null.
found_keys() {
  local holders
  ask "listing the keys of $1" "/key/list?key_alias=$1&return_full_object=true&size=100"
  holders="$(json --output-format json --indent 0 '[.keys[] | select(.key_alias == "'"$1"'")]')"
  key_count="$(yq --input-format json 'length' <<<"$holders")"
  found_row="$(yq --input-format json --output-format json --indent 0 '.[0]' <<<"$holders")"
}
# read_budget <id>: sets found to the budget's row as JSON, or null.
read_budget() {
  ask "listing the budgets" /budget/list
  found="$(json --output-format json --indent 0 '[.[] | select(.budget_id == "'"$1"'")] | .[0]')"
}
# key_hash: the stored hash of the key found_keys found.
key_hash() { yq --input-format json '.token' <<<"$found_row"; }

# Each change is one write: its kind, its subject and its body. The change in change_fields and change_text is added
# after differences, and its lines are printed and counted.
change_kinds=() change_subjects=() change_bodies=()
change_lines=0
add_change() {
  local kind="$1" subject="$2" body line
  [ "$change_fields" != "{}" ] || return 0
  case "$kind" in
    budget-new | budget-update) body="{\"budget_id\":\"$subject\",${change_fields#\{}" ;;
    key-update) body="{\"key\":\"$(key_hash)\",${change_fields#\{}" ;;
  esac
  change_kinds+=("$kind")
  change_subjects+=("$subject")
  change_bodies+=("$body")
  while IFS= read -r line; do
    echo "litellm:keys: ${kind%%-*} $subject $line"
    change_lines=$((change_lines + 1))
  done <<<"$change_text"
}

keys_command() {
  local plan=false app desired found kind path index not_made_index missing=0 made="" not_made=""
  case "$*" in
    "") ;;
    --plan) plan=true ;;
    *) fail "usage: scripts/litellm_keys.sh keys [--plan]" ;;
  esac
  connect
  read_table

  # The person budget, then each app in name order.
  desired="$(PERIOD="$period" yq --output-format json --indent 0 '{"max_budget": .person_budget,
    "budget_duration": strenv(PERIOD)}' <<<"$table")"
  read_budget "$budget_id"
  differences "$desired" "$found"
  if [ "$found" = null ]; then kind=budget-new; else kind=budget-update; fi
  add_change "$kind" "$budget_id"
  for app in "${app_names[@]}"; do
    found_keys "$app"
    if [ "$key_count" != 1 ]; then
      if [ "$key_count" = 0 ]; then
        echo "litellm:keys: key $app: none; run mise run litellm:key $app"
      else
        echo "litellm:keys: key $app: $key_count keys hold the alias, none is changed"
      fi
      missing=$((missing + 1))
      continue
    fi
    desired="$(desired_key "$app")"
    differences "$desired" "$found_row"
    add_change key-update "$app"
  done

  if [ "$plan" = true ]; then
    echo "litellm:keys: $change_lines changes planned, nothing written"
    [ "$missing" = 0 ] || exit 1
    [ "$change_lines" = 0 ] || exit 2
    return 0
  fi
  for index in "${!change_kinds[@]}"; do
    case "${change_kinds[$index]}" in
      budget-new) path=/budget/new ;;
      budget-update) path=/budget/update ;;
      key-update) path=/key/update ;;
    esac
    if ! request "writing ${change_kinds[$index]%%-*} ${change_subjects[$index]}" "$path" "${change_bodies[$index]}" discard; then
      # The write may have reached LiteLLM before its answer was lost, so it is neither made nor not made.
      for ((not_made_index = index + 1; not_made_index < ${#change_kinds[@]}; not_made_index++)); do
        not_made+=" ${change_kinds[$not_made_index]%%-*}:${change_subjects[$not_made_index]}"
      done
      echo "litellm:keys: $failure; made:${made:- none}; failed: ${change_kinds[$index]%%-*}:${change_subjects[$index]};" \
        "not made:${not_made:- none}" >&2
      exit 1
    fi
    made+=" ${change_kinds[$index]%%-*}:${change_subjects[$index]}"
  done
  echo "litellm:keys: $change_lines changes made"
  [ "$missing" = 0 ] || exit 1
}

key_command() {
  local app="${1-}" secret_data value value_hash desired body table_app has_row=false
  [ "$#" = 1 ] || fail "usage: scripts/litellm_keys.sh key <app>"
  connect
  read_table
  for table_app in "${app_names[@]}"; do
    [ "$table_app" != "$app" ] || has_row=true
  done
  [ "$has_row" = true ] || fail "$app has no row in the table"
  secret_data="$(in_cluster "reading the Secret $app" --namespace "$app" get secret "$app" \
    -o jsonpath='{.data.litellm_key}')"
  [ -n "$secret_data" ] || fail "the Secret $app has no litellm_key"
  decode "$secret_data" || fail "the litellm_key of $app is no base64"
  value="$decoded"
  [[ $value == "$key_prefix"* && $value =~ ^[!-~]+$ ]] ||
    fail "the litellm_key of $app is not one printable line starting with $key_prefix"
  [ "${#value}" -ge "$key_minimum_length" ] || fail "the litellm_key of $app is shorter than $key_minimum_length characters"
  value_hash="$(printf '%s' "$value" | sha256sum)"
  value_hash="${value_hash%% *}"

  found_keys "$app"
  case "$key_count" in
    0) ;;
    1)
      [ "$(key_hash)" = "$value_hash" ] || fail "another key value holds the alias $app; nothing changed"
      echo "litellm:key: $app unchanged"
      return 0
      ;;
    *) fail "$key_count keys hold the alias $app; nothing changed" ;;
  esac
  desired="$(desired_key "$app")"
  body="{\"key\":\"$(quote_inner "$value")\",\"key_alias\":\"$app\",${desired#\{}"
  ask "making the key of $app" /key/generate "$body" discard
  echo "litellm:key: $app made"
}

# The admin budget has no limit and resets monthly; its group marks who is on it.
admin_budget=litellm-admin admin_period=1mo admin_group=/services/litellm/admin

# read_customer: sets customer_row to the person's customer row as JSON, or null when LiteLLM has none.
read_customer() {
  request "reading the customer row of $username" "/customer/info?end_user_id=$fingerprint" || [ "$status" = 404 ] ||
    fail "$failure"
  if [ "$status" = 404 ]; then customer_row=null; else customer_row="$(json --output-format json --indent 0 '.')"; fi
}
# make_admin_budget: creates the admin budget or corrects its fields, then reads it back.
make_admin_budget() {
  local desired path
  desired="$(PERIOD="$admin_period" yq --null-input --output-format json --indent 0 \
    '{"max_budget": null, "budget_duration": strenv(PERIOD)}')"
  read_budget "$admin_budget"
  differences "$desired" "$found"
  [ "$change_fields" != "{}" ] || return 0
  if [ "$found" = null ]; then path=/budget/new; else path=/budget/update; fi
  attempted+=("budget $admin_budget")
  ask "writing budget $admin_budget" "$path" "{\"budget_id\":\"$admin_budget\",${change_fields#\{}" discard
  read_budget "$admin_budget"
  differences "$desired" "$found"
  [ "$change_fields" = "{}" ] || fail "the budget $admin_budget did not read back as written"
}
# link_customer: puts the person's customer row, as read before the first write, on the admin budget, by a new row or a
# change of its budget alone, then reads it back.
link_customer() {
  local path=/customer/update
  [ "$(yq '.budget_id' <<<"$customer_row")" != "$admin_budget" ] || return 0
  [ "$customer_row" != null ] || path=/customer/new
  attempted+=("customer row of $username")
  ask "writing the customer row of $username" "$path" \
    "{\"user_id\":\"$fingerprint\",\"budget_id\":\"$admin_budget\"}" discard
  read_customer
  [ "$(yq '.budget_id' <<<"$customer_row")" = "$admin_budget" ] || fail "the customer row of $username did not read back on $admin_budget"
}

admin_command() {
  local issuer identity person_groups
  username="${1-}"
  [ "$#" = 1 ] && [ -n "$username" ] || fail "usage: scripts/litellm_keys.sh admin <username>"
  realm="$(yq '.realm' "$(dirname "${BASH_SOURCE[0]}")/../infrastructure/keycloak/realm.yaml")"
  connect
  sign_in_kcadm
  find_person "$username"
  start_forward keycloak keycloak http
  reply="$(curl --silent --fail --max-time 30 "http://127.0.0.1:$forwarded_port/realms/$realm/.well-known/openid-configuration" \
    </dev/null)" || fail "Keycloak's discovery document of the realm cannot be read"
  issuer="$(json '.issuer')"
  [[ $issuer == http*://* ]] || fail "Keycloak's discovery document names no issuer"
  # agent-runtime's person_fingerprint: the compact JSON of [issuer, subject], whose sha256 follows fp-.
  identity="$(ISSUER="$issuer" SUBJECT="$person_id" yq --null-input --output-format json --indent 0 '[strenv(ISSUER), strenv(SUBJECT)]')"
  fingerprint="fp-$(printf '%s' "$identity" | sha256sum | cut -d ' ' -f 1)"
  kcadm get "group-by-path$admin_group" --target-realm "$realm" --fields id --format csv --noquotes >/dev/null ||
    fail "$realm holds no $admin_group or Keycloak cannot be read"

  # The state this preflight enumerates is read before the first write, and each step is written and read back in this order, so a customer without a limit never stands without the marker.
  read_customer
  make_admin_budget
  ensure_member "$admin_group"
  person_groups="$(kcadm get "users/$person_id/groups" --target-realm "$realm" --fields path --format csv --noquotes)" ||
    fail "$unreadable"
  grep -qxF "$admin_group" <<<"$person_groups" || fail "$username did not read back in $admin_group"
  link_customer
  if [ "${#attempted[@]}" = 0 ]; then
    echo "litellm:admin: $username unchanged"
  else
    echo "litellm:admin: $username is in $admin_group on the budget $admin_budget; written: $(written_list)"
  fi
}

case "${1-}" in
  keys)
    command_name=keys
    shift
    keys_command "$@"
    ;;
  key)
    command_name=key
    shift
    key_command "$@"
    ;;
  admin)
    command_name="admin"
    shift
    admin_command "$@"
    ;;
  *) fail "usage: scripts/litellm_keys.sh keys [--plan] | key <app> | admin <username>" ;;
esac
