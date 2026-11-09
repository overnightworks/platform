# shellcheck shell=sh
# The program of the init container remove-link, run by busybox sh: with lo alone it is done; with eth0 besides it
# deletes eth0, reads again and admits lo alone. A failed read, any other link and a failed delete end non-zero;
# the last two name themselves and end 1, whatever status ip ended with.
set -eu
link_names() {
  links="$(ip -o link)"
  printf '%s\n' "$links" | sed -n 's/^[0-9]*: \([^:@ ]*\).*/\1/p' | sort
}
names="$(link_names)"
[ "$names" = lo ] && exit 0
[ "$names" = "$(printf 'eth0\nlo')" ] || { echo "remove-link: unexpected links: $(echo $names)" >&2; exit 1; }
ip link delete eth0 || { echo "remove-link: the delete of eth0 failed" >&2; exit 1; }
names="$(link_names)"
[ "$names" = lo ] || { echo "remove-link: links left after the delete: $(echo $names)" >&2; exit 1; }
