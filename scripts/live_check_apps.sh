# shellcheck shell=bash
# Sourced by live_check.sh and live_check_report.sh: the one table of the apps the sign-in check covers.
# The apps this command signs in to, one row each, and the one list of their names (the usage message and the cleanup
# read it): the app, which is also its client in realm.yaml, whose baseUrl and first redirect URI are its origin and
# callback; the namespace and name of the Deployment that must be Available; and the paths of the app's own routes (its
# route contract): where a sign-in starts, the account route that answers 200 signed in and 401 otherwise, and the
# sign-out.
app_table='
hopin        hopin        hopin   /auth/start  /api/account  /logout
skat         skat         skat    /auth/start  /api/account  /logout
presentator  presentator  web     /login/oidc  /api/account  /logout
songmaker    songmaker    web     /login/oidc  /api/auth/me  /auth/logout
'
app_names() { awk 'NF { print $1 }' <<<"$app_table"; }
app_row() { awk -v wanted="$1" '$1 == wanted' <<<"$app_table"; }
# app_repository <app>: the GitHub repository of the app, which the report opens its items at and the journeys tier's
# checkout must name as its origin.
app_repository() { printf 'overnightworks/%s' "$1"; }
