#!/usr/bin/env bash
set -eo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
export PATH="$HOME/.local/bin:$PATH"
scratch="$(mktemp -d)"
docuum_pid=""
cell_images=(disk-cell/pinned:previous disk-cell/pinned-base:1 disk-cell/used:1 disk-cell/older:1 disk-cell/newer:1)
cleanup() {
  [ -z "$docuum_pid" ] || kill "$docuum_pid" 2>/dev/null || true
  docker rm --force disk-cell-user >/dev/null 2>&1 || true
  docker image rm --force "${cell_images[@]}" >/dev/null 2>&1 || true
}
trap cleanup EXIT
# The arguments are the service's own, read from its ExecStart as systemd splits them; only the threshold and the
# minimum age are the cell's, and every image the runner already holds is kept.
exec_start="$(mise exec -- yq -p toml -oy '.bootstrap.linux.systemd.units.docuum.exec_start' mise.toml)"
mapfile -t service_args < <(python3 -I -c 'import shlex, sys; print(*shlex.split(sys.argv[1].replace("$$", "$"))[1:], sep="\n")' "$exec_start")
shipped_args=()
for ((index = 0; index < ${#service_args[@]}; index++)); do
  case "${service_args[index]}" in
    --threshold | --min-age) index=$((index + 1)) ;;
    *) shipped_args+=("${service_args[index]}") ;;
  esac
done
[ "${#shipped_args[@]}" -gt 0 ] || fail "the service's ExecStart '$exec_start' holds no --keep"
existing_args=()
while IFS= read -r reference; do
  existing_args+=("--keep=^$(sed 's/[.[\*^$()+?{|]/\\&/g' <<<"$reference")\$")
done < <(docker image ls --all --format '{{.Repository}}:{{.Tag}}')

make_image() {
  local image="$1" megabytes="$2"
  mkdir -p "$scratch/layer"
  head -c "$((megabytes * 1000000))" /dev/urandom >"$scratch/layer/blob"
  tar -C "$scratch/layer" -c blob | docker import - "$image" >/dev/null
}
make_image disk-cell/pinned:previous 10
make_image disk-cell/pinned-base:1 10
make_image disk-cell/used:1 10
docker create --name disk-cell-user disk-cell/used:1 /blob >/dev/null
# Docker dates an image to the second, and Docuum starts from the creation date of an image it has not seen.
sleep 2
make_image disk-cell/older:1 100
sleep 2
make_image disk-cell/newer:1 100
# docker system df prints a size like 72.19GB or 512.3MB, which numfmt reads as SI units.
images_bytes="$(docker system df --format '{{.Type}} {{.Size}}' | awk '$1 == "Images" { sub("B$", "", $2); print $2 }' |
  LC_ALL=C numfmt --from=si)"
# One 100 MB image over the limit by half of that: deleting the older one is enough and the newer one must stay.
threshold_bytes=$((images_bytes - 50000000))
XDG_DATA_HOME="$scratch/data" "$(mise which docuum)" --threshold "$threshold_bytes B" --min-age 1s "${shipped_args[@]}" \
  "${existing_args[@]}" >"$scratch/docuum.log" 2>&1 &
docuum_pid=$!
for _ in $(seq 120); do
  grep -q 'within the limit' "$scratch/docuum.log" && break
  kill -0 "$docuum_pid" 2>/dev/null || fail "docuum ended: $(cat "$scratch/docuum.log")"
  sleep 1
done
grep -q 'within the limit' "$scratch/docuum.log" || fail "docuum never got within the limit: $(cat "$scratch/docuum.log")"
kill "$docuum_pid"
docuum_pid=""
if docker image inspect disk-cell/older:1 >/dev/null 2>&1; then fail "the least recently used unprotected image stayed"; fi
for image in disk-cell/newer:1 disk-cell/pinned:previous disk-cell/pinned-base:1 disk-cell/used:1; do
  docker image inspect "$image" >/dev/null 2>&1 || fail "docuum deleted $image: $(cat "$scratch/docuum.log")"
done
echo "docuum deleted the least recently used unprotected image and kept the newer one, the :previous and -base: tags" \
  "and the image a container uses"
