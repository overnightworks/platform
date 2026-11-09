# shellcheck shell=sh
# The program of the init container remove-link, run by busybox sh: with lo alone it is done; with eth0 besides it
# deletes eth0, reads again and admits lo alone. A failed read, any other link and a failed delete name themselves and
# end 1, whatever status ip ended with. busybox sh ignores set -e inside a command substitution, so each read of the
# links is a plain assignment at the top level with its own failure branch, and the function only parses.
set -eu
link_names() { printf '%s\n' "$1" | sed -n 's/^[0-9]*: \([^:@ ]*\).*/\1/p' | sort; }
links="$(ip -o link)" || { echo "remove-link: the read of the links failed" >&2; exit 1; }
names="$(link_names "$links")"
[ "$names" = lo ] && exit 0
[ "$names" = "$(printf 'eth0\nlo')" ] || { echo "remove-link: unexpected links: $(echo $names)" >&2; exit 1; }
ip link delete eth0 || { echo "remove-link: the delete of eth0 failed" >&2; exit 1; }
links="$(ip -o link)" || { echo "remove-link: the second read of the links failed" >&2; exit 1; }
names="$(link_names "$links")"
[ "$names" = lo ] || { echo "remove-link: links left after the delete: $(echo $names)" >&2; exit 1; }
