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

# Root never works by a path inside a folder another user may write: that
# user could put a link there, and root would write, own or read what it
# points to. Whether nobody but root can change a folder and the folders
# above it (a folder with the sticky bit, /tmp, counts as root's).
root_only_dir() { # root_only_dir <dir>
    local d=$1 s
    # Not root (the kit run against a staged root by its tests): there is no
    # right of root for a link to borrow.
    [ "$(id -u)" = 0 ] || return 0
    while :; do
        [ ! -L "$d" ] || return 1
        s=$(stat -c '%u %a' -- "$d" 2>/dev/null) || return 1
        [ "${s%% *}" = 0 ] || return 1
        # Group or others may write: only with the sticky bit.
        [ $((8#${s#* } & 8#022)) = 0 ] || [ $((8#${s#* } & 8#1000)) != 0 ] || return 1
        [ "$d" != / ] || return 0
        d=$(dirname -- "$d")
    done
}

# A command as the user of a folder that is not root's alone: what a link
# planted there could reach, that user reaches by itself anyway.
as_user() { # as_user <user> <command>...
    local u=$1; shift
    [ "$u" != root ] && [ "$u" != 0 ] || die "the kit's mistake: root was to work in a folder another user may write ($*)"
    runuser -u "$u" -- "$@"
}

mkdirp() { # mkdirp <dir> <mode> <owner:group>
    local d; d=$(target "$1")
    if [ "$DRY" = 1 ]; then mkdir -p "$d"; return 0; fi
    if root_only_dir "$(dirname -- "$d")"; then
        mkdir -p "$d"
        chmod "$2" "$d"
        chown "$3" "$d"
        return 0
    fi
    # Its folder is another user's: made and set by the owner it is for.
    [ ! -L "$d" ] || die "$1 is a symbolic link in a folder another user may write: the kit follows none; move it away and run again"
    as_user "${3%%:*}" mkdir -p "$d"
    as_user "${3%%:*}" chmod "$2" "$d"
    as_user "${3%%:*}" chgrp "${3#*:}" "$d"
}

# put <dest> <mode> <owner:group>   (content on stdin)
#
# A new file renamed over the old one: a link or a file at <dest> is
# replaced, never followed (mv -T: a folder there is refused). In a folder
# another user may write (the access files of the relay, the secrets of
# vpush) the file is written by its owner, who can write the folder.
put() {
    local dest; dest=$(target "$1")
    mkdir -p "$(dirname "$dest")"
    if [ "$DRY" != 1 ] && ! root_only_dir "$(dirname -- "$dest")"; then
        # shellcheck disable=SC2016  # the script of the owner, its own $1..$3
        as_user "${3%%:*}" sh -c 'umask 077; t=$(mktemp "$(dirname "$1")/.put.XXXXXX") || exit 1
            if cat > "$t" && chmod "$2" "$t" && chgrp "$3" "$t" && mv -fT "$t" "$1"; then exit 0; fi
            rm -f "$t"; exit 1' put "$dest" "$2" "${3#*:}" \
            || die "put: $1 could not be written as ${3%%:*}"
        return 0
    fi
    local tmp; tmp=$(mktemp "$(dirname "$dest")/.put.XXXXXX")
    cat > "$tmp"
    if [ "$DRY" != 1 ]; then
        chmod "$2" "$tmp"
        chown "$3" "$tmp"
    fi
    mv -fT "$tmp" "$dest"
}

# A file of a folder another user may write, read as that user: a link
# planted there gives nothing that user could not read itself.
read_as() { # read_as <user> <path>
    if [ "$DRY" = 1 ]; then cat -- "$(target "$2")"; return; fi
    as_user "$1" cat -- "$2"
}

# A regular file, not a link (the test of a path in another user's folder).
plain_file() { [ -f "$(target "$1")" ] && [ ! -L "$(target "$1")" ]; }

# The files of a service in a folder it writes (the access files of the
# relay), given back to it on every run without root following a link put
# there: a link is told and left; the owner is set with chown -h (the
# entry itself, never what it points to); the mode by the user, who can
# change only its own files.
own_files() { # own_files <dir> <user> <mode> <file>...
    local dir=$1 u=$2 mode=$3 f p; shift 3
    for f in "$@"; do
        p=$(target "$dir/$f")
        if [ -L "$p" ]; then
            warn "$dir/$f is a symbolic link: the kit follows none and leaves it; $u writes the file itself, so a link there was put by somebody else. Look at it (ls -l $dir), remove it, and run again"
            continue
        fi
        [ -e "$p" ] || continue
        [ -f "$p" ] || { warn "$dir/$f is not a file: left as it is"; continue; }
        if [ "$DRY" = 1 ]; then
            run chown -h "$u:$u" "$dir/$f"
            run runuser -u "$u" -- chmod "$mode" "$dir/$f"
            continue
        fi
        [ "$(stat -c %U -- "$p")" = "$u" ] || chown -h "$u:$u" "$p"
        runuser -u "$u" -- chmod "$mode" "$p"
    done
}

# Template variables are the shell variables named V_*. Only those are
# replaced, so nginx's $host and the like stay as they are.
render_text() { # render_text <template>
    local vars names
    names=$(compgen -v V_ || true)
    # No V_ variable yet: a bare `export` would print the environment into
    # the text, and envsubst without a list would replace every variable.
    [ -n "$names" ] || { cat "$1"; return 0; }
    vars=$(printf '%s\n' $names | sed 's/.*/${&}/' | tr '\n' ' ')
    # shellcheck disable=SC2086,SC2163  # the names, split on purpose
    export $names
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
# bin/vguard of the kit, a vguard installed, or the release of Veydan-Guard
# named by VGUARD_VERSION. A relay is never put up without one.
vguard_at_hand() {
    [ -f "$HERE/bin/vguard" ] || [ -x "$(target /opt/vguard/bin/vguard)" ] || [ -n "${VGUARD_VERSION:-}" ]
}
NO_VGUARD="relay: no vguard, the read policy of the relay (not in bin/ of the kit, none installed, and VGUARD_VERSION of versions.conf names no release of Veydan-Guard). Without it anyone with the app key could ask the relay for every gift wrap and every group event, so the relay is not put up: set VGUARD_VERSION in versions.conf, or put bin/vguard into the kit (make build-deploy)"

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

# The store and the bus of the vrelay engine: docker compose over the
# relay's own compose.yaml and the kit's layer (templates/relay-compose).
VRELAY_COMPOSE=/opt/vrelay/compose
vrelay_compose() {
    # A server of the mesh: mesh.yaml alone, the host's network (lib/mesh.sh).
    if [ -f "$(target "$VRELAY_COMPOSE/mesh.yaml")" ]; then
        run docker compose --project-directory "$VRELAY_COMPOSE" --env-file "$VRELAY_COMPOSE/.env" \
            -f "$VRELAY_COMPOSE/mesh.yaml" "$@"
        return
    fi
    run docker compose --project-directory "$VRELAY_COMPOSE" --env-file "$VRELAY_COMPOSE/.env" \
        -f "$VRELAY_COMPOSE/compose.yaml" -f "$VRELAY_COMPOSE/compose.kit.yaml" "$@"
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

# The memory of a server of vrelay, in MB (README, "The vrelay engine": the
# table of 8, 16 and 32 GB). Every program gets a limit, and the limits add
# up to the machine: Cassandra's container (its heap, its direct buffers,
# the memtables off the heap, the JVM's own, a share of page cache), NATS's
# container, the units of vrelay write and vrelay serve, and what has no
# limit of its own (the system, nginx, the media server, vpush, a call
# node). What serve's limit holds is the default of RELAY_MAX_CONNECTIONS.
#   vrelay_memory <MemTotal MB> [<heap MB>] [<components>]
# sets MEM_HEAP MEM_DIRECT MEM_PAGE MEM_CASSANDRA MEM_NATS MEM_GOMEMLIMIT
# MEM_WRITE MEM_OTHERS MEM_NGINX MEM_SERVE MEM_CONNECTIONS, and MEM_SHORT:
# the MB the machine lacks for the estimate of the programs without a
# limit (0 when it has them).
VRELAY_SERVE_KB_PER_CONN=96   # measured: about 80 KB a connection of vrelay serve at 35 000
VRELAY_NGINX_KB_PER_CONN=40   # not measured: nginx's TLS and its two sockets of a WebSocket
vrelay_memory() {
    local mem=$1 heap=${2:-} comps=" ${3:-relay} " avail per
    _vm_clamp() { local v=$1; [ "$v" -ge "$2" ] || v=$2; [ "$v" -le "$3" ] || v=$3; printf '%s' "$v"; }
    # From 32 768 MB of MemTotal on the machine is taken for a node of the
    # database (a "32 GB" machine shows 31 900 to 32 900 MB: either side).
    # The heap: a fifth of a machine below 32 GB, which runs everything, 1.5
    # to 4 GB; a quarter of a larger one, a node of the database, at most
    # 16 GB (G1, the memtables off the heap). Cassandra 5.0's own
    # cassandra-env.sh would take half the machine.
    if [ -z "$heap" ]; then
        if [ "$mem" -lt 32768 ]; then heap=$(_vm_clamp $((mem / 5 / 256 * 256)) 1536 4096)
        else heap=$(_vm_clamp $((mem / 4 / 256 * 256)) 1536 16384); fi
    fi
    MEM_HEAP=$heap
    # The direct buffers (the chunk cache, the network): half the heap,
    # given (-XX:MaxDirectMemorySize): the image counts them from the memory
    # of the host, not of the container.
    MEM_DIRECT=$((heap / 2))
    # What has no limit: the system (the kernel, sshd, journald, docker,
    # chrony) and each other component of this server; nginx below, by the
    # connections. Not measured: estimates.
    MEM_OTHERS=768
    [[ "$comps" == *" media "* ]] && MEM_OTHERS=$((MEM_OTHERS + 512))   # blossom and sqld
    [[ "$comps" == *" vpush "* ]] && MEM_OTHERS=$((MEM_OTHERS + 256))
    [[ "$comps" == *" call "* ]] && MEM_OTHERS=$((MEM_OTHERS + 768))
    if [ "$mem" -lt 32768 ]; then
        # NATS: a quarter of what is above 4 GB, 1 to 6 GB (3 GB on 16 GB).
        # At 35 000 connections it held 0.8-0.9 GB, a subscription a live
        # key; with Go's soft limit at 768 MiB its collector ran without
        # pause. The soft limit four fifths of the container.
        MEM_NATS=$(_vm_clamp $(((mem - 4096) / 4)) 1024 6144)
        # The container of Cassandra holds its page cache too (the kernel
        # charges the pages of its files to it): the heap, the direct
        # buffers, the memtables off the heap (a quarter of the heap), 1 GB
        # of the JVM's own (metaspace, code, threads, the bloom filters and
        # compression metadata of a young store) and a twentieth of the
        # machine of page cache (384 MB to 2 GB; the rest of the page cache
        # is what the others leave).
        MEM_PAGE=$(_vm_clamp $((mem / 20)) 384 2048)
        MEM_CASSANDRA=$((heap + MEM_DIRECT + heap / 4 + 1024 + MEM_PAGE))
        MEM_WRITE=$(_vm_clamp $((mem / 16)) 512 2048)
        # The rest is the clients': vrelay serve and nginx, by what a
        # connection takes of each.
        avail=$((mem - MEM_CASSANDRA - MEM_NATS - MEM_WRITE - MEM_OTHERS))
        per=$((VRELAY_SERVE_KB_PER_CONN + VRELAY_NGINX_KB_PER_CONN))
        MEM_SERVE=$((avail * VRELAY_SERVE_KB_PER_CONN / per))
    else
        # A node of the database: NATS an eighth (at most 8 GB, the presence
        # of a region is in its memory), serve 4 GB, the writer 2 GB, the
        # rest Cassandra's.
        MEM_NATS=$(_vm_clamp $((mem / 8)) 1024 8192)
        MEM_WRITE=2048
        MEM_SERVE=4096
        avail=$((MEM_SERVE * (VRELAY_SERVE_KB_PER_CONN + VRELAY_NGINX_KB_PER_CONN) / VRELAY_SERVE_KB_PER_CONN))
        MEM_CASSANDRA=$((mem - MEM_NATS - MEM_WRITE - MEM_OTHERS - avail))
        MEM_PAGE=$((MEM_CASSANDRA - heap - MEM_DIRECT - heap / 4 - 1024))
    fi
    MEM_GOMEMLIMIT=$((MEM_NATS * 4 / 5))
    # serve has 768 MB at least. On a small machine with several components
    # the estimates of the others are then not all there; the page cache in
    # Cassandra's limit gives way first (the kernel takes it back), and what
    # is short past it is MEM_SHORT.
    MEM_SHORT=0
    if [ "$MEM_SERVE" -lt 768 ]; then
        MEM_SHORT=$(((768 - MEM_SERVE) * (VRELAY_SERVE_KB_PER_CONN + VRELAY_NGINX_KB_PER_CONN) / VRELAY_SERVE_KB_PER_CONN - MEM_PAGE))
        [ "$MEM_SHORT" -ge 0 ] || MEM_SHORT=0
        MEM_SERVE=768
    fi
    MEM_NGINX=$((MEM_SERVE * VRELAY_NGINX_KB_PER_CONN / VRELAY_SERVE_KB_PER_CONN))
    # What serve's limit holds, in thousands; at most 50 000 (no load test
    # went past 35 000, and the CPU of the machine is the other bound: a
    # larger number is RELAY_MAX_CONNECTIONS of server.conf).
    MEM_CONNECTIONS=$((MEM_SERVE * 1024 / VRELAY_SERVE_KB_PER_CONN / 1000 * 1000))
    [ "$MEM_CONNECTIONS" -le 50000 ] || MEM_CONNECTIONS=50000
    unset -f _vm_clamp
}
