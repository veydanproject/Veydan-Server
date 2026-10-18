# shellcheck shell=bash disable=SC2034  # V_* are read by the templates
# vguard, the read policy of the relay (VGuard of Veydan-Push,
# crates/vguard): nginx hands every WebSocket of the relay to it on
# 127.0.0.1:7778, and it passes the frames on to strfry on 127.0.0.1:7777,
# but answers itself a question for gift wraps (kind 1059) of a key the
# connection did not sign in with (NIP-42), for events of groups (kind 9)
# without #h, or with no filter at all. The other relays of the mesh and
# VPush come with the key of the peers, and nginx names them as peers
# (X-Veydan-Role): they read everything, as before. Everything in
# /opt/vguard:
#   bin/vguard  etc/vguard.toml  etc/vguard.service
# Part of the relay; sourced by run.sh after strfry.sh. Sets V_RELAY_WS,
# where nginx sends the WebSockets of the relay.

G=/opt/vguard
V_RELAY_WS=127.0.0.1:7777

# The binary: from the kit when it is there; else what is installed stays
# (a build of one's own, or the release named); else the release of
# VGUARD_VERSION (versions.conf): vguard-linux-<arch> of Veydan-Push,
# signed as the component vguard. With none of them the relay is refused.
if [ -f "$HERE/bin/vguard" ]; then
    ( cd "$HERE/bin" && sha256sum -c --quiet vguard.sha256 ) \
        || die "bin/vguard does not match bin/vguard.sha256: a damaged kit"
    mkdirp "$G" 0755 root:root
    mkdirp "$G/bin" 0755 root:root
    # install, not cp: cp over a running binary fails with "text file busy".
    run install -m 0755 "$HERE/bin/vguard" "$G/bin/vguard"
    say "vguard: $(cat "$HERE/bin/vguard.RELEASE" 2>/dev/null || echo '?') from the kit"
elif needs_release "$G/bin/vguard" "${VGUARD_VERSION:-}"; then
    [ -n "${VGUARD_VERSION:-}" ] || die "$NO_VGUARD"
    mkdirp "$G" 0755 root:root
    mkdirp "$G/bin" 0755 root:root
    fetch_program vguard Veydan-Push "$VGUARD_VERSION" "$G/bin/vguard"
fi

say "vguard: the read policy in front of strfry"
ensure_user vguard "$G"
mkdirp "$G/etc" 0750 root:vguard
# The state of the guard: the keys denied on every server of the network
# (data/denied-keys.txt, spec/vguard.md "Denied keys") and the groups
# closed on our relays (data/denied-groups.txt, "Denied groups"), laid by
# the agent of vcloud through its helper (root, the group of this folder)
# and read by vguard by its group. No file, nobody denied.
mkdirp "$G/data" 0750 root:vguard
V_GUARD_DENIED="denied_keys_file = \"$G/data/denied-keys.txt\""
V_GUARD_DENIED_GROUPS="denied_groups_file = \"$G/data/denied-groups.txt\""
# Only a vguard that knows the key gets the line: an older release named by
# VGUARD_VERSION refuses an unknown key, and keeps working without it.
if [ "$DRY" != 1 ]; then
    probe=$(mktemp)
    printf 'relay_hosts = ["probe.invalid"]\n%s\n' "$V_GUARD_DENIED" > "$probe"
    if ! "$G/bin/vguard" check-config --config "$probe" >/dev/null 2>&1; then
        warn "vguard: this release does not read denied keys yet; the relay denies nobody until it is updated"
        V_GUARD_DENIED="# denied_keys_file: not known to this vguard yet"
    fi
    # The same for the groups, which came a release after the keys.
    printf 'relay_hosts = ["probe.invalid"]\n%s\n' "$V_GUARD_DENIED_GROUPS" > "$probe"
    if ! "$G/bin/vguard" check-config --config "$probe" >/dev/null 2>&1; then
        warn "vguard: this release does not read closed groups yet; the relay closes no group until it is updated"
        V_GUARD_DENIED_GROUPS="# denied_groups_file: not known to this vguard yet"
    fi
    rm -f "$probe"
fi
V_RELAY_FQDN=$RELAY_FQDN
# shellcheck disable=SC2086  # one name per word
V_GUARD_HOSTS=$(printf '"%s", ' $RELAY_FQDN $RELAY_ALIAS_FQDNS | sed 's/, $//')
render_block "$HERE/templates/vguard.toml" "$G/etc/vguard.toml" 0640 root:vguard
render "$HERE/templates/systemd/vguard.service" "$G/etc/vguard.service" 0644 root:root

if [ "$DRY" != 1 ]; then
    runuser -u vguard -- "$G/bin/vguard" check-config --config "$G/etc/vguard.toml" >/dev/null \
        || die "vguard: $G/etc/vguard.toml is refused (see above)"
fi
link_unit "$G/etc/vguard.service"
run systemctl restart vguard

# Health: a public question through vguard to strfry. Until it answers,
# nginx keeps sending the relay where it did.
if [ "$DRY" != 1 ]; then
    ok=""
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if "$G/bin/vguard" probe --config "$G/etc/vguard.toml" --wait 3 >/dev/null 2>&1; then ok=1; break; fi
        sleep 1
    done
    [ -n "$ok" ] || die "vguard does not answer on 127.0.0.1:7778 (journalctl -u vguard -u strfry); nginx is left as it was"
fi
V_RELAY_WS=127.0.0.1:7778
