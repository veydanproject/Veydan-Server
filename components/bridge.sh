# shellcheck shell=bash disable=SC2034  # V_* are read by the templates
# A VLink bridge: a door into the network for people whose way to it is
# closed. It keeps no keys of anyone and no data, only passes bytes on; a
# hub of the network dials in to it and does the rest. Everything in
# /opt/vlink:
#   bin/vlink  etc/vlink.env  etc/vlink.service  data/ (the bridge's key and certificate)
# Not behind nginx and without a domain or a certificate to get: the bridge
# is known by its key, made on its first start, and reached at the bare
# address of the server on BRIDGE_PORT.
# The binary: bin/vlink of the kit, or the release of VLINK_VERSION
# (versions.conf). Settings: hooks/bridge.pre.sh. Sourced by run.sh.

P=/opt/vlink
say "bridge: $BRIDGE_PUBLIC_IP:$BRIDGE_PORT$([ "$BRIDGE_PRIVATE" = 1 ] && echo ', private')"

ensure_user vlink "$P"
mkdirp "$P" 0755 root:root
mkdirp "$P/bin" 0755 root:root
mkdirp "$P/etc" 0755 root:root
mkdirp "$P/data" 0700 vlink:vlink

if [ -f "$HERE/bin/vlink" ]; then
    ( cd "$HERE/bin" && sha256sum -c --quiet vlink.sha256 ) \
        || die "bin/vlink does not match bin/vlink.sha256: a damaged kit"
    run install -m 0755 "$HERE/bin/vlink" "$P/bin/vlink"
elif [ ! -x "$(target "$P/bin/vlink")" ]; then
    fetch_program vlink Veydan-Link "${VLINK_VERSION:-}" "$P/bin/vlink"
fi

# The settings are the kit's (server.conf holds them); the unit names the
# defaults and reads this file over them.
{
    echo "# The bridge of this server. Made by run.sh from server.conf; every run"
    echo "# writes it anew. More settings of vlink may go into server.conf's"
    echo "# BRIDGE_ENV, one NAME=value each."
    echo "VLINK_LISTEN=0.0.0.0:$BRIDGE_PORT"
    [ "$BRIDGE_PRIVATE" = 1 ] && echo "VLINK_PRIVATE=true"
    # A network with a registry of its own names it; otherwise the one built
    # into vlink is told.
    [ -n "${VLINK_REGISTRY_HOST:-}" ] && echo "VLINK_REGISTRY=https://$(fqdn "$VLINK_REGISTRY_HOST")/vlink"
    for kv in ${BRIDGE_ENV:-}; do echo "$kv"; done
} | put "$P/etc/vlink.env" 0644 root:root
put "$P/etc/vlink.service" 0644 root:root < "$HERE/templates/systemd/vlink.service"

if [ "$FIREWALL" = ufw ]; then
    run ufw allow "$BRIDGE_PORT/tcp"
fi
link_unit "$P/etc/vlink.service"
run systemctl restart vlink

# The bridge's reference (address and key) and the link the app takes: the
# key is made by the first start, so they are read after it.
BRIDGE_REF="$BRIDGE_PUBLIC_IP:$BRIDGE_PORT#<id>" BRIDGE_LINK=""
if [ "$DRY" != 1 ]; then
    sleep 2
    systemctl is-active --quiet vlink || warn "vlink is not running: journalctl -u vlink"
    vl() { runuser -u vlink -- env VLINK_DATA="$P/data" "$P/bin/vlink" "$@" 2>/dev/null; }
    BRIDGE_REF=$(vl id --addr "$BRIDGE_PUBLIC_IP:$BRIDGE_PORT" || true)
    BRIDGE_LINK=$(vl link --addr "$BRIDGE_PUBLIC_IP:$BRIDGE_PORT" || true)
    [ -n "$BRIDGE_REF" ] || { BRIDGE_REF="$BRIDGE_PUBLIC_IP:$BRIDGE_PORT#?"; warn "the bridge did not tell its key yet: runuser -u vlink -- env VLINK_DATA=$P/data $P/bin/vlink id --addr $BRIDGE_PUBLIC_IP:$BRIDGE_PORT"; }
fi

CARD_SHOW+="$(msg card_bridge)  $BRIDGE_REF"$'\n'
[ -n "$BRIDGE_LINK" ] && CARD_SHOW+="  $BRIDGE_LINK"$'\n'
if [ "$BRIDGE_PRIVATE" = 1 ]; then
    CARD_SHOW+="$(msg card_bridge_private)"$'\n'
else
    CARD_SHOW+="$(msg card_bridge_public)"$'\n'
fi
CARD_SHOW+="$(msg card_bridge_port) $BRIDGE_PORT/tcp"$'\n'
CARD_EXTRA+="Bridge:              $BRIDGE_REF"$'\n'
CARD_EXTRA+="   settings: $P/etc/vlink.env (from server.conf)   key: $P/data (keep it: it is the bridge)   log: journalctl -u vlink"$'\n'
