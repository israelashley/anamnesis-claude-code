#!/usr/bin/env bash
# anamnesis/hooks/session-start.sh
# Fires once per Claude Code session. Issues a fresh session_id, drains
# pending uploads from prior crashes, probes server reachability. Never
# blocks — always exits 0.

set -u
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$HOOK_DIR/common.sh"

anamnesis_check_pause
anamnesis_load_config || exit 0   # config not set up yet — silent no-op

# Fresh session_id
SID="$(anamnesis_gen_session_id)"
anamnesis_write_session_id "$SID"

# Drain any queued payloads from prior session crashes
anamnesis_drain_queue

# Health probe (cheap, confirms auth + connectivity; failures logged, not blocking)
if ! anamnesis_post "/mcp/tools/get_memory_stats" '{}' >/dev/null; then
    anamnesis_log_error "session_start_health_probe_failed" "sid=$SID"
    # Fall through — we don't block the session on probe failure
fi

exit 0
