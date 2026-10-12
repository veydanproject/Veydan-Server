#!/usr/bin/env bash
# Negentropy sync with every peer in /opt/strfry/etc/peers, both ways. The
# router carries live events; this closes the gaps left by a lost
# connection. Run by strfry-sync.timer as the strfry user. A peer that does
# not answer is skipped, the others are still synced.
set -u
rc=0
while read -r url; do
    [ -n "$url" ] || continue
    if ! timeout 600 /opt/strfry/bin/strfry --config=/opt/strfry/etc/strfry.conf \
            sync "$url" --dir=both > /dev/null 2> /tmp/sync.err; then
        # The key is in the URL: log the host only.
        h=${url#*://}; h=${h%%/*}
        echo "sync with $h failed: $(tail -n 1 /tmp/sync.err)" >&2
        rc=1
    fi
done < /opt/strfry/etc/peers
exit $rc
