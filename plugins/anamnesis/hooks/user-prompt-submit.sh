#!/usr/bin/env bash
# anamnesis/hooks/user-prompt-submit.sh
# Fires before every user turn. Retrieves top-k engrams + injects them
# plus a server-time anchor as hookSpecificOutput.additionalContext.
#
# Design constraints (ADR-062 §8):
#   - Terse. Self-cap ~2000 chars (10k is the Claude Code hard cap).
#   - Topically gated: skip injection entirely when no engram clears
#     the similarity floor (claude-mem #1079 noise lesson).
#   - Never persona/rules/guidance. Only retrieval + time anchor.

set -u
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$HOOK_DIR/common.sh"

anamnesis_check_pause
anamnesis_load_config || exit 0

# Stdin is a JSON object with at least .prompt (UserPromptSubmit hook input).
STDIN_JSON="$(cat)"
PROMPT="$(printf '%s' "$STDIN_JSON" | jq -r '.prompt // empty' 2>/dev/null)"

if [ -z "$PROMPT" ]; then
    # No prompt to query on — emit nothing, exit 0.
    exit 0
fi

# Query knobs. Keep conservative in v0: hierarchical/standard, 5 engrams,
# min_similarity 0.35 to cut weak matches.
QUERY_BODY="$(jq -n \
    --arg q "$PROMPT" \
    '{query: $q, top_n: 5, mode: "hierarchical", detail_level: "standard", min_similarity: 0.35, diversity: 0.3}')"

RESPONSE="$(anamnesis_post "/mcp/tools/retrieve_memories" "$QUERY_BODY")"
POST_STATUS=$?

if [ $POST_STATUS -ne 0 ]; then
    anamnesis_log_error "retrieve_failed" "status=$POST_STATUS"
    # Fail-open: still emit the time anchor so the model at least knows
    # what day it is. Authoritative server time from the Date: header we
    # captured in anamnesis_post, even on failure paths (will be empty if
    # we couldn't reach the server at all).
    if [ -n "${ANAMNESIS_SERVER_TIME:-}" ]; then
        ADDL=$(printf '<server-time source="anamnesis">%s</server-time>' "$ANAMNESIS_SERVER_TIME")
        jq -n --arg ctx "$ADDL" \
            '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}}'
    fi
    exit 0
fi

# Parse top engrams. Pull from .engrams (hierarchical) or .results (flat).
# Filter: only items with .content present; keep top 5 after server scoring.
ENGRAMS_JSON="$(printf '%s' "$RESPONSE" | jq -c '
    def pick:
        if (.content // null) != null then {score: (.score // 0), content: .content}
        elif (.text // null) != null    then {score: (.score // 0), content: .text}
        else empty end;
    ((.engrams // []) + (.results // [])) | map(pick) | .[0:5]
' 2>/dev/null)"

ENGRAM_COUNT="$(printf '%s' "$ENGRAMS_JSON" | jq 'length' 2>/dev/null)"
ENGRAM_COUNT="${ENGRAM_COUNT:-0}"

# Build additionalContext.
# If we have engrams: <anamnesis-context> block + <server-time> anchor.
# If we don't: server-time only. Never both empty.
ADDL=""
if [ "$ENGRAM_COUNT" -gt 0 ]; then
    # Format each engram as a bullet. Cap per-engram at 350 chars to stay
    # under the 2000-char self-cap in aggregate (5 * 350 = 1750 + wrapper).
    BODY="$(printf '%s' "$ENGRAMS_JSON" | jq -r '
        .[] | "- (" + ((.score | tostring)[0:5]) + ") " + (.content | gsub("\n"; " ") | .[0:350])
    ' 2>/dev/null)"
    ADDL="$(printf '<anamnesis-context source="anamnesis" count="%s">\n%s\n</anamnesis-context>' "$ENGRAM_COUNT" "$BODY")"
fi

if [ -n "${ANAMNESIS_SERVER_TIME:-}" ]; then
    TIME_LINE="$(printf '<server-time source="anamnesis">%s</server-time>' "$ANAMNESIS_SERVER_TIME")"
    if [ -n "$ADDL" ]; then
        ADDL="$ADDL"$'\n'"$TIME_LINE"
    else
        ADDL="$TIME_LINE"
    fi
fi

if [ -z "$ADDL" ]; then
    exit 0
fi

# Final self-cap: trim to 2000 chars. If somehow we're over (shouldn't be
# given per-engram cap), fall through with truncation + ellipsis.
CAP=2000
ADDL_LEN=${#ADDL}
if [ "$ADDL_LEN" -gt $CAP ]; then
    ADDL="$(printf '%s' "$ADDL" | head -c $CAP)…"
fi

jq -n --arg ctx "$ADDL" \
    '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}}'

exit 0
