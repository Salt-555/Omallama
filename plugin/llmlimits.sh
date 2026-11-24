#!/usr/bin/env bash
# Per-client lane limits for the LLM door (:6969), behind the salt.llama-server
# widget's config panel ("Client lane limits" section).
#
# State:   ~/.config/llama-server/llm-limits.json   {"default": <0-8>, "clients": {"<ip>": <0-8>}, "names": {...}}
#            0 = unlimited (explicit 0 survives a nonzero default; a client
#            with NO entry uses `default`). This file is the single source of
#            truth: the queueing gateway (llm-queue.py, :6962) re-reads it on
#            every request, so a save takes effect with no reload of anything.
#
# Commands:
#   llmlimits.sh list            -> JSON: door state + rows (configured and
#                                   seen clients, hit counts, live/direct
#                                   activity, auto-filled names)
#   llmlimits.sh apply '<json>'  -> validate + save state (atomic, with
#                                   timestamped backup)
#
# Loopback (127.0.0.1 / ::1) is always unlimited and never listed.
set -euo pipefail

CFG_DIR="${LLAMA_CFG_DIR:-$HOME/.config/llama-server}"
STATE="$CFG_DIR/llm-limits.json"
ACCESS_LOG="$HOME/.local/state/cardmode/logs/llm-access.log"
DOOR_CONF="$HOME/.config/cardmode/llm-door-6969.conf"

ensure_state() {
  mkdir -p "$CFG_DIR"
  [[ -f "$STATE" ]] || echo '{"default": 0, "clients": {}, "names": {}}' > "$STATE"
}

seen_ips() {
  # Recently seen client IPs from the door access log (combined format, $1 is
  # the remote address), with per-IP hit counts. Loopback is excluded.
  [[ -f "$ACCESS_LOG" ]] || return 0
  tail -n 20000 "$ACCESS_LOG" \
    | awk '$1 !~ /^(127\.0\.0\.1|::1)$/ { n[$1]++; last[$1]=$4 } END { for (ip in n) print ip, n[ip], last[ip] }' \
    | sort -k2,2 -rn
}

resolve_names() {
  # Auto-fill display names for unnamed clients, three sources in order:
  # 1. `tailscale status` — authoritative for tailnet peers (covers remote
  #    clients in one call)
  # 2. mDNS via avahi-resolve — how LAN devices advertise themselves
  #    (DoomSlayer.local, Katherines-iMac.local)
  # 3. reverse DNS via getent hosts — MagicDNS already answered here for
  #    tailscale IPs, and some routers publish DHCP PTRs
  # Prints "ip name" lines; suffixes (.local, *.ts.net) are stripped. Used as
  # a SUGGESTION: an operator-set name always wins, and Save persists
  # whatever the row shows.
  local ts ip n
  ts=$(tailscale status 2>/dev/null | awk 'NF >= 2 && $1 ~ /^[0-9a-fA-F.:]+$/ {print $1, $2}')
  for ip in "$@"; do
    n=$(awk -v ip="$ip" '$1 == ip {print $2; exit}' <<<"$ts")
    if [[ -z "$n" ]]; then
      n=$(timeout 2 avahi-resolve -a "$ip" 2>/dev/null | awk 'NR == 1 {print $2}')
    fi
    if [[ -z "$n" ]]; then
      n=$(getent hosts "$ip" 2>/dev/null | awk 'NR == 1 {print $2}')
    fi
    [[ -n "$n" ]] && printf '%s %s\n' "$ip" "$(sed 's/\..*$//' <<<"$n")"
  done
}

door_conns() {
  # LIVE connections on the doors, counted per client IP. Containerized
  # backends DNAT external traffic, so the HOST netns sees nothing for :6969
  # while a container is published wide (verified: active requests, zero host
  # rows) — the connections live in the serving container's netns, readable
  # via /proc/net/tcp with no tools in the image. After llm-door.sh enable,
  # the HOST file instead carries the door's own client sockets (real IPs) —
  # but docker-proxy's wide-publish sockets look identical in /proc, so the
  # door state decides the label: host :6969 peers count as "live" only when
  # the door include carries a listen line, as "direct" before that.
  # Output: "ip kind count" with kind direct (:6969 past the door) or live
  # (through a door). 6969 = 0x1B39, 8191 = 0x1FFF.
  local host6969=direct
  grep -qE '^[[:space:]]*listen ' "$HOME/.config/cardmode/llm-door-6969.conf" 2>/dev/null && host6969=live
  {
    local c
    for c in $(docker ps --filter publish=6969 --format '{{.Names}}' 2>/dev/null); do
      docker exec "$c" cat /proc/net/tcp 2>/dev/null | sed 's/^/C /' || true
    done
    cat /proc/net/tcp 2>/dev/null | sed 's/^/H /'
  } | awk -v h6="$host6969" '
    function hexip(h, a,b,c,d) {
      a = substr(h,7,2); b = substr(h,5,2); c = substr(h,3,2); d = substr(h,1,2)
      return strtonum("0x" a) "." strtonum("0x" b) "." strtonum("0x" c) "." strtonum("0x" d)
    }
    $5 != "01" { next }
    { split($3, l, ":"); split($4, r, ":")
      port = strtonum("0x" l[2])
      if (port != 6969 && port != 8191) next
      ip = hexip(r[1])
      if (ip ~ /^127\./) next
      if (ip ~ /^172\.(1[6-9]|2[0-9]|3[01])\./) next
      if ($1 == "C") { if (port == 6969) direct[ip]++ }
      else if (port == 6969) { if (h6 == "live") live[ip]++; else direct[ip]++ }
      else live[ip]++ }
    END { for (i in direct) print i, "direct", direct[i]
          for (i in live)   print i, "live",   live[i] }'
}

