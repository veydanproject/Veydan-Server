#!/usr/bin/env bash
# Veydan server: the one installer. Run it as root on a clean Debian 13.
#
#   curl -fsSL https://raw.githubusercontent.com/veydanproject/Veydan-Server/main/install.sh | sudo bash
#
# It finds the kit of its version in one of three places, in this order:
#   1. appended to this very file after the line __KIT__ (an installer made
#      by `make server`, which carries the kit and the programs inside);
#   2. beside it (a checkout of the repository);
#   3. the release of this version on GitHub, checked against SHA256SUMS
#      and against the signature of the owner (<kit>.sig, the release key
#      below; an unsigned kit is refused).
# Then it runs run.sh of that kit with the arguments it got. A server.conf
# and the key files for push (*.json) beside this file are taken as
# answers; what is not in them is asked.
set -euo pipefail

KIT_VERSION=0.1.7
RELEASES=https://github.com/veydanproject/Veydan-Server/releases/download
KITS=/opt/veydan/kit

self=""
[ -f "${BASH_SOURCE[0]:-}" ] && self=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")
from=${self:+$(dirname "$self")}
from=${from:-$PWD}

die() { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

# --- release.sh ---
# The public half of the release key of the Veydan Project, hex (Ed25519).
RELEASE_PUBKEY=a809a6cf0b1ad6759ce497d75a9d1822ccc0cc68fb075e642ca95f33df2f3946

# release_verify <file> <component> <version> <sig file>
# Whether <file> is the release <version> of <component> signed by the
# release key; why not on stderr. Needs openssl 3 (Debian 12 and 13).
release_verify() {
    local file=$1 component=$2 version=$3 sigfile=$4 sha sig dir ok=0
    command -v openssl >/dev/null || { echo "openssl is needed to check the signature of $file: apt-get install openssl" >&2; return 1; }
    [ -s "$sigfile" ] || { echo "$file has no signature ($(basename "$sigfile")): it is not a release of the Veydan Project" >&2; return 1; }
    sig=$(tr -d '[:space:]' < "$sigfile")
    [[ "$sig" =~ ^[0-9a-f]{128}$ ]] || { echo "$(basename "$sigfile"): not a signature (128 hex)" >&2; return 1; }
    sha=$(sha256sum "$file" | cut -d' ' -f1)
    dir=$(mktemp -d)
    # The key as DER (SubjectPublicKeyInfo of Ed25519: a fixed head and
    # the 32 bytes), the signature as its 64 bytes, the message as signed.
    printf '%b' "$(printf '302a300506032b6570032100%s' "$RELEASE_PUBKEY" | sed 's/../\\x&/g')" > "$dir/key.der"
    printf '%b' "$(printf '%s' "$sig" | sed 's/../\\x&/g')" > "$dir/sig"
    printf 'vcloud-release/1\n%s\n%s\n%s' "$component" "$version" "$sha" > "$dir/msg"
    openssl pkeyutl -verify -pubin -keyform DER -inkey "$dir/key.der" -rawin -in "$dir/msg" -sigfile "$dir/sig" >/dev/null 2>&1 && ok=1
    rm -rf "$dir"
    [ "$ok" = 1 ] || { echo "$file: the signature is not the release key's for $component $version" >&2; return 1; }
}
# --- end of release.sh ---

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
    command -v openssl >/dev/null || die "openssl is needed to check the signature of the kit: apt-get install openssl"
    kit=$KITS/$KIT_VERSION
    tmp=$(mktemp -d)
    name=veydan-server-$KIT_VERSION.tar.gz
    curl -fsSL -o "$tmp/$name" "$RELEASES/v$KIT_VERSION/$name" || die "could not download $name from $RELEASES/v$KIT_VERSION"
    curl -fsSL -o "$tmp/SHA256SUMS" "$RELEASES/v$KIT_VERSION/SHA256SUMS" || die "could not download SHA256SUMS of v$KIT_VERSION"
    ( cd "$tmp" && grep " $name\$" SHA256SUMS | sha256sum -c --quiet - ) || die "$name does not match SHA256SUMS"
    # The sums come from the same release as the file, so they only catch a
    # broken download; what proves the kit is ours is the owner's signature,
    # made offline, checked by the key above.
    curl -fsSL -o "$tmp/$name.sig" "$RELEASES/v$KIT_VERSION/$name.sig" \
        || die "the release v$KIT_VERSION has no signature ($name.sig): nothing is installed from an unsigned kit"
    release_verify "$tmp/$name" server "$KIT_VERSION" "$tmp/$name.sig" || die "$name is not signed by the release key of the Veydan Project: nothing is installed"
    mkdir -p "$kit"
    tar -xzf "$tmp/$name" -C "$kit"
    rm -rf "$tmp"
fi
[ -f "$kit/run.sh" ] || die "no run.sh in the kit at $kit"
exec bash "$kit/run.sh" --from "$from" "$@"
