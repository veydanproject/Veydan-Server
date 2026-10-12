# shellcheck shell=bash disable=SC2034
# The component bridge (components/bridge.sh): its settings, asked and
# checked before anything is installed. Sourced by run.sh.
#
#   BRIDGE_PORT       the TCP port the bridge listens on. 443 is the one that
#                     looks like any web server and is the least blocked
#   BRIDGE_PRIVATE    1: the bridge tells no registry and is used by those
#                     who are given its reference; 0: anybody's
#   BRIDGE_PUBLIC_IP  the address the world reaches this server at. Empty:
#                     the one its default route goes out from
BRIDGE_PORT=${BRIDGE_PORT:-443}
BRIDGE_PRIVATE=${BRIDGE_PRIVATE:-0}
BRIDGE_PUBLIC_IP=${BRIDGE_PUBLIC_IP:-}
EXTRA_CONF_VARS+=" BRIDGE_PORT BRIDGE_PRIVATE BRIDGE_PUBLIC_IP"

if [ "$FIRST" = 1 ]; then
    ask BRIDGE_PORT q_bridge_port
    ask BRIDGE_PRIVATE q_bridge_private "0 1"
fi
[[ "$BRIDGE_PORT" =~ ^[0-9]{1,5}$ ]] && [ "$BRIDGE_PORT" -ge 1 ] && [ "$BRIDGE_PORT" -le 65535 ] || die "BRIDGE_PORT: a TCP port"
BRIDGE_PORT=$((10#$BRIDGE_PORT))
case "$BRIDGE_PRIVATE" in 0|1) ;; *) die "BRIDGE_PRIVATE is 0 or 1" ;; esac
# nginx holds 80 and 443 on a server with a relay, media or push.
if sites_wanted && { [ "$BRIDGE_PORT" = 443 ] || [ "$BRIDGE_PORT" = 80 ]; }; then
    die "BRIDGE_PORT=$BRIDGE_PORT is nginx's on a server with a relay, media or push: another port (8443), or a server of its own for the bridge"
fi
if has call && { [ "$BRIDGE_PORT" = "${CALL_PORT:-8443}" ] || [ "$BRIDGE_PORT" = 3478 ] || [ "$BRIDGE_PORT" = "${CALL_SFU_PORT:-3479}" ]; }; then
    die "BRIDGE_PORT=$BRIDGE_PORT is the call node's: another port"
fi
if [ -z "$BRIDGE_PUBLIC_IP" ]; then
    BRIDGE_PUBLIC_IP=$( { ip -4 route get 1.1.1.1 2>/dev/null || true; } | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n1)
    [ -n "$BRIDGE_PUBLIC_IP" ] || BRIDGE_PUBLIC_IP=$( { hostname -I 2>/dev/null || true; } | awk '{print $1}')
fi
[[ "$BRIDGE_PUBLIC_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "BRIDGE_PUBLIC_IP: the public IPv4 of this server, not \"$BRIDGE_PUBLIC_IP\""
