#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# The key, the values and the plain manifests exist only in this runner's temp directory; no step prints them.
umask 077
private_dir="$RUNNER_TEMP/decryption-proof"
artifact_dir="$RUNNER_TEMP/platform-secrets"
mkdir "$private_dir" "$artifact_dir"
key_file="$private_dir/ci.agekey"
age-keygen -o "$key_file" 2>/dev/null
# Each Secret's data holds the files of its own directory, keyed by file name; the same name in two
# namespaces is two Secrets.
files_dir="$private_dir/files"
plain_files=()
secret_files() { mkdir -p "$files_dir/$2/$1" && echo "$files_dir/$2/$1"; }
plain_secret() {
  local file
  plain_files+=("$private_dir/$2.$1.yaml")
  NAME="$1" NAMESPACE="$2" TYPE="$3" yq --null-input \
    '{"apiVersion": "v1", "kind": "Secret", "metadata": {"name": strenv(NAME), "namespace": strenv(NAMESPACE)}, "type": strenv(TYPE)}' \
    > "${plain_files[-1]}"
  while IFS= read -r file; do
    KEY="${file##*/}" FILE="$file" yq --inplace '.data[strenv(KEY)] = (load_str(strenv(FILE)) | @base64)' "${plain_files[-1]}"
  done < <(find "$files_dir/$2/$1" -maxdepth 1 -type f | sort)
}

# Eighteen fixed characters, a multiple of three, so the dummy's base64 form starts with a fixed string too.
dummy="platform-ci-dummy-$(openssl rand -hex 16)"
echo "::add-mask::$dummy"
echo "::add-mask::$(printf '%s' "$dummy" | base64 --wrap=0)"
dummy_file="$(secret_files "$PROOF_SECRET_NAME" "$PROOF_SECRET_NAMESPACE")/value"
printf '%s' "$dummy" > "$dummy_file"
plain_secret "$PROOF_SECRET_NAME" "$PROOF_SECRET_NAMESPACE" Opaque

# Each app's files as dummies, one per key the PC's Secret holds, for an app that mounts a Secret; hex meets
# the TURN files' grammar, and 64 characters the session secret's minimum.
auth="$(printf '%s:%s' "$PULL_USER" "$PULL_TOKEN" | base64 --wrap=0)"
echo "::add-mask::$auth"
for manifest in $APP_MANIFESTS; do
  deployment="$(yq 'select(.kind == "Deployment")' "$manifest")"
  app_namespace="$(yq '.metadata.namespace' <<<"$deployment")"
  app_secret="$(yq '.spec.template.spec.volumes[] | select(.secret) | .secret.secretName' <<<"$deployment")"
  pull_secret="$(yq '.spec.template.spec.imagePullSecrets[].name' <<<"$deployment")"
  if [ -n "$app_secret" ]; then
    app_files="$(secret_files "$app_secret" "$app_namespace")"
    for key in oidc_client_secret session_secret turn_key_id turn_api_token; do
      value="$(openssl rand -hex 32)"
      echo "::add-mask::$value"
      printf '%s' "$value" > "$app_files/$key"
    done
    plain_secret "$app_secret" "$app_namespace" Opaque
  fi
  pull_file="$(secret_files "$pull_secret" "$app_namespace")/.dockerconfigjson"
  printf '{"auths":{"ghcr.io":{"auth":"%s"}}}' "$auth" > "$pull_file"
  echo "::add-mask::$(base64 --wrap=0 < "$pull_file")"
  plain_secret "$pull_secret" "$app_namespace" kubernetes.io/dockerconfigjson
done

# Each namespace whose layer includes the Postgres base gets its password, in the URL-safe alphabet, as the
# file the base's StatefulSet reads from its Secret.
postgres_statefulset="$(yq 'select(.kind == "StatefulSet")' "$POSTGRES_BASE/postgres.yaml")"
postgres_secret="$(yq '.spec.template.spec.volumes[] | select(.secret) | .secret.secretName' <<<"$postgres_statefulset")"
password_file="$(yq '.spec.template.spec.containers[0].env[] | select(.name == "POSTGRES_PASSWORD_FILE") | .value' \
  <<<"$postgres_statefulset")"
