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
# Populates auth state from ~/.anamnesis/config.json. Supports two modes:
#
#   ANAMNESIS_AUTH_MODE=oauth  — OAuth 2.1 + PKCE (target state).
#     Sets ANAMNESIS_ACCESS_TOKEN, ANAMNESIS_REFRESH_TOKEN,
#     ANAMNESIS_EXPIRES_AT (unix seconds), ANAMNESIS_OAUTH_CLIENT_ID.
#
#   ANAMNESIS_AUTH_MODE=legacy — raw api_key (deprecated 2026-05-20).
#     Sets ANAMNESIS_API_KEY. Used when an existing install hasn't re-run
#     anamnesis-config yet; keeps hooks working through the cutoff window.
#
# Always sets ANAMNESIS_HANDLE + ANAMNESIS_SERVER_URL when available.
# Returns 1 if config is absent/malformed/missing all credentials — the
# hook should exit 0 quietly (user hasn't finished setup yet).
anamnesis_load_config() {
    if [ ! -r "$ANAMNESIS_CONFIG" ]; then
        return 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        anamnesis_log_error "missing_dep" "jq not found in PATH"
        return 1
    fi

    ANAMNESIS_HANDLE="$(jq -r '.handle // empty'                         < "$ANAMNESIS_CONFIG" 2>/dev/null)"
    ANAMNESIS_SERVER_URL="$(jq -r '.server_url // "https://anamnesis.smtry.ai"' < "$ANAMNESIS_CONFIG" 2>/dev/null)"
    ANAMNESIS_ACCESS_TOKEN="$(jq -r '.access_token // empty'             < "$ANAMNESIS_CONFIG" 2>/dev/null)"
    ANAMNESIS_REFRESH_TOKEN="$(jq -r '.refresh_token // empty'           < "$ANAMNESIS_CONFIG" 2>/dev/null)"
    ANAMNESIS_EXPIRES_AT="$(jq -r '.expires_at // 0'                     < "$ANAMNESIS_CONFIG" 2>/dev/null)"
    ANAMNESIS_OAUTH_CLIENT_ID="$(jq -r '.client_id // empty'             < "$ANAMNESIS_CONFIG" 2>/dev/null)"
    ANAMNESIS_API_KEY="$(jq -r '.api_key // empty'                       < "$ANAMNESIS_CONFIG" 2>/dev/null)"

    if [ -n "$ANAMNESIS_ACCESS_TOKEN" ] && [ -n "$ANAMNESIS_REFRESH_TOKEN" ]; then
        ANAMNESIS_AUTH_MODE="oauth"
    elif [ -n "$ANAMNESIS_API_KEY" ]; then
        ANAMNESIS_AUTH_MODE="legacy"
    else
        anamnesis_log_error "config_missing_credentials" "$ANAMNESIS_CONFIG"
        return 1
    fi

    export ANAMNESIS_HANDLE ANAMNESIS_SERVER_URL ANAMNESIS_AUTH_MODE \
           ANAMNESIS_ACCESS_TOKEN ANAMNESIS_REFRESH_TOKEN \
           ANAMNESIS_EXPIRES_AT ANAMNESIS_OAUTH_CLIENT_ID ANAMNESIS_API_KEY
    return 0
}

