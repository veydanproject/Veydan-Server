# shellcheck shell=bash disable=SC1090
# Questions on the terminal, in the admin's language. Sourced by run.sh.
#
# The terminal is /dev/tty, not stdin: the installer is often run as
#   curl … | bash
# where stdin is the script itself. With --yes, or without a terminal, a
# question keeps its current value.
#
# The texts are M[key] of lang/<code>.sh; English is the base and every
# other language overrides what it translates.

declare -A M
# shellcheck source=../lang/en.sh
. "$HERE/lang/en.sh"
case "${KIT_LANG:-}" in
    ''|en) ;;
    *) [ -f "$HERE/lang/$KIT_LANG.sh" ] && . "$HERE/lang/$KIT_LANG.sh" ;;
esac

msg() { printf '%s' "${M[$1]:-$1}"; }

TTY=0
if [ "${YES:-0}" != 1 ] && { exec 3<>/dev/tty; } 2>/dev/null; then
    TTY=1
fi

# ask <VAR> <key> [choices]: the current value is the default; with choices
# (space separated) the answer must be one of them.
ask() {
    local var=$1 key=$2 choices=${3:-} cur=${!1} a
    [ "$TTY" = 1 ] || return 0
    while :; do
        printf '%s [%s]: ' "$(msg "$key")" "$cur" >&3
        IFS= read -r -u 3 a || return 0
        [ -n "$a" ] || a=$cur
        if [ -n "$choices" ] && [[ " $choices " != *" $a "* ]]; then
            printf '%s: %s\n' "$(msg one_of)" "$choices" >&3
            continue
        fi
        printf -v "$var" '%s' "$a"
        return 0
    done
}

# ask_secret <VAR> <key>: the same without the value on the screen.
ask_secret() {
    local var=$1 key=$2 cur=${!1} a
    [ "$TTY" = 1 ] || return 0
    printf '%s%s: ' "$(msg "$key")" "${cur:+ [$(msg kept)]}" >&3
    IFS= read -r -s -u 3 a || return 0
    echo >&3
    [ -n "$a" ] && printf -v "$var" '%s' "$a"
    return 0
}

# confirm <key>: yes or no on the terminal; no terminal means yes.
confirm() {
    local a
    [ "$TTY" = 1 ] || return 0
    printf '%s [y/N] ' "$(msg "$1")" >&3
    IFS= read -r -u 3 a || return 1
    [ "$a" = y ] || [ "$a" = Y ]
}

# pause <key>: waits for Enter.
pause() {
    [ "$TTY" = 1 ] || return 0
    printf '%s' "$(msg "$1")" >&3
    IFS= read -r -u 3 _ || true
}

# tell <text>: a line for the admin, on the terminal when there is one.
tell() {
    if [ "$TTY" = 1 ]; then printf '%s\n' "$*" >&3; else printf '%s\n' "$*"; fi
}
