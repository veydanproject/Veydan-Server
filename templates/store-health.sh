#!/usr/bin/env bash
# The health of the node of Cassandra of this server, for the agent of
# vcloud (services/relay/spec/stats.md 13; vagent reads it, relay_stats.rs).
# Run as root once a minute by veydan-store-health.timer (components/vrelay.sh):
# nodetool inside the container (JMX on its loopback, no password, no role of
# CQL), the answer in /run/veydan/store-health.json, 0644, through a rename.
#
#   {"v": 1, "at": <unix>, "cassandra": {"status": "up"|"down", "state": "normal"|...,
#    "datacenter": "eu", "cluster": "veydan", "load_bytes": N, "pending_compactions": N,
#    "pending_hints": N, "nodes": {"up": N, "down": N, "joining": N, "leaving": N}}}
#
# Cassandra down, or nodetool unanswered: "status": "down" and what is known.
set -uo pipefail

OUT=${STORE_HEALTH_FILE:-/run/veydan/store-health.json}
CLUSTER="${V_CASSANDRA_CLUSTER}"
# STORE_HEALTH_NODETOOL: a program in nodetool's place (the tests).
nt() {
    if [ -n "${STORE_HEALTH_NODETOOL:-}" ]; then "$STORE_HEALTH_NODETOOL" "$@"; return; fi
    local c
    c=$(docker ps -q --filter label=com.docker.compose.project=vrelay --filter label=com.docker.compose.service=cassandra 2>/dev/null | head -n1)
    [ -n "$c" ] || return 1
    timeout 50 docker exec "$c" nodetool "$@"
}

# "114.67 KiB" → bytes.
to_bytes() {
    awk -v n="$1" -v u="$2" 'BEGIN {
        m = 1
        if (u == "KiB" || u == "KB") m = 1024
        else if (u == "MiB" || u == "MB") m = 1024 ^ 2
        else if (u == "GiB" || u == "GB") m = 1024 ^ 3
        else if (u == "TiB" || u == "TB") m = 1024 ^ 4
        else if (u != "bytes" && u != "B") exit 1
        printf "%.0f", n * m
    }'
}

status=down state="" dc="" load="" pending="" hints="" nodes=null
if info=$(nt info 2>/dev/null); then
    field() { awk -F' *: *' -v k="$1" '$1 == k {print $2; exit}' <<< "$info"; }
    [ "$(field 'Gossip active')" = true ] && [ "$(field 'Native Transport active')" = true ] && status=up
    dc=$(field 'Data Center')
    host=$(field 'ID')
    read -r n u <<< "$(field 'Load')"
    load=$(to_bytes "${n:-}" "${u:-}" 2>/dev/null) || load=""
    if st=$(nt status 2>/dev/null); then
        nodes=$(printf '{"up": %d, "down": %d, "joining": %d, "leaving": %d}' \
            "$(grep -c '^UN ' <<< "$st")" "$(grep -cE '^D[NLJM] ' <<< "$st")" "$(grep -c '^UJ ' <<< "$st")" "$(grep -c '^UL ' <<< "$st")")
        mine=$(grep -F -- "$host" <<< "$st" | awk 'NR == 1 {print $1}')
        case "${mine:1:1}" in N) state=normal ;; J) state=joining ;; L) state=leaving ;; M) state=moving ;; esac
    fi
    pending=$(nt compactionstats 2>/dev/null | awk '/^pending tasks/ {print $NF; exit}')
    [[ "$pending" =~ ^[0-9]+$ ]] || pending=""
    if lh=$(nt listpendinghints 2>/dev/null); then
        if grep -q 'does not have any pending hints' <<< "$lh"; then
            hints=0
        else
            # The column "Total hints" of the header, by its place among the
            # columns (two spaces or more between them).
            hints=$(awk -F'  +' '
                NR == 1 { for (i = 1; i <= NF; i++) if ($i ~ /^Total hints/) c = i; next }
                c && $c ~ /^[0-9]+$/ { s += $c; seen = 1 }
                END { if (c && (seen || NR == 1)) print s + 0 }' <<< "$lh")
        fi
    fi
fi

json=$(jq -cn --arg status "$status" --arg state "$state" --arg dc "$dc" --arg cluster "$CLUSTER" \
    --arg load "$load" --arg pending "$pending" --arg hints "$hints" \
    --argjson nodes "$nodes" '
    def num: if . == "" then null else tonumber end;
    {v: 1, at: now | floor,
     cassandra: ({status: $status, state: (if $state == "" then null else $state end),
                  datacenter: (if $dc == "" then null else $dc end), cluster: $cluster,
                  load_bytes: ($load | num), pending_compactions: ($pending | num), pending_hints: ($hints | num),
                  nodes: $nodes}
                 | with_entries(select(.value != null)))}') || exit 1
install -d -m 0755 "$(dirname "$OUT")"
tmp=$(mktemp "$(dirname "$OUT")/.store-health.XXXXXX") || exit 1
printf '%s\n' "$json" > "$tmp"
chmod 0644 "$tmp"
mv -f "$tmp" "$OUT"