# --- token refresh --------------------------------------------------------
# Called from anamnesis_post() before every request. No-op on legacy
# mode. In oauth mode, refreshes the access_token via /oauth/token's
# refresh_token grant if <60s remain until expiry. Server rotates the
# refresh_token on every use, so a successful refresh ALWAYS rewrites
# config.json atomically with the new pair; a failure leaves the stale
# tokens in place and we fall through (the /mcp call will 401 and the
# hook logs it).
#
# Concurrency: a simple lockfile prevents two hooks from refreshing
# simultaneously and burning the rotation. Without it, one hook's
# post-refresh state clobbers the other and next call fails.
anamnesis_ensure_token() {
    [ "${ANAMNESIS_AUTH_MODE:-}" = "oauth" ] || return 0
    local now
    now="$(date -u +"%s")"
    # Refresh threshold: 60s before expiry. Burning a refresh for each
    # hook call is wasteful, but waiting until 0s leaves a race where the
    # token expires mid-request.
    local threshold=$((now + 60))
    if [ "${ANAMNESIS_EXPIRES_AT:-0}" -gt "$threshold" ]; then
        return 0  # token is still fresh
    fi

    local lock="$ANAMNESIS_HOME/refresh.lock"
    # mkdir is atomic — races cleanly. Wait up to 10s for the other hook
    # to finish, then re-check expiry in case it already refreshed.
    local waited=0
    while ! mkdir "$lock" 2>/dev/null; do
        waited=$((waited + 1))
        [ $waited -gt 20 ] && break  # ~10s at 0.5s sleeps
        sleep 0.5 2>/dev/null || sleep 1
    done
    # Re-read config in case the other process refreshed while we waited.
    if [ $waited -gt 0 ]; then
        anamnesis_load_config >/dev/null 2>&1 || true
        if [ "${ANAMNESIS_EXPIRES_AT:-0}" -gt "$threshold" ]; then
            rmdir "$lock" 2>/dev/null || true
            return 0
        fi
    fi

    local resp
    resp="$(curl -sS -X POST "${ANAMNESIS_SERVER_URL}/oauth/token" \
        --max-time "$ANAMNESIS_CURL_TIMEOUT" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "grant_type=refresh_token" \
        --data-urlencode "refresh_token=${ANAMNESIS_REFRESH_TOKEN}" \
        --data-urlencode "client_id=${ANAMNESIS_OAUTH_CLIENT_ID}" \
        2>/dev/null)" || resp=""

    local new_access new_refresh new_expires_in
    new_access="$(printf '%s' "$resp"     | jq -r '.access_token  // empty' 2>/dev/null)"
    new_refresh="$(printf '%s' "$resp"    | jq -r '.refresh_token // empty' 2>/dev/null)"
    new_expires_in="$(printf '%s' "$resp" | jq -r '.expires_in    // 0'     2>/dev/null)"

    if [ -z "$new_access" ] || [ -z "$new_refresh" ]; then
        anamnesis_log_error "refresh_failed" "$(printf '%s' "$resp" | head -c 200)"
        rmdir "$lock" 2>/dev/null || true
        return 1
    fi

    local new_expires_at
    new_expires_at="$(date -u -v+"${new_expires_in}"S +"%s" 2>/dev/null \
                    || date -u -d "+${new_expires_in} seconds" +"%s" 2>/dev/null \
                    || echo 0)"

    # Atomic rewrite: write to tmp in the same dir, then rename.
    local tmp="$ANAMNESIS_CONFIG.tmp.$$"
    jq \
        --arg at "$new_access" \
        --arg rt "$new_refresh" \
        --argjson xa "${new_expires_at:-0}" \
        '.access_token = $at | .refresh_token = $rt | .expires_at = $xa' \
        < "$ANAMNESIS_CONFIG" > "$tmp" 2>/dev/null \
        && chmod 600 "$tmp" \
        && mv -f "$tmp" "$ANAMNESIS_CONFIG"

    ANAMNESIS_ACCESS_TOKEN="$new_access"
    ANAMNESIS_REFRESH_TOKEN="$new_refresh"
    ANAMNESIS_EXPIRES_AT="$new_expires_at"
    export ANAMNESIS_ACCESS_TOKEN ANAMNESIS_REFRESH_TOKEN ANAMNESIS_EXPIRES_AT

    rmdir "$lock" 2>/dev/null || true
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
#
# Auth header selection:
#   oauth mode  → ensure_token (refresh if needed), send Authorization: Bearer
#   legacy mode → X-Anamnesis-Key (deprecated, warns once/day)
anamnesis_post() {
    local path="$1"
    local body="$2"
    local url="${ANAMNESIS_SERVER_URL}${path}"
    local auth_header

    if [ "${ANAMNESIS_AUTH_MODE:-legacy}" = "oauth" ]; then
        anamnesis_ensure_token || true  # fall through on refresh failure; server 401 will surface it
        auth_header="Authorization: Bearer ${ANAMNESIS_ACCESS_TOKEN}"
    else
        # Legacy path — one nag/day. Suppress if already warned today.
        local warn_marker="$ANAMNESIS_HOME/.legacy_auth_warned_$(date -u +%Y%m%d)"
        if [ ! -f "$warn_marker" ]; then
            anamnesis_log_error "legacy_auth_deprecated" "X-Anamnesis-Key stops working 2026-05-20 — run 'anamnesis-config' to upgrade"
            touch "$warn_marker" 2>/dev/null || true
        fi
        auth_header="X-Anamnesis-Key: ${ANAMNESIS_API_KEY}"
    fi

    local tmp_headers tmp_body
    tmp_headers="$(mktemp 2>/dev/null || printf '/tmp/anamnesis_h_%s' $$)"
    tmp_body="$(mktemp 2>/dev/null || printf '/tmp/anamnesis_b_%s' $$)"
    local status
    status="$(curl -sS -X POST "$url" \
        --max-time "$ANAMNESIS_CURL_TIMEOUT" \
        -H "$auth_header" \
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
