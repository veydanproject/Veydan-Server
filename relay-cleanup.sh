#!/usr/bin/env bash
# strfry and vguard removed for good from a server whose relay runs on vrelay
# (veydan-server relay-cleanup). Never part of a run of the kit.
#
#   relay-cleanup.sh [--yes]    what is there, the word yes, then: the denied
#                               lists and the access files vrelay has not got
#                               copied to it, the kit again (vrelay leaves
#                               /opt/vguard), then the units and timers of
#                               strfry and vguard, /opt/strfry (its database
#                               too), /opt/vguard, nginx's upstream of the
#                               peers of strfry and the users strfry and vguard
#
# Refused while the engine is strfry, or while vrelay does not serve. After
# it there is no way back to strfry but a fresh install of it (an empty
# database, no members): veydan-server relay-engine strfry, then rerun.
# --dry-run (first): the files under $DRY_ROOT, nothing run (the tests).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

if [ "${1:-}" = --dry-run ]; then DRY=1; DRY_ROOT=${DRY_ROOT:?--dry-run needs DRY_ROOT}; shift; fi
YES=0
while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes) YES=1; shift ;;
        -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "veydan-server relay-cleanup [--yes]" ;;
    esac
done
STATE=${VEYDAN_STATE:-/opt/veydan}
CONF=$STATE/server.conf
S=/opt/strfry
G=/opt/vguard
R=/opt/vrelay
UNITS="strfry-router.service strfry-sync.timer strfry-sync.service strfry-retention.timer strfry-retention.service vguard.service strfry.service"

[ "$DRY" = 1 ] || [ "$(id -u)" = 0 ] || die "run as root"
[ -r "$CONF" ] || die "no $CONF: run install.sh once"
# shellcheck disable=SC1090
. "$CONF"
[[ " ${COMPONENTS:-} " == *" relay "* ]] || die "relay-cleanup: this server has no relay"
[ "${RELAY_ENGINE:-strfry}" = vrelay ] \
    || die "relay-cleanup: the engine of this relay is ${RELAY_ENGINE:-strfry}: strfry and vguard serve it, and nothing is removed. Switch first (veydan-server relay-engine vrelay, veydan-server rerun) and see that vrelay serves"
if [ ! -f "$(target "$R/etc/vrelay.env")" ] || { [ "$DRY" != 1 ] && [ ! -x "$R/bin/vrelay" ]; }; then
    die "relay-cleanup: vrelay is not installed here ($R): veydan-server rerun first"
fi
if [ "$DRY" != 1 ]; then
    systemctl is-active -q vrelay \
        || die "relay-cleanup: vrelay does not run (systemctl status vrelay): strfry stays while the engine that replaces it does not serve"
fi

# What is here of them.
unit_here() { # unit_here <unit>
    if [ "$DRY" = 1 ]; then
        [ -f "$(target "$S/etc/$1")" ] || [ -f "$(target "$G/etc/$1")" ]
    else
        systemctl cat "$1" >/dev/null 2>&1 || [ -e "/etc/systemd/system/$1" ] || [ -L "/etc/systemd/system/$1" ]
    fi
}
user_here() { [ "$DRY" != 1 ] && id "$1" >/dev/null 2>&1; }
units=() dirs=() users=() files=()
for u in $UNITS; do unit_here "$u" && units+=("$u"); done
for d in "$S" "$G"; do [ -d "$(target "$d")" ] && dirs+=("$d"); done
for u in strfry vguard; do user_here "$u" && users+=("$u"); done
# (/var/tmp/strfry-build.swap: of an older kit.)
for f in "$STATE/nginx/15-relay-peers.conf" /var/tmp/strfry-build.swap; do [ -e "$(target "$f")" ] && files+=("$f"); done
if [ "${#units[@]}${#dirs[@]}${#users[@]}${#files[@]}" = 0000 ]; then
    say "relay-cleanup: nothing of strfry or vguard on this server"
    exit 0
fi

size() { du -sh "$(target "$1")" 2>/dev/null | awk '{print $1}'; }
echo "relay-cleanup: these go for good:"
[ "${#units[@]}" = 0 ] || echo "   units:   ${units[*]}"
for d in "${dirs[@]}"; do
    case "$d" in
        "$S") echo "   $S ($(size "$S")): strfry, its settings and its database: the history of the relay before vrelay" ;;
        "$G") echo "   $G ($(size "$G")): vguard, its settings, its members, invites and secret (vrelay has its own copies)" ;;
    esac
done
[ "${#files[@]}" = 0 ] || echo "   files:   ${files[*]}"
[ "${#users[@]}" = 0 ] || echo "   users:   ${users[*]}"
echo "After it the way back to strfry is a fresh install of it: an empty database, no members."
[ ! -d "$(target "$S/data")" ] || echo "Its history: veydan-server relay-import pours it into vrelay first, if it was not."
if [ "$YES" != 1 ]; then
    if [ -t 0 ]; then
        read -r -p "Type yes to remove them: " word
        [ "$word" = yes ] || die "relay-cleanup: nothing removed"
    else
        die "relay-cleanup: nothing removed; --yes, or run it on a terminal and type yes"
    fi
