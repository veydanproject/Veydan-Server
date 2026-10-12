# shellcheck shell=bash disable=SC2034  # V_* are read by the templates
# What the app's manifest needs from this server, and every address and
# key of it:
#   /opt/veydan/manifest-node.json   for scripts
#   /opt/veydan/server.txt           for a person: the card
# The entries follow crates/messenger/transport/src/manifest.rs. Both files
# are root's only. The card is also printed at the end of the run.
# Sourced by run.sh.

say "manifest: $STATE/manifest-node.json"

regions=$(jq -cn --arg r "$REGION" '[$r]')
relay_entry=null media_entry=null push_entry=null call_entry=null
if has relay; then
    relay_entry=$(jq -n --arg id "$NETWORK-$(short "$RELAY_FQDN")" --arg url "wss://$RELAY_FQDN" \
        --arg key "$MESH_APP_KEY" --argjson regions "$regions" \
        '{id: $id, url: $url, regions: $regions, read: true, write: true,
          auth: {type: "api_key", key: $key}}')
fi
if has media; then
    media_entry=$(jq -n --arg id "$NETWORK-$(short "$MEDIA_FQDN")" --arg url "https://$MEDIA_FQDN" \
        --argjson regions "$regions" '{id: $id, type: "blossom", url: $url, regions: $regions}')
fi
if has vpush; then
    push_entry=$(jq -n --arg id "$NETWORK-$(short "$VPUSH_FQDN")" --arg url "https://$VPUSH_FQDN" \
        --argjson regions "$regions" '{id: $id, url: $url, regions: $regions}')
fi
# The node of calls is reached at its bare IP, TLS pinned to its id
# (CALL_REF, from components/call.sh). The class is the manifest builder's
# to set; "project" is what it gives the nodes of the network's owner.
if has call; then
    call_entry=$(jq -n --arg ref "$CALL_REF" --argjson sfu "$CALL_SFU_PORT" --argjson regions "$regions" \
        '{ref: $ref, turn_port: 3478, sfu_port: $sfu, class: "project", regions: $regions}')
fi

peers=$(printf '%s\n' $PEERS | sed '/^$/d' | jq -R . | jq -cs .)
media_peers=$(printf '%s\n' $MEDIA_PEERS | sed '/^$/d' | jq -R . | jq -cs .)
vpush_release=""
[ -f "$HERE/bin/RELEASE" ] && vpush_release=$(cat "$HERE/bin/RELEASE")
vcall_release=""
[ -f "$HERE/bin/vcall.RELEASE" ] && vcall_release=$(cat "$HERE/bin/vcall.RELEASE")
media_store=disk
[ -n "$S3_ENDPOINT" ] && media_store="$S3_ENDPOINT/$S3_BUCKET"

json=$(jq -n \
    --arg generated "$(date -u +%FT%TZ)" --arg base "$BASE_DOMAIN" --arg network "$NETWORK" \
    --arg server "$SERVER" --arg region "$REGION" --arg components "$COMPONENTS" \
    --argjson relay "$relay_entry" --argjson media "$media_entry" --argjson push "$push_entry" \
    --argjson call "$call_entry" \
    --arg app_key "$MESH_APP_KEY" --arg peer_key "$MESH_PEER_KEY" \
    --argjson peers "$peers" --argjson media_peers "$media_peers" --arg media_store "$media_store" \
    --arg strfry "$STRFRY_TAG ($STRFRY_COMMIT)" --arg blossom "$BLOSSOM_COMMIT (deno $DENO_VERSION)" \
    --arg libsql "$LIBSQL_VERSION" --arg vpush "$vpush_release" --arg vcall "$vcall_release" \
    '{
      generated_at: $generated, base_domain: $base, network: $network, server: $server, region: $region,
      components: ($components | split(" ")),
      manifest: {
        relays: [$relay | select(. != null)],
        media:  [$media | select(. != null)],
        push:   [$push  | select(. != null)],
        calls:  [$call  | select(. != null)]
      },
      mesh: {
        app_key: $app_key,
        app_key_checked_by: "nginx, /opt/veydan/nginx/10-keys.conf, same on every relay",
        peer_key: $peer_key,
        peers: $peers,
        media_peers: $media_peers,
        media_store: $media_store,
        s3_env: "/opt/blossom/etc/blossom.env",
        vpush_secrets: "/opt/vpush/etc/secrets/"
      },
      versions: {strfry: $strfry, blossom: $blossom, libsql: $libsql, vpush: $vpush, vcall: $vcall}
    }')
