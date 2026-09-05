---
name: call
description: "Place a phone call — 'call 415-555-0123', 'call Ana', 'phone the plumber from last week', 'dial Mom'. The target may be a literal number, a contact name, or a description of someone in the user's notes. Load this whenever the user wants to call/phone/dial."
---

# Place a call

Your job is the *interpretive* part — turn what the user said into one concrete
phone number — then hand it to the deterministic `emacos-call` proposal
command. You work through `eval_elisp`: **evaluate elisp to SEARCH for the
number, then invoke `emacos-call` to SHOW the phone's local confirmation
surface.** Stay on the call task.

## 1. Did the user already give a number? Use it.

If the request contains a phone number (a run of digits, possibly with `+`,
spaces, dashes, or parens — e.g. "call 415-555-0123"), that IS the target.
Strip the separators to digits with an optional leading `+`, prefer E.164
(add the country code if clearly implied), and skip straight to staging (§3).
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
CANDIDATES is a Lisp list of the paths you chose from that listing:

```elisp
(let ((candidates '("~/contacts" "~/notes")))
  (shell-command-to-string
   (concat "grep -rinF -m 5 -A4 -B2 -- " (shell-quote-argument TERM)
           " " (mapconcat (lambda (path)
                            (shell-quote-argument (expand-file-name path)))
                          candidates " ")
           " 2>/dev/null | head -c 3000")))
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

## 3. Stage the phone confirmation (`eval_elisp`)

Evaluate `emacos-call` with the resolved number (a NUMBER, never a name). It
does not dial. It shows the number on the phone with a local two-tap Call
control:

```elisp
(emacos-call "+14155550123")
```

- `"confirmation-required: confirm on phone"` → tell the user the target is
  ready and they should tap Call, then Confirm call, on the phone. STOP. The
  actual dial is a later local UI action, not another agent step.
- `"error: call already in progress"` → tell the user a call or dial attempt is
  already active. Do not replace it.
- another `"error: ..."` → surface the reason; do not retry blindly.

Do not ask for a conversational "yes" as authorization. A chat reply cannot
substitute for the phone's two local control activations. Never call a private
transport function, the platform backend, the root helper, or either tap
handler, and never synthesize the confirmation actions.

## 4. Hang up (on request)

```elisp
(emacos-hang-up)
```

On the PinePhone this returns `"pending: hangup requested"` once the bounded
helper starts; the phone shows `Ending call…` until its terminal success or
failure arrives, then restores recovery controls on failure unless the carrier
has independently reported that the call ended. A synchronous
transport returns `"hung-up: ..."` or `"error: ..."` directly.

## Rules

- `emacos-call` takes a phone NUMBER. Resolve it first — from the request
  (§1) or the files (§2) — never pass a name or description.
- Search by *evaluating elisp* (`grep` via `shell-command-to-string`); stage the
  local proposal by invoking `emacos-call`. That split is the point.
- Never fabricate a number. If you can't find it, say so.
- Never claim the phone is dialing from `emacos-call`'s confirmation-required
  result. The user-visible phone state is the authority.
- Just read enough to find the number; keep other contacts' data out of the
  result (the caps above).
