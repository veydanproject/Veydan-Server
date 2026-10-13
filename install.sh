#!/usr/bin/env bash
# Veydan server: the one installer. Run it as root on a clean Debian 13.
#
#   curl -fsSL https://raw.githubusercontent.com/veydanproject/Veydan-Server/main/install.sh | sudo bash
#
# It finds the kit of its version in one of three places, in this order:
#   1. appended to this very file after the line __KIT__ (an installer made
#      by `make server`, which carries the kit and the programs inside);
#   2. beside it (a checkout of the repository);
#   3. the release of this version on GitHub, checked against SHA256SUMS.
# Then it runs run.sh of that kit with the arguments it got. A server.conf
# and the key files for push (*.json) beside this file are taken as
# answers; what is not in them is asked.
set -euo pipefail

KIT_VERSION=0.1.3
RELEASES=https://github.com/veydanproject/Veydan-Server/releases/download
KITS=/opt/veydan/kit

self=""
[ -f "${BASH_SOURCE[0]:-}" ] && self=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")
from=${self:+$(dirname "$self")}
from=${from:-$PWD}

die() { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

kit=""
# -a: after the marker the file is an archive, which grep would otherwise
# call binary and not search.
if [ -n "$self" ] && marker=$(grep -a -n -m1 '^__KIT__$' "$self" | cut -d: -f1) && [ -n "$marker" ]; then
    kit=$KITS/$KIT_VERSION
    mkdir -p "$kit"
    tail -n +$((marker + 1)) "$self" | tar -xzf - -C "$kit"
elif [ -n "$self" ] && [ -f "$(dirname "$self")/run.sh" ]; then
    kit=$(dirname "$self")
else
    command -v curl >/dev/null || die "curl is needed: apt-get install curl ca-certificates"
    kit=$KITS/$KIT_VERSION
    tmp=$(mktemp -d)
    name=veydan-server-$KIT_VERSION.tar.gz
    curl -fsSL -o "$tmp/$name" "$RELEASES/v$KIT_VERSION/$name" || die "could not download $name from $RELEASES/v$KIT_VERSION"
    curl -fsSL -o "$tmp/SHA256SUMS" "$RELEASES/v$KIT_VERSION/SHA256SUMS" || die "could not download SHA256SUMS of v$KIT_VERSION"
    ( cd "$tmp" && grep " $name\$" SHA256SUMS | sha256sum -c --quiet - ) || die "$name does not match SHA256SUMS"
    mkdir -p "$kit"
    tar -xzf "$tmp/$name" -C "$kit"
    rm -rf "$tmp"
fi
[ -f "$kit/run.sh" ] || die "no run.sh in the kit at $kit"
exec bash "$kit/run.sh" --from "$from" "$@"
