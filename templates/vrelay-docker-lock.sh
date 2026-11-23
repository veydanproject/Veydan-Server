#!/bin/sh
# The second lock of the store and the bus of the relay: nothing reaches the
# containers of the bridge br-vrelay unless it comes from the bridge itself
# or answers what they opened. The first lock is that nothing of them is
# published but on 127.0.0.1 (compose files, docker's own "ip"), and what
# comes from this machine never passes the FORWARD chain, so it stays open.
# A port that docker publishes is opened before ufw's rules are read; this
# chain is read before docker's (DOCKER-USER).
#
# Run by vrelay-docker-lock.service each time docker starts (made by
# components/vrelay.sh); the same every time: the chain is made anew.
#   vrelay-docker-lock.sh        put the lock
#   vrelay-docker-lock.sh check  0 when it is in place
set -eu
BRIDGE=br-vrelay
CHAIN=VRELAY-LOCK

check() {
    "$1" -n -L DOCKER-USER 2>/dev/null | grep -q "^$CHAIN " \
        && "$1" -S "$CHAIN" 2>/dev/null | grep -q -- "-o $BRIDGE -j DROP"
}

lock() {
    ipt=$1
    # No DOCKER-USER: docker of this family does not manage it (IPv6 off).
    $ipt -n -L DOCKER-USER >/dev/null 2>&1 || return 0
    $ipt -N "$CHAIN" 2>/dev/null || $ipt -F "$CHAIN"
    $ipt -A "$CHAIN" -o "$BRIDGE" -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
    $ipt -A "$CHAIN" -i "$BRIDGE" -o "$BRIDGE" -j RETURN
    $ipt -A "$CHAIN" -o "$BRIDGE" -j DROP
    $ipt -A "$CHAIN" -j RETURN
    $ipt -C DOCKER-USER -j "$CHAIN" 2>/dev/null || $ipt -I DOCKER-USER 1 -j "$CHAIN"
}

case "${1:-}" in
    check) check iptables ;;
    "") lock iptables; lock ip6tables; check iptables ;;
    *) echo "vrelay-docker-lock.sh [check]" >&2; exit 2 ;;
esac
