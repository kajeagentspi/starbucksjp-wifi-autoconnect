#!/bin/bash
# wifi-watch.sh
# Detect Wi2 (Starbucks JP) captive-portal session expiry and re-authenticate
# IN PLACE (no Wi-Fi disconnect). Falls back to a Wi-Fi power toggle only if the
# in-place re-login can't be verified.
#
# Two triggers feed one handler:
#   A) ping heartbeat to a public host (default 8.8.8.8) ~1s apart, 3-strike rule
#   B) captive HTTP probe every ~10s (safety net for redirect-only expiry)
# Activates ONLY when the captive redirect points at the Wi2 portal (network gate).
#
# bash 3.2-compatible (macOS /bin/bash). Absolute tool paths for LaunchAgent.
# Personal data (mac/ip/token/key) is redacted from logged URLs; the Wi-Fi gateway
# is auto-detected from the routing table (no hardcoded network address).

set -u
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.local/bin"

# ---------------- config (override via env) ----------------
WIFI_IFACE="${WIFI_IFACE:-en0}"
PING_HOST="${PING_HOST:-8.8.8.8}"          # public host to ping (Google DNS)
PING_INTERVAL="${PING_INTERVAL:-1}"        # seconds between heartbeats
PING_FAIL="${PING_FAIL:-3}"                # consecutive misses -> expiry
PROBE_INTERVAL="${PROBE_INTERVAL:-10}"     # captive-probe cadence (safety net)
CAPTIVE_URL="${CAPTIVE_URL:-http://captive.apple.com/hotspot-detect.html}"
GATE_HOSTS="${GATE_HOSTS:-wi2.ne.jp}"      # space-separated portal signatures to gate on
GATEWAY="${GATEWAY:-}"                     # optional override; auto-detected from $WIFI_IFACE default route if empty
RELOGIN_RETRY="${RELOGIN_RETRY:-3}"
COOLDOWN="${COOLDOWN:-15}"                 # seconds after an action before re-arming
WI2_WINDOW="${WI2_WINDOW:-300}"            # seconds a Wi2 sighting authorizes the toggle fallback

# ---------------- paths ----------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELOGIN_SCRIPT="$SCRIPT_DIR/relogin_wi2.py"
UV="${UV:-$HOME/.local/bin/uv}"
LOG_DIR="$HOME/Library/Logs"
LOG_FILE="$LOG_DIR/starbucks-wifi-watch.log"
CAPTURE_LOG="$LOG_DIR/starbucks-wifi-watch-capture.log"

# ---------------- tools (LaunchAgent has minimal PATH) ----------------
CURL=/usr/bin/curl
PING=/sbin/ping
ROUTE=/sbin/route
AWK=/usr/bin/awk
SED=/usr/bin/sed
SUDO=/usr/bin/sudo
NETWORKSETUP=/usr/sbin/networksetup
SLEEP=/bin/sleep
DATE=/bin/date
GREP=/usr/bin/grep
RM=/bin/rm
MKTEMP=/usr/bin/mktemp

mkdir -p "$LOG_DIR"

log()  { echo "$($DATE '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"; }

# Strip personal query params (mac/ip/token/key) from a URL before logging it.
redact_url() {
  printf '%s\n' "$1" | $SED -E 's/([?&])(mac|ip|token|key)=[^&#]*/\1\2=REDACTED/g'
}

ping_up()     { $PING -c 1 -W 1000 "$1" >/dev/null 2>&1; }

# Wi-Fi gateway, auto-detected from the routing table (or GATEWAY override).
current_gateway() {
  if [ -n "$GATEWAY" ]; then echo "$GATEWAY"; return; fi
  $ROUTE -n get -ifscope "$WIFI_IFACE" default 2>/dev/null | $AWK '/gateway:/ {print $2; exit}'
}
gateway_up() {
  local gw; gw="$(current_gateway)"; [ -n "$gw" ] && ping_up "$gw"
}

