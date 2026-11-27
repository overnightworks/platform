# shellcheck shell=bash
# The one owner of the environment a child of a script runs under when it must see the keyring's gh login and nothing
# else of the caller's shell, so no token, debug switch, proxy or provider setting of the caller reaches it.
# `clean_environment` is `env -i` with PATH, HOME and LANG; `append_gh_login_variables <array name>` adds the two
# variables that place gh's configuration, when the caller set them.
clean_environment=(env -i "PATH=${PATH}" "HOME=${HOME}" "LANG=${LANG:-C.UTF-8}")

append_gh_login_variables() {
  local -n environment_words="$1"
  local variable
  for variable in XDG_CONFIG_HOME GH_CONFIG_DIR; do
    if [ -n "${!variable:-}" ]; then
      environment_words+=("${variable}=${!variable}")
    fi
  done
}
