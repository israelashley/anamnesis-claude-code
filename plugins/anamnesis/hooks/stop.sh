#!/usr/bin/env bash
# anamnesis/hooks/stop.sh
# Fires after every assistant turn. Captures the turn via log_session and
# forwards per-turn usage telemetry.
#
# Performance contract (0.3.2): this hook returns to Claude Code
# immediately — all network work runs in a detached background worker.
# Capture is incremental: a per-transcript high-water mark under
# $ANAMNESIS_STATE_DIR records how many JSONL lines have been shipped, and
# each Stop sends only the lines added since. A per-transcript lock
# serializes overlapping workers so a delta is never double-sent.
#
# Why not resend the whole transcript and lean on server dedup, as 0.3.1
# did? Two reasons: (a) the server ids episodes by ingest-time + chunk
# hash, so resends were *duplicating* episodes, not deduping; (b) the
# usage loop re-POSTed every historical turn on every Stop — O(n²) POSTs
# over a session's life, minutes of wall-clock by turn ~1000.

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

# Consume stdin in the foreground — Claude Code closes the pipe when the
# hook exits, so the background worker can't read it later.
STDIN_JSON="$(cat)"
TRANSCRIPT_PATH="$(printf '%s' "$STDIN_JSON" | jq -r '.transcript_path // empty' 2>/dev/null)"

anamnesis_stop_worker() {
    local transcript body

    if [ -n "$TRANSCRIPT_PATH" ] && [ -r "$TRANSCRIPT_PATH" ]; then
        local key state_file sent total delta_jsonl
        key="$(anamnesis_transcript_key "$TRANSCRIPT_PATH")"
        # If a live worker holds the lock past the wait, bail: the state
        # file only advances on send, so the next Stop picks the delta up.
        anamnesis_lock_acquire "$key" || return 0
        state_file="$ANAMNESIS_STATE_DIR/$key.json"

        sent="$(jq -r '.lines_sent // 0' < "$state_file" 2>/dev/null)"
        case "$sent" in *[!0-9]*|"") sent=0 ;; esac
        total="$(wc -l < "$TRANSCRIPT_PATH" | tr -d '[:space:]')"
        case "$total" in *[!0-9]*|"") total=0 ;; esac
        if [ "$total" -lt "$sent" ]; then
            # Transcript shrank — rotated or rewritten. Start over; the
            # content is new from our point of view.
            sent=0
        fi
        if [ "$total" -le "$sent" ]; then
            anamnesis_lock_release "$key"
            return 0
        fi
        delta_jsonl="$(tail -n +"$((sent + 1))" "$TRANSCRIPT_PATH" | head -n "$((total - sent))")"

        # Render the new rows the same way 0.3.1 rendered the full file.
        transcript="$(printf '%s' "$delta_jsonl" \
            | jq -r '. | (.message.content // .content // .text // "") | tostring' 2>/dev/null)"

        if [ -n "$transcript" ]; then
            body="$(printf '%s' "$transcript" | jq -Rs --arg sid "$SID" \
                '{session_id: $sid, transcript: .}')"
            if ! anamnesis_post "/mcp/tools/log_session" "$body" >/dev/null; then
                anamnesis_queue_payload "/mcp/tools/log_session" "$body"
                anamnesis_log_error "log_session_queued" "sid=$SID"
            fi
        fi

        # ── Usage telemetry ──────────────────────────────────────────────
        # One POST per NEW assistant turn (typically 1–3 per Stop). Shape
        # mirrors the Anthropic usage block; server sums and dedups by
        # turn_id. Fire-and-forget: a lost row is informational only.
        local usage_records rec usage_body
        usage_records="$(printf '%s' "$delta_jsonl" | jq -rc '
            select(.message?.usage?)
            | {
                input_tokens:                (.message.usage.input_tokens // 0),
                output_tokens:               (.message.usage.output_tokens // 0),
                cache_read_input_tokens:     (.message.usage.cache_read_input_tokens // 0),
                cache_creation_input_tokens: (.message.usage.cache_creation_input_tokens // 0),
                model:                       (.message.model // null),
                turn_id:                     (.message.id // .uuid // null)
            }' 2>/dev/null)"
        if [ -n "$usage_records" ]; then
            while IFS= read -r rec; do
                [ -z "$rec" ] && continue
                usage_body="$(printf '%s' "$rec" | jq --arg sid "$SID" \
                    '. + {session_id: $sid, source: "claude_code_plugin"}')"
                anamnesis_post "/mcp/tools/track_usage" "$usage_body" >/dev/null 2>&1 || true
            done <<< "$usage_records"
        fi

        # Advance the high-water mark. Failed sends were queued above, so
        # the delta is owned by the queue from here on.
        printf '{"transcript_path":%s,"lines_sent":%s}\n' \
            "$(printf '%s' "$TRANSCRIPT_PATH" | jq -Rs 'rtrimstr("\n")' 2>/dev/null || echo '""')" \
            "$total" > "$state_file" 2>/dev/null || true

        anamnesis_lock_release "$key"
        return 0
    fi

    # Fallback: no transcript file — log whatever stdin gave us.
    transcript="$(printf '%s' "$STDIN_JSON" | jq -r '
        .last_assistant_message // .assistant_message // .content // .
    ' 2>/dev/null)"
    [ -z "$transcript" ] && return 0
    body="$(printf '%s' "$transcript" | jq -Rs --arg sid "$SID" \
        '{session_id: $sid, transcript: .}')"
    if ! anamnesis_post "/mcp/tools/log_session" "$body" >/dev/null; then
        anamnesis_queue_payload "/mcp/tools/log_session" "$body"
        anamnesis_log_error "log_session_queued" "sid=$SID"
    fi
    return 0
}

# Detach: fds must not point at the hook's pipes or Claude Code would wait
# for EOF. The worker survives this script's exit.
anamnesis_stop_worker </dev/null >/dev/null 2>&1 &

exit 0