fi

# 1. What vrelay has not got: the denied lists as the agent laid them last
#    (newer than its copy), the access files it lacks.
#    The files of vguard are read as vguard (its folder is its own to
#    write: a link there reaches nothing vguard could not read itself);
#    those of vrelay's access are written as vrelay (lib/common.sh put).
mkdirp "$R/policy" 0750 root:vrelay
for f in denied-keys.txt denied-groups.txt; do
    if plain_file "$G/data/$f"; then
        read_as vguard "$G/data/$f" | put "$R/policy/$f" 0640 root:vrelay
        say "relay-cleanup: $G/data/$f copied to $R/policy/$f"
    fi
done
if [ "${ACCESS_MODE:-open}" != open ]; then
    mkdirp "$R/access" 0770 root:vrelay
    for f in members.txt invites.json; do
        if plain_file "$G/data/$f" && [ ! -e "$(target "$R/access/$f")" ] && [ ! -L "$(target "$R/access/$f")" ]; then
            read_as vguard "$G/data/$f" | put "$R/access/$f" 0660 vrelay:vrelay
            say "relay-cleanup: $G/data/$f copied to $R/access/$f"
        fi
    done
    if plain_file "$G/etc/access.key" && [ -s "$(target "$G/etc/access.key")" ] && [ ! -s "$(target "$R/etc/secrets/access.key")" ]; then
        read_as vguard "$G/etc/access.key" | put "$R/etc/secrets/access.key" 0600 vrelay:vrelay
        say "relay-cleanup: $G/etc/access.key copied to $R/etc/secrets/access.key"
    fi
fi

# 2. Stopped and disabled (they are, since the switch).
for u in "${units[@]}"; do run systemctl disable --now "$u"; done

# 3. The kit again, vrelay without vguard: its denied lists in policy/, no
#    group vguard (components/vrelay.sh, RELAY_CLEANUP). A failed run stops
#    here, with nothing removed.
say "relay-cleanup: the kit again, vrelay without /opt/vguard"
if [ "$DRY" = 1 ]; then
    run env RELAY_CLEANUP=1 bash "$HERE/run.sh" --yes
elif ! RELAY_CLEANUP=1 bash "$HERE/run.sh" --yes; then
    die "relay-cleanup: the run of the kit failed (above); nothing of strfry or vguard is removed"
fi

# 4. Removed.
removed=()
for u in "${units[@]}"; do
    if [ "$DRY" = 1 ] || [ -L "/etc/systemd/system/$u" ] || [ -f "/etc/systemd/system/$u" ]; then
        run rm -f "/etc/systemd/system/$u"
    fi
    removed+=("$u")
done
if [ "${#units[@]}" -gt 0 ]; then
    run systemctl daemon-reload
    # shellcheck disable=SC2068  # one unit a word
    [ "$DRY" = 1 ] || systemctl reset-failed ${units[@]} 2>/dev/null || true
fi
for f in "${files[@]}"; do
    case "$f" in
        *.swap) [ "$DRY" = 1 ] || swapoff "$f" 2>/dev/null || true ;;
    esac
    run rm -f "$f"
    removed+=("$f")
done
if [[ " ${files[*]} " == *" $STATE/nginx/15-relay-peers.conf "* ]]; then
    run nginx -t -q || die "relay-cleanup: nginx refuses its config without 15-relay-peers.conf (nginx -t)"
    run systemctl reload nginx
fi
for d in "${dirs[@]}"; do
    run rm -rf "$d"
    removed+=("$d")
done
if user_here vrelay && id -nG vrelay 2>/dev/null | tr ' ' '\n' | grep -qx vguard; then
    run gpasswd -d vrelay vguard >/dev/null
fi
for u in "${users[@]}"; do
    run userdel "$u"
    if [ "$DRY" != 1 ] && getent group "$u" >/dev/null; then groupdel "$u" || true; fi
    removed+=("user $u")
done

say "relay-cleanup: removed: ${removed[*]}"
echo "There is no way back to strfry as it was: veydan-server relay-engine strfry would install strfry and vguard anew, with an empty database and no members."
echo "Debian's packages that strfry needed (liblmdb0, libsecp256k1-2, and its compilers when it was built here) stay; apt-get autoremove after removing them by hand, if nothing else needs them."
if [[ " ${COMPONENTS:-} " == *" agent "* ]]; then
    echo "The agent names the denied lists where the overlay's agent component says; until that component names $R/policy and the kit runs again, vcloud lays them nowhere vrelay reads."
fi
