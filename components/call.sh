# shellcheck shell=bash disable=SC2034  # V_* are read by the templates
# VCall, the node of calls (STUN, TURN, the SFU of groups): the binary made
# by `make build-deploy` (deploy/bin/vcall). Everything in /opt/vcall:
#   bin/vcall  etc/vcall.env  etc/vcall.service  data/ (the node's key and TURN secret)
# Not behind nginx: clients reach it at the bare IP, TLS pinned to the
# node's id, on CALL_PORT (8443: nginx holds 443), STUN/TURN on 3478 UDP
# and TCP, the SFU on CALL_SFU_PORT, relayed traffic on CALL_RELAY_PORTS.
# The key in data/ is made on the first run, by `vcall id` before the node
# starts, and kept: it is the node's id, so a rerun leaves it alone.
# Sourced by run.sh.

P=/opt/vcall
say "call"

ensure_user vcall "$P"
mkdirp "$P" 0755 root:root
mkdirp "$P/bin" 0755 root:root
mkdirp "$P/etc" 0750 root:vcall
mkdirp "$P/data" 0750 vcall:vcall

# The binary: from the kit when it is there; else the installed one stays;
# else the release of VCALL_VERSION (versions.conf).
if [ -f "$HERE/bin/vcall" ]; then
    ( cd "$HERE/bin" && sha256sum -c --quiet vcall.sha256 ) \
        || die "bin/vcall does not match bin/vcall.sha256: a damaged kit"
    run install -m 0755 "$HERE/bin/vcall" "$P/bin/vcall"
    say "vcall: $(cat "$HERE/bin/vcall.RELEASE" 2>/dev/null || echo '?')"
elif [ ! -x "$(target "$P/bin/vcall")" ]; then
    fetch_program vcall Veydan-Call "${VCALL_VERSION:-}" "$P/bin/vcall"
fi

V_CALL_PORT=$CALL_PORT
V_CALL_PUBLIC_IP=$CALL_PUBLIC_IP
V_CALL_RELAY_PORTS=$CALL_RELAY_PORTS
V_CALL_SFU_PORT=$CALL_SFU_PORT
V_REGION=$REGION
if [ -n "${VLINK_REGISTRY_HOST:-}" ]; then
    V_CALL_REGISTRY_LINE="VCALL_REGISTRY=https://$(fqdn "$VLINK_REGISTRY_HOST")/vlink"
else
    V_CALL_REGISTRY_LINE="# no registry in this mesh (VLINK_REGISTRY_HOST is empty)"
fi
# The template is vcall-env.conf: a file named *.env is a secret to git.
render "$HERE/templates/vcall-env.conf" "$P/etc/vcall.env" 0640 root:vcall keep "VCALL_REGISTRY="
render "$HERE/templates/systemd/vcall.service" "$P/etc/vcall.service" 0644 root:root

if [ "$FIREWALL" = ufw ]; then
    say "call: firewall (control $CALL_PORT/tcp, 3478 udp+tcp, sfu $CALL_SFU_PORT udp+tcp, relay $CALL_RELAY_PORTS/udp)"
    run ufw allow "$CALL_PORT/tcp"
    run ufw allow 3478/udp
    run ufw allow 3478/tcp
    run ufw allow "$CALL_SFU_PORT/udp"
    run ufw allow "$CALL_SFU_PORT/tcp"
    run ufw allow "${CALL_RELAY_PORTS/-/:}/udp"
fi

# The node's reference for the manifest: address:port#id. `vcall id` makes
# the key when there is none, so it runs before the node starts: two
# processes making the key at once could each write their own, and the
# node would run under another id than the manifest names.
CALL_REF="$CALL_PUBLIC_IP:$CALL_PORT#<id: vcall id --data $P/data>"
if [ "$DRY" != 1 ]; then
    if ref=$(runuser -u vcall -- "$P/bin/vcall" id --data "$P/data" --addr "$CALL_PUBLIC_IP:$CALL_PORT"); then
        CALL_REF=$ref
        say "call: $CALL_REF"
    else
        die "vcall could not make or read its key in $P/data: see the line above"
    fi
else
    run runuser -u vcall -- "$P/bin/vcall" id --data "$P/data" --addr "$CALL_PUBLIC_IP:$CALL_PORT"
fi

link_unit "$P/etc/vcall.service"
run systemctl restart vcall
if [ "$DRY" != 1 ]; then
    sleep 2
    systemctl is-active --quiet vcall || warn "vcall is not running: journalctl -u vcall"
fi