# Cheap online check for verification (no capture-log writes).
check_online() {
  local body
  body="$($CURL -sS -m 3 "$CAPTIVE_URL" 2>/dev/null)"
  if echo "$body" | $GREP -qi 'Success'; then return 0; fi
  ping_up "$PING_HOST" && return 0
  return 1
}

# Capturing probe: sets PROBE_RESULT (ONLINE|REDIR|OFFLINE), PROBE_LOC, PROBE_CODE.
probe_captive() {
  local hdr body code loc
  hdr="$($MKTEMP -t wifiwatch)"; body="$($MKTEMP -t wifiwatch)"
  code="$($CURL -sS -m 3 -o "$body" -D "$hdr" -w '%{http_code}' "$CAPTIVE_URL" 2>/dev/null)"
  PROBE_CODE="$code"
  if $GREP -qi 'Success' "$body" 2>/dev/null; then
    PROBE_RESULT="ONLINE"; PROBE_LOC=""
  else
    loc="$($GREP -i '^Location:' "$hdr" 2>/dev/null | tail -1 | sed 's/^[Ll]ocation:[[:space:]]*//' | tr -d '\r')"
    PROBE_LOC="$loc"
    if [ -n "$loc" ]; then PROBE_RESULT="REDIR"; else PROBE_RESULT="OFFLINE"; fi
    {
      echo "----- probe ($($DATE '+%H:%M:%S')) -----"
      echo "http_code: $code"
      echo "location: $(redact_url "$loc")"
      echo "body (first 500):"
      head -c 500 "$body" 2>/dev/null
      echo ""
    } >> "$CAPTURE_LOG"
  fi
  $RM -f "$hdr" "$body"
}

# True if we've seen the Wi2 portal recently (authorizes the toggle fallback off
# a pure-OFFLINE state, so we never toggle Wi-Fi on a non-Wi2 network).
recently_on_wi2() {
  [ "${LAST_WI2_SEEN:-0}" -gt 0 ] && [ $(( $($DATE +%s) - ${LAST_WI2_SEEN:-0} )) -lt "$WI2_WINDOW" ]
}

# True if the redirect URL matches one of our portal signatures (network gate).
is_target() {
  local loc="$1" g
  [ -z "$loc" ] && return 1
  for g in $GATE_HOSTS; do
    case "$loc" in *"$g"*) return 0;; esac
  done
  return 1
}

do_relogin() {
  local portal_url="$1" i rc tmp
  log "relogin: starting (up to $RELOGIN_RETRY attempts) for $(redact_url "$portal_url")"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ "$i" -gt "$RELOGIN_RETRY" ] && break
    tmp="$($MKTEMP -t relogin)"
    if [ -x "$UV" ] && [ -f "$RELOGIN_SCRIPT" ]; then
      "$UV" run --no-project "$RELOGIN_SCRIPT" "$portal_url" >"$tmp" 2>&1
      rc=$?
    else
      echo "[watchdog] uv ($UV) or relogin script missing" >"$tmp"
      rc=99
    fi
    log "relogin: attempt $i/$RELOGIN_RETRY rc=$rc"
    # full detail -> capture log
    {
      echo "===== $($DATE '+%Y-%m-%d %H:%M:%S') relogin attempt $i (rc=$rc) ====="
      cat "$tmp"
    } >> "$CAPTURE_LOG"
    # concise, timestamped lines -> main log
    while IFS= read -r line; do log "    $line"; done < "$tmp"
    $RM -f "$tmp"
    if check_online; then
      log "relogin: ONLINE confirmed after attempt $i"
      return 0
    fi
    $SLEEP 1
  done
  log "relogin: all $RELOGIN_RETRY attempts exhausted, still offline"
  return 1
}