postgres_namespaces=()
for layer in infrastructure/*/kustomization.yaml apps/*/kustomization.yaml; do
  includes=0
  while IFS= read -r resource; do
    [ "$(realpath --canonicalize-missing "${layer%/*}/$resource")" != "$(realpath "$POSTGRES_BASE")" ] || includes=1
  done < <(yq '.resources[]' "$layer")
  [ "$includes" = 1 ] || continue
  postgres_namespace="$(yq '.namespace' "$layer")"
  value="$(openssl rand -hex 32)"
  echo "::add-mask::$value"
  printf '%s' "$value" > "$(secret_files "$postgres_secret" "$postgres_namespace")/${password_file##*/}"
  plain_secret "$postgres_secret" "$postgres_namespace" Opaque
  postgres_namespaces+=("$postgres_namespace")
done
[ "${#postgres_namespaces[@]}" -gt 0 ] || fail "no layer under infrastructure/ or apps/ includes $POSTGRES_BASE"

# Each Secret a container of a layer in SECRET_KEY_LAYERS reads by key, beside the Postgres base's, gets a dummy per
# key, in the URL-safe alphabet.
key_secrets=()
while read -r secret_namespace secret_name secret_key; do
  [ "$secret_name" != "$postgres_secret" ] || continue
  value="$(openssl rand -hex 32)"
  echo "::add-mask::$value"
  printf '%s' "$value" > "$(secret_files "$secret_name" "$secret_namespace")/$secret_key"
  [[ " ${key_secrets[*]} " == *" $secret_namespace/$secret_name "* ]] || key_secrets+=("$secret_namespace/$secret_name")
done < <(for layer in $SECRET_KEY_LAYERS; do kubectl kustomize "$layer"; echo ---; done | yq --no-doc \
  '.metadata.namespace as $namespace | .. | select(tag == "!!map" and has("secretKeyRef")) |
   $namespace + " " + .secretKeyRef.name + " " + .secretKeyRef.key' | sort -u)
[ "${#key_secrets[@]}" -gt 0 ] || fail "no container of $SECRET_KEY_LAYERS reads a Secret by key"
for secret in "${key_secrets[@]}"; do plain_secret "${secret#*/}" "${secret%/*}" Opaque; done

# The recipient is the key's public half, so sops encrypts without reading any private key.
recipient="$(age-keygen -y "$key_file")"
data_values() { yq '.data // {} | .[]' "$1"; }
for plain_file in "${plain_files[@]}"; do
  encrypted_file="$artifact_dir/${plain_file##*/}"
  sops --encrypt --age "$recipient" --encrypted-regex '^(data|stringData)$' "$plain_file" > "$encrypted_file"

  # Flux applies a value left outside the encrypted fields as it is, which would fake the proof or leak it.
  encrypted="$(<"$encrypted_file")"
  while IFS= read -r value; do
    [[ $encrypted != *"$value"* && $encrypted != *"$(base64 --decode <<<"$value")"* ]] ||
      fail "$encrypted_file holds a value in plain text"
  done < <(data_values "$plain_file")
  values="$(data_values "$encrypted_file")"
  [ -n "$values" ] || fail "$encrypted_file holds no data value"
  while IFS= read -r value; do
    [[ $value == 'ENC['* ]] || fail "a data value in $encrypted_file is not sops ciphertext"
  done <<<"$values"
  echo "every data value in $encrypted_file is sops ciphertext, and no plain value is in it"
done

{
  echo "AGE_KEY_FILE=$key_file"
  echo "DUMMY_FILE=$dummy_file"
  echo "SECRETS_ARTIFACT_DIR=$artifact_dir"
  echo "POSTGRES_NAMESPACES=${postgres_namespaces[*]}"
} >> "$GITHUB_ENV"