printf '%s\n' "$json" | put "$STATE/manifest-node.json" 0600 root:root

# The card: what the admin needs, in their language.
card() {
    echo "$(msg card_ready)  ($NETWORK, $SERVER, $(date -u +%F))"
    has relay && printf '  %-7s wss://%s   %s: %s\n' "$(msg card_relay)" "$RELAY_FQDN" "$(msg card_relay_key)" "$MESH_APP_KEY"
    has media && printf '  %-7s https://%s\n' "$(msg card_media)" "$MEDIA_FQDN"
    has vpush && printf '  %-7s https://%s\n' "$(msg card_push)" "$VPUSH_FQDN"
    has call  && printf '  %-7s %s\n' "$(msg card_call)" "$CALL_REF"
    has relay && echo "$(msg card_app)"
    has vpush && echo "$(msg card_push_note)"
    sites_wanted && echo "$(msg card_next)"
    echo "$(msg card_file)"
}

{
    card
    [ -n "$CARD_SHOW" ] && printf '\n%s' "$CARD_SHOW"
    echo
    echo "== Into the manifest of the network (crates/messenger/transport/manifest) =="
    if has relay; then echo; echo '"relays": ['; jq . <<< "$relay_entry"; echo ']'; fi
    if has media; then echo; echo '"media": ['; jq . <<< "$media_entry"; echo ']'; fi
    if has vpush; then echo; echo '"push": ['; jq . <<< "$push_entry"; echo ']'; fi
    if has call; then echo; echo '"calls": ['; jq . <<< "$call_entry"; echo ']'; fi
    echo
    echo "== Keys of the network (server.conf, the same on every server) =="
    echo "App key (in the manifest of every relay):  $MESH_APP_KEY"
    echo "   wss://<relay>/?key=<key>   or header   X-API-Key: <key>"
    echo "Peer key (relay ↔ relay, vpush → relay):   $MESH_PEER_KEY"
    echo
    echo "== This server =="
    if has relay; then
        echo "Relay peers:         ${PEERS:-none}"
        echo "   router: /opt/strfry/etc/router.conf   sync: systemctl list-timers strfry-sync.timer"
    fi
    if has media; then
        echo "Media files:         $media_store"
        echo "Media peers:         ${MEDIA_PEERS:-none}"
        echo "Media index:         this server's own (sqld, /opt/libsql/data)"
        echo "Blossom S3 keys:     /opt/blossom/etc/blossom.env"
        echo "Blossom config:      /opt/blossom/etc/config.yml"
    fi
    if has vpush; then
        echo "VPush config:        /opt/vpush/etc/vpush.toml (watches every relay of the network)"
        echo "VPush secrets:       /opt/vpush/etc/secrets/ (peer key, FCM)"
    fi
    if has call; then
        echo "Call node:           $CALL_REF"
        echo "   settings: /opt/vcall/etc/vcall.env   key and TURN secret: /opt/vcall/data/ (the key is the node's id: keep it)"
        echo "   stats: vcall ctl --socket /run/vcall/ctl.sock stats"
    fi
    # What the components of a larger kit say about themselves.
    [ -n "$CARD_EXTRA" ] && printf '%s' "$CARD_EXTRA"
    echo "Configuration:       $STATE/server.conf"
    echo
    echo "== Versions =="
    has relay && echo "strfry   $STRFRY_TAG ($STRFRY_COMMIT)"
    has media && echo "blossom  $BLOSSOM_COMMIT on deno $DENO_VERSION"
    has media && echo "libsql   $LIBSQL_VERSION"
    has vpush && echo "vpush    ${vpush_release:-?}"
    has call && echo "vcall    ${vcall_release:-?}"
    echo
    echo "== Services =="
    for s in strfry strfry-router strfry-sync.timer libsql blossom vpush vcall nginx; do
        case $s in
            strfry) has relay || continue ;;
            strfry-router|strfry-sync.timer) has relay && [ -n "$PEERS" ] || continue ;;
            libsql|blossom) has media || continue ;;
            vpush) has vpush || continue ;;
            vcall) has call || continue ;;
        esac
        echo "$s: systemctl status $s   journalctl -u ${s%.timer} -f"
    done
} | put "$STATE/server.txt" 0600 root:root
# An older install wrote the card as manifest-node.txt.
[ -f "$(target "$STATE/manifest-node.txt")" ] && run rm -f "$STATE/manifest-node.txt"

echo
card
# What a component wants seen at once, not only kept in the file.
[ -n "$CARD_SHOW" ] && printf '\n%s' "$CARD_SHOW"
true