case "${1:-}" in
  list)
    ensure_state
    hits=$(seen_ips)
    doors=$(door_conns)
    direct=$(echo "$doors" | awk '$2 == "direct" { print $1, $3 }')
    live=$(echo "$doors" | awk '$2 == "live" { print $1, $3 }')
    door=off
    grep -qE '^[[:space:]]*listen ' "$HOME/.config/cardmode/llm-door-6969.conf" 2>/dev/null && door=on
    # rows = configured ∪ seen ∪ live-direct ∪ live-through-door, merged by
    # IP (later sources only add their own fields; zeros filled after).
    DOC=$(jq -n --slurpfile state "$STATE" --arg hits "$hits" --arg direct "$direct" --arg live "$live" --arg door "$door" '
      ($state[0]) as $state
      | ($hits | split("\n") | map(select(length > 0)) | map(split(" ")) | map({ip: .[0], hits: (.[1] | tonumber), last: .[2]})) as $seen
      | ($direct | split("\n") | map(select(length > 0)) | map(split(" ")) | map({ip: .[0], direct: (.[1] | tonumber)})) as $dir
      | ($live | split("\n") | map(select(length > 0)) | map(split(" ")) | map({ip: .[0], live: (.[1] | tonumber)})) as $liv
      | ([ $state.clients | to_entries[] | {ip: .key} ]
         + $seen + $dir + $liv)
      | group_by(.ip) | map(reduce .[] as $x ({}; . * $x))
      | map(. + {hits: (.hits // 0), last: (.last // ""), direct: (.direct // 0), live: (.live // 0),
                 limit: ($state.clients[.ip] // 0),
                 name: ((($state.names // {})[.ip] // "") | tostring)})
      | sort_by(-(.hits), -(.direct), -(.live), .ip)
      | { default: ($state.default // 0), door: $door, rows: . }')
    # Auto-fill names the operator has not set: resolved hostname as a
    # suggestion, operator-set names always win.
    unnamed=$(jq -r '.rows[] | select(.name == "") | .ip' <<<"$DOC")
    if [[ -n "$unnamed" ]]; then
      auto=$(resolve_names $unnamed | jq -Rn 'reduce inputs as $l ({}; ($l | split(" ")) as $f | if ($f | length) == 2 then . + {($f[0]): $f[1]} else . end)')
      DOC=$(jq --argjson auto "$auto" '.rows |= map(if .name == "" then .name = ($auto[.ip] // "") else . end)' <<<"$DOC")
    fi
    echo "$DOC"
    ;;
  apply)
    ensure_state
    blob="${2:-}"
    [[ -n "$blob" ]] || { echo "usage: llmlimits.sh apply '<json>'" >&2; exit 1; }
    echo "$blob" | jq empty >/dev/null 2>&1 || { echo "invalid json" >&2; exit 1; }
    # Validate before anything touches disk: default and every client value are
    # integers 0..8; every key is an IP; loopback is never configurable.
    bad=$(echo "$blob" | jq -r '
      (if ((.default // 0) | type) == "number" and (.default // 0) == ((.default // 0) | floor) and (.default // 0) >= 0 and (.default // 0) <= 8 then "" else "default must be an integer 0..8" end) as $d
      | [.clients // {} | to_entries[] |
         if (.key == "127.0.0.1" or .key == "::1") then "loopback is always unlimited"
         elif (.value | type) != "number" or .value != (.value | floor) or .value < 0 or .value > 8 then "\(.key): limit must be an integer 0..8"
         else "" end]
         + [.names // {} | to_entries[] |
            if (.value | type) != "string" or (.value | test("^[A-Za-z0-9 _-]{1,24}$") | not) then "\(.key): name must be 1-24 chars of letters, digits, space, _ or -"
            else "" end]
      | map(select(length > 0))
      | if $d != "" then [$d] + . else . end
      | .[0] // empty')
    if [[ -n "$bad" ]]; then echo "$bad" >&2; exit 1; fi

    bak="$STATE.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$STATE" "$bak"
    tmp="$STATE.tmp.$$"
    jq '{default: (.default // 0), clients: (.clients // {}), names: ((.names // {}) | with_entries(.value |= (tostring | gsub("^ +| +$"; "")))) | with_entries(select(.value != ""))}' <(echo "$blob") > "$tmp"
    mv "$tmp" "$STATE"
    # That's the whole apply: the queueing gateway (llm-queue.py) re-reads
    # this file on every request, so new lanes take effect on the next
    # request with no reload of anything. Explicit 0 = unlimited.
    echo "saved"
    ;;
  *)
    echo "usage: llmlimits.sh {list|apply '<json>'}" >&2
    exit 1
    ;;
esac
