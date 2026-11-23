#!/bin/sh
# The local lock of the relay: which users of this machine may open the
# ports of the store, the bus and the statistics. Cassandra's JMX (7199, no
# password: LOCAL_JMX), the page of NATS (8222) and the statistics of vrelay
# (7783, 7784) have no login, and a container on the host's network (the
# mesh) listens on the host's own loopback; so every other service of the
# box (the media server, vpush, the call node, nginx's workers) is kept
# from them by the owner of the socket that opens the connection
# (nftables, meta skuid), on the loopback, where a connection to an address
# of this machine goes:
#   7199, 7000      root, vrelay-db (Cassandra: its nodetool, its own node)
#   9042            root, vrelay, vrelay-db (the clients of CQL; the one-shots
#                   of the kit run as vrelay-db)
#   4222            root, vrelay, vrelay-bus
#   6222, 7422      root, vrelay-bus (NATS's routes and leaf links)
#   8222            root, vrelay, vrelay-bus (its health check), vagent
#   7783, 7784      root, vrelay, vagent
# A user missing here (vagent on a server without the agent) is left out.
# Only the opening of a connection is judged (a SYN): the answers, and what
# comes from other machines (the mesh, on wg0), pass by. The chain is read
# before docker's (priority -150, before the NAT of a port docker
# publishes), and it is made anew every time.
#
# Run by vrelay-local-lock.service at boot, before docker, and by the kit at
# every run (components/vrelay.sh, run.sh); checked by veydan-server audit.
#   vrelay-local-lock.sh        put the lock
#   vrelay-local-lock.sh check  0 when it is in place as it would be put now
#   vrelay-local-lock.sh rules  the rules, on the output (nothing put)
set -eu
TABLE=veydan_local

# The uids of the users given and root, in order (as nft lists them), those
# missing left out.
uids() {
    { echo 0; for u in "$@"; do id -u "$u" 2>/dev/null || true; done; } | sort -nu | paste -sd, - | sed 's/,/, /g'
}

rules() {
    db=$(uids vrelay-db)
    cql=$(uids vrelay vrelay-db)
    bus=$(uids vrelay vrelay-bus)
    nats=$(uids vrelay-bus)
    page=$(uids vrelay vrelay-bus vagent)
    stats=$(uids vrelay vagent)
    cat <<EOF
table inet $TABLE {
	chain out {
		type filter hook output priority -150; policy accept;
		oifname != "lo" return
		tcp flags & (syn | ack) != syn return
		tcp dport { 7000, 7199 } meta skuid != { $db } counter reject with tcp reset
		tcp dport 9042 meta skuid != { $cql } counter reject with tcp reset
		tcp dport 4222 meta skuid != { $bus } counter reject with tcp reset
		tcp dport { 6222, 7422 } meta skuid != { $nats } counter reject with tcp reset
		tcp dport 8222 meta skuid != { $page } counter reject with tcp reset
		tcp dport { 7783, 7784 } meta skuid != { $stats } counter reject with tcp reset
	}
}
EOF
}

# The rules of the chain as nft lists them, without the counters: what
# check compares (the lines of the rules, in their order).
rule_lines() { grep -E '^[[:space:]]*(oifname|tcp )' | sed -E 's/counter packets [0-9]+ bytes [0-9]+ /counter /; s/^[[:space:]]+//; s/[[:space:]]+$//'; }

lock() {
    command -v nft >/dev/null || { echo "vrelay-local-lock: no nft (the package nftables)" >&2; exit 1; }
    {
        if nft list table inet "$TABLE" >/dev/null 2>&1; then printf 'delete table inet %s\n' "$TABLE"; fi
        rules
    } | nft -f -
}

check() {
    command -v nft >/dev/null || return 1
    have=$(nft list table inet "$TABLE" 2>/dev/null) || return 1
    printf '%s\n' "$have" | grep -q 'type filter hook output priority' || return 1
    [ "$(printf '%s\n' "$have" | rule_lines)" = "$(rules | rule_lines)" ]
}

case "${1:-}" in
    "") lock; check ;;
    check) check ;;
    rules) rules ;;
    *) echo "vrelay-local-lock.sh [check|rules]" >&2; exit 2 ;;
esac
