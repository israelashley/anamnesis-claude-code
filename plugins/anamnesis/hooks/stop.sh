#!/usr/bin/env bash
# anamnesis/hooks/stop.sh
# Fires after every assistant turn. Captures the turn via log_session.
# Server chunks on 2000-char boundaries and dedups by SHA-256 prefix —
# re-sending is idempotent (ADR-062 §4).
#
# Stdin (Claude Code Stop hook input) contains a JSON object that
# typically includes .transcript_path pointing to the session JSONL.
# We prefer reading the whole transcript from that path; fall back to
# piping stdin as raw transcript text.

set -u
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$HOOK_DIR/common.sh"

anamnesis_check_pause
anamnesis_load_config || exit 0

SID="$(anamnesis_read_session_id)"
if [ -z "$SID" ]; then
    # SessionStart didn't fire (or state was lost). Synthesize a
    # recovery id so server gets a session_id to dedup against.
    SID="recovered-$(date -u +"%Y%m%dT%H%M%SZ")"
    anamnesis_write_session_id "$SID"
fi

STDIN_JSON="$(cat)"
TRANSCRIPT_PATH="$(printf '%s' "$STDIN_JSON" | jq -r '.transcript_path // empty' 2>/dev/null)"

TRANSCRIPT=""
if [ -n "$TRANSCRIPT_PATH" ] && [ -r "$TRANSCRIPT_PATH" ]; then
    # Read the JSONL transcript, extract content per row, join with newlines.
    TRANSCRIPT="$(jq -r '. | (.message.content // .content // .text // "") | tostring' \
        < "$TRANSCRIPT_PATH" 2>/dev/null)"
fi

# Fallback: use whatever stdin gave us (e.g. .last_assistant_message or raw).
if [ -z "$TRANSCRIPT" ]; then
    TRANSCRIPT="$(printf '%s' "$STDIN_JSON" | jq -r '
        .last_assistant_message // .assistant_message // .content // .
    ' 2>/dev/null)"
fi

if [ -z "$TRANSCRIPT" ]; then
    # Nothing to log — not an error, not every Stop carries content.
    exit 0
fi

BODY="$(jq -n --arg sid "$SID" --arg tx "$TRANSCRIPT" \
    '{session_id: $sid, transcript: $tx}')"

if ! anamnesis_post "/mcp/tools/log_session" "$BODY" >/dev/null; then
    anamnesis_queue_payload "/mcp/tools/log_session" "$BODY"
    anamnesis_log_error "log_session_queued" "sid=$SID"
fi

# ── Usage telemetry ─────────────────────────────────────────────────────────
# Parse each message row's .message.usage block from the transcript JSONL
# and POST totals to /mcp/tools/track_usage. One POST per turn tracked in
# this file, so the dashboard's Tokens Paid card ticks live as assistant
# turns complete. Dedup is handled server-side via the turn_id (uuid field
# from the message row). Fire-and-forget: failures are silently queued.
#
# The Anthropic API response usage shape we're pulling:
#   { "input_tokens": N, "output_tokens": M,
#     "cache_read_input_tokens": X, "cache_creation_input_tokens": Y }
# Claude Code writes it under .message.usage on each assistant turn.
if [ -n "$TRANSCRIPT_PATH" ] && [ -r "$TRANSCRIPT_PATH" ]; then
    # Extract one usage record per line that carries a usage block. Missing
    # fields default to 0. Null .message.usage rows are dropped.
    USAGE_RECORDS="$(jq -rc '
        select(.message?.usage?)
        | {
            input_tokens:                (.message.usage.input_tokens // 0),
            output_tokens:               (.message.usage.output_tokens // 0),
            cache_read_input_tokens:     (.message.usage.cache_read_input_tokens // 0),
            cache_creation_input_tokens: (.message.usage.cache_creation_input_tokens // 0),
            model:                       (.message.model // null),
            turn_id:                     (.message.id // .uuid // null)
        }' < "$TRANSCRIPT_PATH" 2>/dev/null)"

    if [ -n "$USAGE_RECORDS" ]; then
        # One POST per record. Losing a row to a network blip is acceptable —
        # the totals are informational, not load-bearing, and the next turn
        # will re-fire its own event so drift stays bounded.
        while IFS= read -r REC; do
            [ -z "$REC" ] && continue
            USAGE_BODY="$(printf '%s' "$REC" | jq --arg sid "$SID" \
                '. + {session_id: $sid, source: "claude_code_plugin"}')"
            anamnesis_post "/mcp/tools/track_usage" "$USAGE_BODY" >/dev/null 2>&1 || true
        done <<< "$USAGE_RECORDS"
    fi
fi

exit 0
