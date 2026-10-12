# shellcheck shell=bash disable=SC2034  # V_* are read by the templates
# VPush, the push server (bin/vpush of the kit). Everything in /opt/vpush:
#   bin/vpush  etc/vpush.toml  etc/secrets/  etc/vpush.service  data/
# Listens on 127.0.0.1:8090; only nginx is in front of it. A device
# registers with one VPush of the network (the app takes the first of its
# region); every VPush may watch every relay of the network, with the peer
# key.
# Sourced by run.sh.

P=/opt/vpush
say "vpush"

ensure_user vpush "$P"
mkdirp "$P" 0755 root:root
mkdirp "$P/bin" 0755 root:root
mkdirp "$P/etc" 0750 root:vpush
mkdirp "$P/etc/secrets" 0700 vpush:vpush
mkdirp "$P/data" 0750 vpush:vpush
mkdirp "$P/data/backups" 0750 vpush:vpush

# The binary: from the kit when it is there; else the installed one stays;
# else the release of VPUSH_VERSION (versions.conf).
if [ -f "$HERE/bin/vpush" ]; then
    ( cd "$HERE/bin" && sha256sum -c --quiet vpush.sha256 ) \
        || die "bin/vpush does not match bin/vpush.sha256: a damaged kit"
    run install -m 0755 "$HERE/bin/vpush" "$P/bin/vpush"
    say "vpush: $(cat "$HERE/bin/RELEASE" 2>/dev/null || echo '?')"
elif [ ! -x "$(target "$P/bin/vpush")" ]; then
    fetch_program vpush Veydan-Push "${VPUSH_VERSION:-}" "$P/bin/vpush"
fi

# Every relay of the network, all behind the one peer key. The key is in a
# file, never in vpush.toml.
printf '%s\n' "$MESH_PEER_KEY" | put "$P/etc/secrets/mesh-peer.key" 0600 vpush:vpush
relay_allow=""
for r in $MESH_RELAY_FQDNS; do
    relay_allow+=$'\n[[relays.allow]]\n'"url = \"wss://$r\""$'\n'"api_key_file = \"$P/etc/secrets/mesh-peer.key\""$'\n'
done

# The apps served and their Firebase keys: fcm-<app id>.json beside the
# installer or in secrets/ of the kit; with FCM_APPS naming one app, any
# service account JSON beside the installer is its key. A key already on
# the server stays when the kit brings none.
apps=""
fcm_dirs="$FROM $HERE/secrets"
app_key() { # app_key <app id> → the path of its key in the kit, or nothing
    local d
    for d in $fcm_dirs; do [ -f "$d/fcm-$1.json" ] && { printf '%s' "$d/fcm-$1.json"; return 0; }; done
    return 1
}
if [ -z "$FCM_APPS" ]; then
    for d in $fcm_dirs; do
        for f in "$d"/fcm-*.json; do
            [ -f "$f" ] || continue
            app=$(basename "$f" .json); app=${app#fcm-}
            [[ " $FCM_APPS " == *" $app "* ]] || FCM_APPS="${FCM_APPS:+$FCM_APPS }$app"
        done
    done
fi
for app in $FCM_APPS; do
    key=$(app_key "$app") || key=""
    if [ -z "$key" ] && [ "$(printf '%s\n' $FCM_APPS | wc -l)" = 1 ]; then
        for f in "$FROM"/*.json; do
            [ -f "$f" ] && grep -q '"type": *"service_account"' "$f" && { key=$f; break; }
        done
    fi
    if [ -n "$key" ]; then
        put "$P/etc/secrets/fcm-$app.json" 0600 vpush:vpush < "$key"
    elif [ ! -f "$(target "$P/etc/secrets/fcm-$app.json")" ]; then
        warn "vpush: no key for $app: put fcm-$app.json beside the installer and run again"
        continue
    fi
    apps+=$'\n'"[apps.\"$app\".fcm]"$'\n'"service_account = \"$P/etc/secrets/fcm-$app.json\""$'\n'
done
if [ -z "$apps" ]; then
    apps=$'\n'"# No app yet: FCM_APPS in server.conf and fcm-<app id>.json beside the installer."$'\n'
    warn "vpush serves no app: set FCM_APPS in server.conf and put the Firebase key beside the installer"
fi

V_VPUSH_FQDN=$VPUSH_FQDN
V_RELAYS_ALLOW=$relay_allow
V_APPS=$apps
# The kit's part of vpush.toml (apps, relays) is written on every run; the
# rest of the file is the admin's.
render_block "$HERE/templates/vpush.toml" "$P/etc/vpush.toml" 0640 root:vpush "# VPush of " "public_url = "
render "$HERE/templates/systemd/vpush.service" "$P/etc/vpush.service" 0644 root:root

if [ "$DRY" != 1 ]; then
    runuser -u vpush -- "$P/bin/vpush" check-config --config "$P/etc/vpush.toml" \
        || die "vpush: $P/etc/vpush.toml is refused (see above)"
fi
link_unit "$P/etc/vpush.service"
run systemctl restart vpush
