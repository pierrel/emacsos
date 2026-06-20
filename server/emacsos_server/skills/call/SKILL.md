---
name: call
description: "Place a phone call — 'call 415-555-0123', 'call Ana', 'phone the plumber from last week', 'dial Mom'. The target may be a literal number, a contact name, or a description of someone in the user's notes. Load this whenever the user wants to call/phone/dial."
---

# Place a call

Your job is the *interpretive* part — turn what the user said into one concrete
phone number — then hand it to the deterministic `emacos-call` command. You
work through `eval_elisp`: **evaluate elisp to SEARCH for the number, then
invoke the `emacos-call` command to DIAL.** Stay on the call task.

## 1. Did the user already give a number? Use it.

If the request contains a phone number (a run of digits, possibly with `+`,
spaces, dashes, or parens — e.g. "call 415-555-0123"), that IS the target.
Strip the separators to digits with an optional leading `+`, prefer E.164
(add the country code if clearly implied), and skip straight to confirm (§3).
No search.

## 2. Otherwise, find the number (`eval_elisp` search)

The target is a person or a description ("Ana", "the plumber from last week").
**There is no fixed contacts file** — names and numbers live wherever the user
keeps notes. So first *discover* where to look, then search.

Search principles (apply them, don't just copy a command):
- **Pick a distinctive term** — the name, or a keyword from the description
  ("plumber"). Search a LITERAL, shell-quoted string (`shell-quote-argument`
  prevents injection; `grep -F` avoids regex surprises).
- **Grep WITH CONTEXT** (`-A`/`-B`) — the number may be on a line near the
  mention, not always on the matched line itself.
- **CAP the output** (`-m` per file, `| head -c` total) so a common term can't
  dump unrelated personal data into the result.
- **Search multiple directories** — the likely note locations, not one fixed
  path.

First, list the home directory and pick the likely places notes/contacts could
live (a notes or org dir, a contacts file, a documents dir, …):

```elisp
(shell-command-to-string "ls -p ~ 2>/dev/null")
```

Then grep the few promising candidates together — with context, capped — where
CANDIDATES is the space-separated paths you chose from that listing:

```elisp
(shell-command-to-string
 (concat "grep -rinF -m 5 -A4 -B2 -- " (shell-quote-argument TERM)
         " " CANDIDATES " 2>/dev/null | head -c 3000"))
```

If that finds nothing, widen — search the whole home dir but restrict to
text/notes files (keeps it fast and avoids binaries), or retry with a looser
term (a last name, the business type):

```elisp
(shell-command-to-string
 (concat "grep -rinF -m 5 -A4 -B2 --include=*.org --include=*.md --include=*.txt -- "
         (shell-quote-argument TERM) " ~ 2>/dev/null | head -c 3000"))
```

From the matched block, take the phone number (digits, optional leading `+`).

- **No match anywhere** → tell the user you couldn't find a number for them and
  STOP. Never invent a number, never dial.
- **More than one plausible match** → list them and ask which. STOP — don't
  guess.

## 3. Confirm before dialing (MANDATORY)

Confirmation is YOUR job, not the command's — `emacos-call` just dials. State
exactly who/what and the number ("Call the plumber at +1 415 555 0123?") and
wait for the user to say yes. Only then continue.

## 4. Dial — invoke the deterministic command (`eval_elisp`)

Evaluate `emacos-call` with the resolved number (a NUMBER, never a name). It's
a plain emacs command that dials the modem and returns a status string:

```elisp
(emacos-call "+14155550123")
```

- `"dialing: <call-path>"` → ringing; tell the user it's dialing.
- `"error: ..."` (no modem / not registered / invalid number) → surface the
  reason; do not retry blindly.

## 5. Hang up (on request)

```elisp
(emacos-hang-up)
```

Returns `"hung-up: ..."` or `"error: ..."`.

## Rules

- `emacos-call` takes a phone NUMBER. Resolve it first — from the request
  (§1) or the files (§2) — never pass a name or description.
- Search by *evaluating elisp* (`grep` via `shell-command-to-string`); dial by
  *invoking the command* (`emacos-call`). That split is the point.
- Never fabricate a number. If you can't find it, say so.
- Always confirm the specific target + number before dialing.
- Just read enough to find the number; keep other contacts' data out of the
  result (the caps above).
