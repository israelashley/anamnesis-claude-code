# Privacy — anamnesis Claude Code plugin

## What the hooks send

On every Claude Code lifecycle event, the plugin hooks read data from
Claude Code stdin and send it to `https://anamnesis.smtry.ai` over HTTPS:

- **SessionStart.** Nothing outbound except a health probe with your api_key.
- **UserPromptSubmit.** Your prompt text (as a query) to retrieve relevant
  memories. The response is injected into the turn's context.
- **Stop.** The assistant's reply and user prompt for the turn (sometimes
  the whole transcript, depending on what Claude Code puts in stdin).
- **SessionEnd.** Only the session id and a close reason.

These hooks see the full transcript of the session — that's how capture
works at all. They run **locally on your machine.**

## What the server does

1. Authenticates your request via the `X-Anamnesis-Key` header.
2. Derives an encryption key from your api_key via HKDF-SHA256.
3. Chunks the transcript, dedups by SHA-256 prefix, and writes each
   chunk encrypted under your derived key (Fernet: AES-128-CBC + HMAC-SHA256).
4. Never writes plaintext to disk. Content lives in request memory only
   for as long as the request is in flight.

## What the server can and can't do

- **Can't** read your memory content without your api_key. The key derives
  from your api_key; we don't store it separately.
- **Can't** use your content to train any model. This is architectural,
  not a policy promise.
- **Can** see access patterns (when you log in, when hooks fire, byte
  counts). This is unavoidable for any hosted service.
- **Can** respond to a subpoena with ciphertext, but the ciphertext is
  useless without your api_key.

See [anamnesis.smtry.ai/privacy](https://anamnesis.smtry.ai/privacy)
for the full policy, including subprocessor list and retention.

## Pausing / revoking

- Run `anamnesis pause` to stop capture immediately. Hooks become no-ops
  until you run `anamnesis resume`.
- Run `anamnesis-config` again to rotate your api_key.
- Delete individual memories or wipe everything at
  [anamnesis.smtry.ai/memory](https://anamnesis.smtry.ai/memory).

## Uninstall

```
/plugin uninstall anamnesis@smtry
rm -rf ~/.anamnesis
```

Server-side deletion is a separate action at `/memory`.
