# anamnesis — persistent encrypted memory for Claude Code

Four lifecycle hooks capture every session. A per-user HKDF-derived key
encrypts content server-side — nobody at smtry.ai can read it without
your api_key. Browse, search, and delete any memory at
[anamnesis.smtry.ai/memory](https://anamnesis.smtry.ai/memory).

## Install

```
/plugin marketplace add https://github.com/israelashley/anamnesis-claude-code
/plugin install anamnesis@smtry
```

Then, once:

```
anamnesis-config                  # interactive — paste api_key + handle
```

Open a new Claude Code session. On the first MCP tool call, your browser
opens `anamnesis.smtry.ai/oauth/authorize` — paste your api_key, approve
the three scopes (`memory.read`, `memory.write`, `memory.delete`), and
return to the terminal. The OAuth access token lives in your system
keychain (macOS) / credentials file (Linux/Windows); it is never written
to a config file or shell env. On the same session the `SessionStart`
hook fires, probes the server, and drains any queued uploads from prior
crashes.

## What the hooks do

| Hook | When | What it does |
|------|------|--------------|
| `SessionStart` | Once per session | Issues a fresh `session_id`, drains the pending-upload queue, probes server reachability. |
| `UserPromptSubmit` | Before every user turn | Retrieves top-5 relevant engrams + a **server-time anchor** (authoritative, from the HTTP `Date:` header), injects them as `additionalContext`. Model starts the turn oriented. |
| `Stop` | After every assistant turn | Captures the turn via `log_session`. Server dedups by SHA-256 prefix — re-sends are idempotent. |
| `SessionEnd` | Session close | Calls `session_close`, advancing the server-side pipeline (episodes → echoes). Clears the session marker. |

All four are POSIX shell scripts that use `curl` + `jq`. No Node, no
Python, no compiled binaries.

## Control surface

```
anamnesis                  status (default)
anamnesis pause            suspend capture — hooks become no-ops
anamnesis resume           re-enable capture
```

The `paused` sentinel file at `~/.anamnesis/paused` is the first thing
every hook checks. Deleting the file resumes immediately. No daemon, no
restart, no shell refresh needed.

## What makes this different from claude-mem and mem0

The hook shape is borrowed — Stop-per-turn, fail-open, per-event JSON
input — because those patterns are correct. What's ours:

1. **Crypto posture.** Per-user HKDF-derived keys. Lose your api_key and
   even smtry.ai cannot recover your memory. Competitors either ship
   plaintext on disk (claude-mem) or hold the decryption key themselves
   (mem0).
2. **Pipeline structure.** Episodes → Echoes → Engrams with explicit
   quality gates and reject-and-audit. Low-signal content is quarantined
   with a reason, not silently curated.
3. **Visible memory.** Browse, search, and delete your memory as a
   first-class UI at `/memory`. Competitors ship text files on disk or
   developer APIs.
4. **Time grounding.** Every `UserPromptSubmit` injection carries a
   `<server-time source="anamnesis">` line read from the server's
   authoritative HTTP `Date` header — the model always knows what day
   it is, grounded on the server's clock, not the user's drifted laptop.
5. **Cross-client fidelity.** The same MCP server backs this plugin,
   Claude Desktop, and any MCP-aware client. Install the plugin on
   Claude Code and the connector on Claude Desktop: same api_key, same
   memory root, same encryption.
6. **Control surface.** `anamnesis pause|resume|status` as first-class
   commands — not a config file you have to remember the shape of.

## Configuration files

| Path | Contents | Mode |
|------|----------|------|
| `~/.anamnesis/config.json` | api_key, handle, server_url | 0600 |
| `~/.anamnesis/current_session.json` | session_id for the live session | 0600 |
| `~/.anamnesis/paused` | present ⇒ hooks exit 0 silently | 0600 |
| `~/.anamnesis/pending_uploads/*.json` | queued payloads from prior failures; drained on next SessionStart | 0600 |
| `~/.anamnesis/hook_errors.log` | structured JSONL of transient errors — for debugging only | 0644 |

All state is user-local and user-readable. Nothing in `.claude/settings.json`
holds your api_key.

## Failure behavior

Hooks **never block Claude Code.** On any server error they:

1. Print a one-line warning to stderr.
2. Append a structured entry to `~/.anamnesis/hook_errors.log`.
3. Queue the failed payload under `~/.anamnesis/pending_uploads/`.
4. Exit `1` — non-blocking. Claude Code continues the session.

The next `SessionStart` drains the queue before doing anything else.

## Uninstall

```
/plugin uninstall anamnesis@smtry
rm -rf ~/.anamnesis   # optional — removes local config + queued uploads
```

Delete your server-side memory at `anamnesis.smtry.ai/memory` if you
want all traces gone. Deletes are cryptographic — content is written to
disk encrypted under your key; when you delete we also drop the key
reference, so recovery is structurally impossible.

## License

MIT. See [`LICENSE`](../../LICENSE).
