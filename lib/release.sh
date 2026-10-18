# shellcheck shell=bash
# The signature of a release of the Veydan Project. Sourced, never run:
# by run.sh (fetch_program), by scripts/server/make.sh and by
# scripts/release/service.sh. install.sh carries the same lines, word for
# word, between its two marks (it runs before any kit is there); a test
# holds the two copies equal.
#
# The owner signs every file of a release offline with the release key,
# the one whose public half every agent pins as release_pubkey:
#   vcloud release-sign --component <c> --version <v> --file <f>
# Ed25519 over "vcloud-release/1\n<component>\n<version>\n<sha256 of the file>",
# 128 hex in <file>.sig beside the file in the release. A component is
# server (this kit), link, call, vpush or vguard (the programs); the kit of
# kit.run is signed as kit, so that the one never passes for the other.

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

# The component a program of ours is signed as: vlink → link, vcall →
# call, vpush → vpush, vguard → vguard (vcloud-proto release::COMPONENTS).
release_component() {
    case "$1" in
        vlink) echo link ;;
        vcall) echo call ;;
        *) echo "$1" ;;
    esac
}
