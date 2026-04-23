#!/usr/bin/env bash
# anamnesis/hooks/common.sh — shared helpers sourced by every hook.
# Principles (ADR-062 §7): fail-open. Hooks NEVER block Claude Code on
# transient errors. Exit 0 with warnings on stderr; exit 1 only on hard
# network/auth failure (Claude Code treats exit 1 as non-blocking warning);
# exit 2 reserved for programming bugs.

set -u

ANAMNESIS_HOME="${ANAMNESIS_HOME:-$HOME/.anamnesis}"
ANAMNESIS_CONFIG="$ANAMNESIS_HOME/config.json"
ANAMNESIS_SESSION_FILE="$ANAMNESIS_HOME/current_session.json"
ANAMNESIS_ERROR_LOG="$ANAMNESIS_HOME/hook_errors.log"
ANAMNESIS_PAUSE_FILE="$ANAMNESIS_HOME/paused"
ANAMNESIS_QUEUE_DIR="$ANAMNESIS_HOME/pending_uploads"
ANAMNESIS_CURL_TIMEOUT="${ANAMNESIS_CURL_TIMEOUT:-8}"

mkdir -p "$ANAMNESIS_HOME" "$ANAMNESIS_QUEUE_DIR" 2>/dev/null || true

# --- pause sentinel -------------------------------------------------------
# First line of every hook calls this. If paused, silently exit 0.
anamnesis_check_pause() {
    if [ -f "$ANAMNESIS_PAUSE_FILE" ]; then
        exit 0
    fi
}

# --- structured logging ---------------------------------------------------
anamnesis_log_error() {
    local event="$1"
    local detail="$2"
    local ts
    ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    printf '{"ts":"%s","event":"%s","detail":%s}\n' \
        "$ts" "$event" "$(printf '%s' "$detail" | jq -Rs . 2>/dev/null || echo '"<unloggable>"')" \
        >> "$ANAMNESIS_ERROR_LOG" 2>/dev/null || true
}

# --- config loader --------------------------------------------------------
# Sets ANAMNESIS_API_KEY, ANAMNESIS_HANDLE, ANAMNESIS_SERVER_URL.
# Returns 1 if config is absent or malformed (hook should exit 0 quietly —
# user hasn't finished setup yet).
anamnesis_load_config() {
    if [ ! -r "$ANAMNESIS_CONFIG" ]; then
        return 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        anamnesis_log_error "missing_dep" "jq not found in PATH"
        return 1
    fi
    ANAMNESIS_API_KEY="$(jq -r '.api_key // empty' < "$ANAMNESIS_CONFIG" 2>/dev/null)"
    ANAMNESIS_HANDLE="$(jq -r '.handle // empty' < "$ANAMNESIS_CONFIG" 2>/dev/null)"
    ANAMNESIS_SERVER_URL="$(jq -r '.server_url // "https://anamnesis.smtry.ai"' < "$ANAMNESIS_CONFIG" 2>/dev/null)"
    if [ -z "$ANAMNESIS_API_KEY" ]; then
        anamnesis_log_error "config_missing_api_key" "$ANAMNESIS_CONFIG"
        return 1
    fi
    export ANAMNESIS_API_KEY ANAMNESIS_HANDLE ANAMNESIS_SERVER_URL
    return 0
}

# --- session_id -----------------------------------------------------------
anamnesis_read_session_id() {
    if [ -r "$ANAMNESIS_SESSION_FILE" ]; then
        jq -r '.session_id // empty' < "$ANAMNESIS_SESSION_FILE" 2>/dev/null
    fi
}

anamnesis_write_session_id() {
    local sid="$1"
    local ts
    ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    printf '{"session_id":"%s","started_at":"%s"}\n' "$sid" "$ts" \
        > "$ANAMNESIS_SESSION_FILE"
    chmod 600 "$ANAMNESIS_SESSION_FILE" 2>/dev/null || true
}

anamnesis_clear_session_id() {
    rm -f "$ANAMNESIS_SESSION_FILE" 2>/dev/null || true
}

anamnesis_gen_session_id() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    elif [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    else
        # Fallback — epoch + random. Not RFC-compliant UUID but unique-enough.
        printf 'sess-%s-%04x%04x' "$(date +%s)" $RANDOM $RANDOM
    fi
}

# --- curl wrapper ---------------------------------------------------------
# Usage: anamnesis_post <path> <json-body>
# Writes response body to stdout. Returns:
#   0 on 2xx, 1 on network/4xx/5xx, 2 on auth (401/403).
# Also captures Date: response header in ANAMNESIS_SERVER_TIME (RFC 2822).
anamnesis_post() {
    local path="$1"
    local body="$2"
    local url="${ANAMNESIS_SERVER_URL}${path}"
    local tmp_headers tmp_body
    tmp_headers="$(mktemp 2>/dev/null || printf '/tmp/anamnesis_h_%s' $$)"
    tmp_body="$(mktemp 2>/dev/null || printf '/tmp/anamnesis_b_%s' $$)"
    local status
    status="$(curl -sS -X POST "$url" \
        --max-time "$ANAMNESIS_CURL_TIMEOUT" \
        -H "X-Anamnesis-Key: $ANAMNESIS_API_KEY" \
        -H "Content-Type: application/json" \
        -D "$tmp_headers" \
        -o "$tmp_body" \
        -w "%{http_code}" \
        --data-binary "$body" 2>/dev/null)" || status="000"

    # Pick up authoritative server time from Date: header
    ANAMNESIS_SERVER_TIME="$(grep -i '^date:' "$tmp_headers" 2>/dev/null | head -1 | sed 's/^[Dd]ate:[[:space:]]*//; s/\r$//')"

    cat "$tmp_body" 2>/dev/null
    rm -f "$tmp_headers" "$tmp_body" 2>/dev/null || true

    case "$status" in
        2*) return 0 ;;
        401|403) return 2 ;;
        *) return 1 ;;
    esac
}

# --- queue drain ----------------------------------------------------------
# Replays any pending_uploads/*.json files (created by prior hook failures).
anamnesis_drain_queue() {
    local count=0
    for f in "$ANAMNESIS_QUEUE_DIR"/*.json; do
        [ -r "$f" ] || continue
        local path body
        path="$(jq -r '.path // empty' < "$f" 2>/dev/null)"
        body="$(jq -c '.body' < "$f" 2>/dev/null)"
        if [ -n "$path" ] && [ -n "$body" ]; then
            if anamnesis_post "$path" "$body" >/dev/null; then
                rm -f "$f"
                count=$((count + 1))
            fi
        fi
    done
    [ $count -gt 0 ] && anamnesis_log_error "queue_drained" "$count payloads replayed"
    return 0
}

# --- queue add ------------------------------------------------------------
anamnesis_queue_payload() {
    local path="$1"
    local body="$2"
    local f
    f="$ANAMNESIS_QUEUE_DIR/$(date +%s)_$$_$RANDOM.json"
    jq -n --arg path "$path" --argjson body "$body" \
        '{path: $path, body: $body, queued_at: (now | todate)}' \
        > "$f" 2>/dev/null || true
}
