#!/usr/bin/env bash
# anamnesis/hooks/session-end.sh
# Fires when a Claude Code session closes. Triggers server-side pipeline
# advance (episodes → echoes) for this session's captured content.

set -u
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$HOOK_DIR/common.sh"

anamnesis_check_pause
anamnesis_load_config || exit 0

SID="$(anamnesis_read_session_id)"
if [ -z "$SID" ]; then
    # Nothing to close. Still OK — idempotent.
    exit 0
fi

STDIN_JSON="$(cat 2>/dev/null || true)"
REASON="$(printf '%s' "$STDIN_JSON" | jq -r '.reason // "exit"' 2>/dev/null)"
[ -z "$REASON" ] && REASON="exit"

# Stop's capture worker runs in the background (0.3.2). Give the final
# turn's upload a moment to land before session_close triggers reflection —
# otherwise that content waits for the nightly batch. Wait ≤15s for a live
# worker, then proceed regardless (reflection is idempotent, batch is the
# backstop).
TRANSCRIPT_PATH="$(printf '%s' "$STDIN_JSON" | jq -r '.transcript_path // empty' 2>/dev/null)"
if [ -n "$TRANSCRIPT_PATH" ]; then
    KEY="$(anamnesis_transcript_key "$TRANSCRIPT_PATH")"
    if anamnesis_lock_acquire "$KEY" 30; then
        anamnesis_lock_release "$KEY"
    fi
fi

BODY="$(jq -n --arg sid "$SID" --arg reason "$REASON" \
    '{session_id: $sid, reason: $reason}')"

if ! anamnesis_post "/mcp/tools/session_close" "$BODY" >/dev/null; then
    anamnesis_queue_payload "/mcp/tools/session_close" "$BODY"
    anamnesis_log_error "session_close_queued" "sid=$SID reason=$REASON"
fi

# Receipt housekeeping (ADR-070): this session's rate-limit markers are
# spent, and any unconsumed pending capture receipt must not leak into the
# next session. Prune sweeps markers from sessions that never ended cleanly.
rm -f "$ANAMNESIS_RECEIPT_DIR/$(anamnesis_transcript_key "$SID")".* \
      "$ANAMNESIS_RECEIPT_DIR/pending_capture.json" 2>/dev/null || true
anamnesis_receipt_prune

# Clear the session marker regardless — a new SessionStart will regenerate.
anamnesis_clear_session_id

exit 0
