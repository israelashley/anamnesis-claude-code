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

BODY="$(jq -n --arg sid "$SID" --arg reason "$REASON" \
    '{session_id: $sid, reason: $reason}')"

if ! anamnesis_post "/mcp/tools/session_close" "$BODY" >/dev/null; then
    anamnesis_queue_payload "/mcp/tools/session_close" "$BODY"
    anamnesis_log_error "session_close_queued" "sid=$SID reason=$REASON"
fi

# Clear the session marker regardless — a new SessionStart will regenerate.
anamnesis_clear_session_id

exit 0
