#!/usr/bin/env bash
# Deletes from this relay what it need not keep: gift wraps (kind 1059, the
# messages) and events of groups (kind 9) older than ${V_RETENTION_DAYS} days.
# Run by strfry-retention.timer as the strfry user. Other kinds (profiles,
# relay lists, presence, notes) are replaceable and stay. LMDB does not give
# the file back, but the freed pages are used again: the database stops
# growing instead of growing without end.
set -eu
exec /opt/strfry/bin/strfry --config=/opt/strfry/etc/strfry.conf \
    delete --age=${V_RETENTION_SECONDS} --filter='{"kinds":[1059,9]}'
