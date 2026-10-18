# shellcheck shell=bash disable=SC2034  # V_* are read by the templates
# Helpers shared by run.sh and the components. Sourced, never run.
#
# Every change to the machine goes through run/put/render, so that
# --dry-run can print it and write the files under $DRY_ROOT instead.

DRY=${DRY:-0}
DRY_ROOT=${DRY_ROOT:-}

say()  { printf '\033[1;32m>>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; WARNINGS+=("$*"); }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }
WARNINGS=()

# Runs a command, or prints it on --dry-run.
run() {
    if [ "$DRY" = 1 ]; then
        printf '   + %s\n' "$*"
    else
        "$@"
    fi
}

# The path a file really goes to (under $DRY_ROOT on --dry-run).
target() { printf '%s%s' "$DRY_ROOT" "$1"; }

mkdirp() { # mkdirp <dir> <mode> <owner:group>
    local d; d=$(target "$1")
    mkdir -p "$d"
    [ "$DRY" = 1 ] && return 0
    chmod "$2" "$d"
    chown "$3" "$d"
}

# put <dest> <mode> <owner:group>   (content on stdin)
put() {
    local dest; dest=$(target "$1")
    mkdir -p "$(dirname "$dest")"
    local tmp; tmp=$(mktemp "$(dirname "$dest")/.put.XXXXXX")
    cat > "$tmp"
    if [ "$DRY" != 1 ]; then
        chmod "$2" "$tmp"
        chown "$3" "$tmp"
    fi
    mv -f "$tmp" "$dest"
}

# Template variables are the shell variables named V_*. Only those are
# replaced, so nginx's $host and the like stay as they are.
render_text() { # render_text <template>
    local vars
    vars=$(compgen -v V_ | sed 's/.*/${&}/' | tr '\n' ' ')
    # shellcheck disable=SC2046
    export $(compgen -v V_)
    envsubst "$vars" < "$1"
}

# render <template> <dest> <mode> <owner:group> [keep]
#
# keep: the file is the admin's once it exists. A rerun leaves it alone and,
# when the template would now give something else, puts that next to it as
# <dest>.new for the admin to merge by hand.
render() {
    local tpl=$1 dest=$2 mode=$3 owner=$4 keep=${5:-}
    local text; text=$(render_text "$tpl")
    local real; real=$(target "$dest")
    if [ "$keep" = keep ] && [ -f "$real" ]; then
        # After "keep": the starts of the lines that stay the kit's.
        [ $# -gt 5 ] && own_lines "$dest" "$text" "${@:6}"
        if [ "$text" != "$(cat "$real")" ]; then
            printf '%s\n' "$text" | put "$dest.new" "$mode" "$owner"
            warn "$dest is kept as it is; the template now gives $dest.new — merge by hand"
        fi
        return 0
    fi
    printf '%s\n' "$text" | put "$dest" "$mode" "$owner"
}

# render_block <template> <dest> <mode> <owner:group> [start of a line]...
#
# The part of a kept file the kit owns: the lines between "# --- kit begin"
# and "# --- kit end" are written anew on every run, and everything around
# them is the admin's. A file that does not exist is written whole.
render_block() {
    local tpl=$1 dest=$2 mode=$3 owner=$4
    local text; text=$(render_text "$tpl")
    local real; real=$(target "$dest")
    if [ ! -f "$real" ]; then
        printf '%s\n' "$text" | put "$dest" "$mode" "$owner"
        return 0
    fi
    local block; block=$(printf '%s\n' "$text" | sed -n '/^# --- kit begin/,/^# --- kit end/p')
    [ -n "$block" ] || die "render_block: $tpl has no kit block"
    if ! grep -q '^# --- kit begin' "$real" || ! grep -q '^# --- kit end' "$real"; then
        printf '%s\n' "$text" | put "$dest.new" "$mode" "$owner"
        warn "$dest has no kit block; the template is next to it as $dest.new — merge by hand"
        return 0
    fi
    {
        sed '/^# --- kit begin/,$d' "$real"
        printf '%s\n' "$block"
        sed '1,/^# --- kit end/d' "$real"
    } | put "$dest" "$mode" "$owner"
    # After the owner: the starts of the lines outside the block that stay
    # the kit's.
    [ $# -gt 4 ] && own_lines "$dest" "$text" "${@:5}"
    return 0
}

# own_lines <dest> <rendered text> <start of a line>...
#
# The lines of a kept file that stay the kit's: the names of the server
# are in them (the address a service checks signed requests against, say),
# and a server that takes other names must not be left with the old ones.
# For each start, the first line of the file that begins with it becomes
# the line of the rendered text that begins with it.
own_lines() {
    local dest=$1 text=$2 real line tmp p; shift 2
    real=$(target "$dest")
    [ -f "$real" ] || return 0
    for p in "$@"; do
        line=$(printf '%s\n' "$text" | P="$p" awk 'index($0, ENVIRON["P"]) == 1 && !f { print; f = 1 }')
        [ -n "$line" ] || continue
        grep -qxF -- "$line" "$real" && continue
        P="$p" awk 'index($0, ENVIRON["P"]) == 1 { found = 1 } END { exit !found }' "$real" || continue
        tmp=$(mktemp)
        P="$p" L="$line" awk 'index($0, ENVIRON["P"]) == 1 && !done { print ENVIRON["L"]; done = 1; next } { print }' "$real" > "$tmp"
        # In place: the file keeps its owner and mode.
        cat "$tmp" > "$real"
        rm -f "$tmp"
        say "$dest: ${line#"${line%%[![:space:]]*}"}"
    done
}

# A secret of 64 hex characters.
secret() { openssl rand -hex 32; }

# fetch_program <program> <repo> <version> <dest>
#
# A program of the Veydan Project from its release on GitHub, for this
# machine (x86_64 or aarch64), checked against the SHA256SUMS and the
# owner's signature (<file>.sig, lib/release.sh) of the
# release; the kit of a checkout or of make server brings them in bin/
# instead. Nothing on a dry run.
# Whether the release <version> of a program must be fetched to <dest>:
# nothing is installed there, or what is there is another release. A build
# of one's own stays (its version says more than X.Y.Z: it was put there on
# purpose), and so does everything while versions.conf names no release.
needs_release() { # needs_release <dest> <version>
    local bin have
    bin=$(target "$1")
    [ -x "$bin" ] || return 0
    [ -n "$2" ] || return 1
    have=$("$bin" --version 2>/dev/null | awk 'NR==1 {print $2}')
    [[ "$have" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && [ "$have" != "$2" ]
}

# Whether the relay has its read policy to put up (components/guard.sh):
# bin/vguard of the kit, a vguard installed, or the release of Veydan-Push
# named by VGUARD_VERSION. A relay is never put up without one.
vguard_at_hand() {
    [ -f "$HERE/bin/vguard" ] || [ -x "$(target /opt/vguard/bin/vguard)" ] || [ -n "${VGUARD_VERSION:-}" ]
}
NO_VGUARD="relay: no vguard, the read policy of the relay (not in bin/ of the kit, none installed, and VGUARD_VERSION of versions.conf names no release of Veydan-Push). Without it anyone with the app key could ask the relay for every gift wrap and every group event, so the relay is not put up: set VGUARD_VERSION in versions.conf, or put bin/vguard into the kit (make build-deploy)"

fetch_program() {
    local prog=$1 repo=$2 version=$3 dest=$4 arch tmp base
    [ -n "$version" ] || die "$prog: no release to take it from yet (${prog^^}_VERSION of versions.conf is empty) and no bin/$prog in the kit"
    arch=$(uname -m)
    case "$arch" in x86_64|aarch64) ;; *) die "$prog: the release has no build for $arch (x86_64 and aarch64); build it and put it in bin/$prog of the kit" ;; esac
    [ "$DRY" = 1 ] && { printf '   + %s %s from the release of %s → %s\n' "$prog" "$version" "$repo" "$dest"; return 0; }
    base="https://github.com/veydanproject/$repo/releases/download/v$version"
    tmp=$(mktemp -d)
    curl -fsSL -o "$tmp/$prog-linux-$arch" "$base/$prog-linux-$arch" || die "$prog $version: could not download $base/$prog-linux-$arch"
    curl -fsSL -o "$tmp/SHA256SUMS" "$base/SHA256SUMS" || die "$prog $version: could not download $base/SHA256SUMS"
    ( cd "$tmp" && grep " $prog-linux-$arch\$" SHA256SUMS | sha256sum -c --quiet - ) || die "$prog $version: $prog-linux-$arch does not match SHA256SUMS"
    # The owner's signature, not the sums of the same release, says the
    # program is ours (lib/release.sh).
    curl -fsSL -o "$tmp/$prog-linux-$arch.sig" "$base/$prog-linux-$arch.sig" \
        || die "$prog $version: the release has no signature ($prog-linux-$arch.sig); nothing is installed unsigned"
    release_verify "$tmp/$prog-linux-$arch" "$(release_component "$prog")" "$version" "$tmp/$prog-linux-$arch.sig" \
        || die "$prog $version: $prog-linux-$arch is not signed by the release key of the Veydan Project"
    install -m 0755 "$tmp/$prog-linux-$arch" "$dest"
    rm -rf "$tmp"
    say "$prog: $version from the release of $repo"
}

# "relay" → "relay.example.org"; a name with a dot is taken as it is.
fqdn() {
    case "$1" in
        *.*) printf '%s' "$1" ;;
        *)   printf '%s.%s' "$1" "$BASE_DOMAIN" ;;
    esac
}

# The first label of a host: "relay.example.org" → "relay".
short() { printf '%s' "${1%%.*}"; }

# This server's word (SERVER of server.conf): what the components report
# under, and the key of its line in MESH_ORIGINS.
server_name() { printf '%s' "$SERVER"; }

has() { [[ " $COMPONENTS " == *" $1 "* ]]; }

ensure_user() { # ensure_user <name> <home>
    id "$1" >/dev/null 2>&1 && return 0
    run useradd --system --home-dir "$2" --no-create-home --shell /usr/sbin/nologin "$1"
}

apt_install() {
    [ "$DRY" = 1 ] && { printf '   + apt-get install %s\n' "$*"; return 0; }
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

# Links a unit kept under /opt into systemd. A unit that already exists as a
# plain file in /etc (an older install) is replaced by the link.
link_unit() { # link_unit </opt/.../name.service>
    local name; name=$(basename "$1")
    if [ -f "/etc/systemd/system/$name" ] && [ ! -L "/etc/systemd/system/$name" ]; then
        run rm -f "/etc/systemd/system/$name"
    fi
    run systemctl link "$1"
    run systemctl daemon-reload
    run systemctl enable "$name"
}

# Links a unit without enabling it: a service run by a timer, say.
link_only() { # link_only </opt/.../name.service>
    local name; name=$(basename "$1")
    if [ -f "/etc/systemd/system/$name" ] && [ ! -L "/etc/systemd/system/$name" ]; then
        run rm -f "/etc/systemd/system/$name"
    fi
    [ -L "/etc/systemd/system/$name" ] || run systemctl link "$1"
    run systemctl daemon-reload
}

# Is an IPv4 address inside one of the IPv4 ranges listed in a file
# (one CIDR per line, # comments)?
cloudflare_ip() { # cloudflare_ip <a.b.c.d> <ranges file>
    local ip=$1 net bits a b c d n m
    IFS=. read -r a b c d <<< "$ip"
    n=$(( (a << 24) | (b << 16) | (c << 8) | d ))
    while read -r net; do
        case "$net" in ''|'#'*|*:*) continue ;; esac
        bits=${net#*/}
        IFS=. read -r a b c d <<< "${net%/*}"
        m=$(( (0xffffffff << (32 - bits)) & 0xffffffff ))
        [ $(( n & m )) = $(( ((a << 24) | (b << 16) | (c << 8) | d) & m )) ] && return 0
    done < "$2"
    return 1
}

# The real address of a name of the network, from MESH_ORIGINS
# ("eu-2=1.2.3.4 relay.example.org=5.6.7.8 …"): the entry named like the
# host (short or full), else the one whose word is the start of the name
# before a "-" (eu-1 for eu-1-relay-1). Nothing when unknown.
origin_of() { # origin_of <fqdn>
    local o k
    for o in $MESH_ORIGINS; do
        k=${o%%=*}
        [ "$k" = "$1" ] || [ "$(fqdn "$k")" = "$1" ] && { printf '%s' "${o#*=}"; return 0; }
    done
    for o in $MESH_ORIGINS; do
        case "$1" in "${o%%=*}"-*) printf '%s' "${o#*=}"; return 0 ;; esac
    done
    return 1
}