fallback_toggle() {
  log "FALLBACK: toggling $WIFI_IFACE off/on"
  $SUDO "$NETWORKSETUP" -setairportpower "$WIFI_IFACE" off >/dev/null 2>&1
  $SLEEP 2
  $SUDO "$NETWORKSETUP" -setairportpower "$WIFI_IFACE" on  >/dev/null 2>&1
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    $SLEEP 1
    if check_online; then log "recovered after toggle (${i}s)"; return 0; fi
  done
  log "FALLBACK: toggle did not restore connectivity"
  return 1
}

LAST_ACTION=0
LAST_WI2_SEEN=0
NON_WI2_LOGGED=0

handle_expiry() {
  local reason="$1" hint_result="${2:-}" hint_loc="${3:-}" now
  now=$($DATE +%s)
  if [ $((now - LAST_ACTION)) -lt "$COOLDOWN" ]; then return; fi
  LAST_ACTION=$now
  log "EXPIRY detected (via $reason)"
  # Use the probe state the caller already has (captive trigger); only the ping
  # trigger (no hint) probes here. Re-probing on a flapping link races and can
  # turn a real REDIR into OFFLINE, skipping the relogin.
  if [ -n "$hint_result" ]; then
    PROBE_RESULT="$hint_result"; PROBE_LOC="$hint_loc"
  else
    probe_captive
  fi
  case "$PROBE_RESULT" in
    ONLINE)
      log "false alarm: online on re-check"
      NON_WI2_LOGGED=0
      ;;
    REDIR)
      if is_target "$PROBE_LOC"; then
        LAST_WI2_SEEN=$now
        log "target portal matched -> in-place relogin"
        if do_relogin "$PROBE_LOC"; then
          log "RELOGIN OK (no Wi-Fi disconnect)"
        else
          log "relogin exhausted -> fallback toggle"
          fallback_toggle
        fi
      else
        # A captive portal that isn't ours -> stay quiet in the main log (capture log only).
        if [ "$NON_WI2_LOGGED" -eq 0 ]; then
          echo "$($DATE '+%Y-%m-%d %H:%M:%S') non-target portal ($(redact_url "$PROBE_LOC")) -> ignoring (not our network)" >> "$CAPTURE_LOG"
          NON_WI2_LOGGED=1
        fi
      fi
      ;;
    OFFLINE)
      if gateway_up && recently_on_wi2; then
        log "offline but still associated (Wi2) -> fallback toggle"
        fallback_toggle
      elif gateway_up; then
        # associated to a non-Wi2 network with no captive portal -> not ours, do nothing
        :
      else
        log "association lost -> backing off (will keep probing)"
      fi
      ;;
  esac
}

log "=== wifi-watch starting (pid $$): ping=$PING_HOST interval=${PING_INTERVAL}s probe=${PROBE_INTERVAL}s gate=[$GATE_HOSTS] ==="

PING_FAIL_COUNT=0
LAST_PROBE=0
while true; do
  now=$($DATE +%s)

  # Trigger A: ping heartbeat (fast)
  if ping_up "$PING_HOST"; then
    PING_FAIL_COUNT=0
  else
    PING_FAIL_COUNT=$((PING_FAIL_COUNT + 1))
    if [ "$PING_FAIL_COUNT" -ge "$PING_FAIL" ]; then
      handle_expiry "ping:$PING_FAIL_COUNT misses to $PING_HOST"
      PING_FAIL_COUNT=0
    fi
  fi

  # Trigger B: captive probe (safety net)
  if [ $((now - LAST_PROBE)) -ge "$PROBE_INTERVAL" ]; then
    LAST_PROBE=$now
    probe_captive
    if [ "$PROBE_RESULT" = "ONLINE" ]; then
      NON_WI2_LOGGED=0
    else
      handle_expiry "probe:$PROBE_RESULT loc=$(redact_url "$PROBE_LOC")" "$PROBE_RESULT" "$PROBE_LOC"
    fi
  fi

  $SLEEP "$PING_INTERVAL"
done
