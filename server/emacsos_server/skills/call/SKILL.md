---
name: call
description: "Place a phone call to a person by name — 'call Ana', 'phone Sam', 'dial Mom'. Look up the contact's number on the phone's filesystem and dial it via the modem. Load this whenever the user wants to call/phone/dial someone by name."
---

# Call a contact by name

The user wants to call someone by name. You look up their number in the
contact files on the phone, confirm with the user, then dial. Everything
runs on the phone via `eval_elisp` (shelling out to the filesystem and the
modem). Stay on the call task; do not wander into other emacs state.

## 1. Find the contact's number (`eval_elisp`)

Contacts live in plain files on the phone — by default
`~/.emacs.d/emacsos/contacts.org`, plus anything under
`~/.emacs.d/emacsos/contacts/`. Each entry is a name with a phone number
near it. Search for the requested name with `eval_elisp`, e.g.:

```elisp
(shell-command-to-string
 "grep -rinE -A2 'NAME' ~/.emacs.d/emacsos/contacts.org ~/.emacs.d/emacsos/contacts/ 2>/dev/null")
```

From the matching block, take the phone number — the digits (with optional
leading `+`) on or just after the name line. Prefer an E.164 number (leading
`+` and country code).

- **No match** → tell the user "No contact named X" and STOP. Do NOT invent a
  number. Do NOT dial.
- **More than one match** → list the matches and ask which one. STOP — do not
  guess.

## 2. Confirm before dialing (MANDATORY)

Never dial in the same step you found the number. State exactly who and what
number you are about to call ("Call Ana at +1 415 555 0123?") and wait for the
user to confirm. Only continue after they say yes.

## 3. Dial (`eval_elisp` → the place_call script)

Once confirmed, dial by running the `place_call` script on the phone with the
resolved number (a NUMBER, never a name):

```elisp
(shell-command-to-string "bash ~/.emacs.d/emacsos/place_call.sh '+14155550123'")
```

- `dialing: <call-path>` → the call is ringing; tell the user it's dialing.
- `error: no modem found` / `error: dial failed (modem not registered?)` /
  `error: invalid number: ...` → surface the reason to the user; do NOT retry
  blindly with the same input.

## 4. Hang up (on request)

When the user asks to hang up / end the call:

```elisp
(shell-command-to-string "bash ~/.emacs.d/emacsos/hangup.sh")
```

Reports `hung-up:` or `error:`.

## Rules

- `place_call.sh` takes a phone NUMBER, never a name — you MUST resolve the
  number from the contact files first.
- Never fabricate a number. If you can't find it, say so.
- Always confirm the specific name + number with the user before dialing.
- The contact files are private to the user's phone; just read them to find
  the number, don't copy their contents elsewhere.
