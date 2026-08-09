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
anamnesis-config                  # interactive — opens browser for OAuth consent
```

`anamnesis-config` starts a loopback server, registers a Dynamic Client
(RFC 7591), opens your browser to `anamnesis.smtry.ai/oauth/authorize`,
and catches the redirect. You paste your api_key on the consent page,
approve the scopes (`memory.read memory.write` by default — add
`--allow-delete` to also request `memory.delete`), and return to the
terminal. The access + refresh tokens land in `~/.anamnesis/config.json`
(mode 0600); hooks rotate the refresh token automatically before
expiry, so the setup is one-and-done.

Scripted installs (CI, headless servers) can skip the browser with
`anamnesis-config --api-key anm_... --handle jia`, but the legacy
`X-Anamnesis-Key` header path is deprecated — it returns 401 after
**2026-05-20**. Re-run `anamnesis-config` without flags before then.

## What the hooks do

| Hook | When | What it does |
|------|------|--------------|
| `SessionStart` | Once per session | Issues a fresh `session_id`, drains the pending-upload queue, probes server reachability. |
| `UserPromptSubmit` | Before every user turn | Retrieves top-5 relevant engrams + a **server-time anchor** (authoritative, from the HTTP `Date:` header), injects them as `additionalContext`. Model starts the turn oriented. |
| `Stop` | After every assistant turn | Captures the turn via `log_session`. Server dedups by SHA-256 prefix — re-sends are idempotent. |
| `SessionEnd` | Session close | Calls `session_close`, advancing the server-side pipeline (episodes → echoes). Clears the session marker. |

All four are POSIX shell scripts that use `curl` + `jq`. No Node, no
compiled binaries. `python3` is only required once, by `anamnesis-config`,
for the PKCE loopback server during the OAuth consent flow — hooks
themselves stay shell-only.

## Control surface

```
anamnesis                  status (default)
anamnesis pause            suspend capture — hooks become no-ops
anamnesis resume           re-enable capture
```

The `paused` sentinel file at `~/.anamnesis/paused` is the first thing
every hook checks. Deleting the file resumes immediately. No daemon, no
restart, no shell refresh needed.

## Receipts — proof it's working, at zero token cost

Occasionally the plugin prints a tagged status line in your terminal:

```
[anamnesis] recalled 4 memories for this prompt — context you didn't have to re-explain
[anamnesis] session capture is live — 12 turns backed up so far. /clear is free whenever you want it.
```

Receipts are **state-triggered, never scheduled** — one fires because
something measurable just happened (a recall served, a capture landed),
at most once per session per kind. They are delivered through the hook
`systemMessage` channel, which renders to *you* but is never added to
the model's context: a receipt costs **0 tokens**, and CI asserts that
receipt text can never appear in injected context.

Why they exist: memory infrastructure is invisible precisely when it's
working. Receipts are the visible heartbeat — and the capture receipt
carries the practical tip that matters most: once your session is backed
up, `/clear` is free. A fresh context window is cheaper *and* sharper,
and Anamnesis is what makes clearing survivable.

Tune them with the `receipts` key in `~/.anamnesis/config.json`:

| Value | Effect |
|-------|--------|
| `"normal"` (default) | All receipt kinds. |
| `"minimal"` | Reserved for high-value receipts only (context-pressure and compaction notices, coming in 0.4.x) — current informational receipts are silenced. |
| `"off"` | No receipts, ever. Capture and recall behave identically — visibility is a default, never a hostage. |

## What makes this different from claude-mem and mem0

The hook shape is borrowed — Stop-per-turn, fail-open, per-event JSON
input — because those patterns are correct. What's ours:

1. **Crypto posture.** Per-user HKDF-derived keys — no master key, so a
   bulk database compromise alone decrypts nothing. Not yet end-to-end:
   client-held keys are the roadmap, and
   [anamnesis.smtry.ai/security](https://anamnesis.smtry.ai/security)
   says exactly who can decrypt what. Memory tools typically ship
   plaintext on disk or manage keys entirely server-side; we publish the
   boundary and the roadmap past it.
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
| `~/.anamnesis/config.json` | OAuth: handle, server_url, access_token, refresh_token, expires_at, client_id. Legacy: api_key, handle, server_url. | 0600 |
| `~/.anamnesis/current_session.json` | session_id for the live session | 0600 |
| `~/.anamnesis/paused` | present ⇒ hooks exit 0 silently | 0600 |
| `~/.anamnesis/pending_uploads/*.json` | queued payloads from prior failures; drained on next SessionStart | 0600 |
| `~/.anamnesis/receipt_state/` | receipt rate-limit markers + deferred capture-receipt outcome; swept at SessionEnd | 0600 |
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
want all traces gone — deletion removes the encrypted files from the
live store, and full account deletion is self-serve from the account
page.

## License

MIT. See [`LICENSE`](../../LICENSE).
