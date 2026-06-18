---
name: call
description: "Place a phone call to a person by name — 'call Ana', 'phone Sam', 'dial Mom'. Look up the contact's number on the phone's filesystem, confirm, and dial. Load this whenever the user wants to call/phone/dial someone by name."
---

# Call a contact by name

The user wants to call someone by name. Your job is the *interpretive* part —
figure out who they mean and what number to dial — and then hand a concrete
number to the deterministic `emacos-call` command. You act entirely through
`eval_elisp`. Stay on the call task.

## 1. Find the contact's number (`eval_elisp`)

Contacts live in plain files on the phone — by default
`~/.emacs.d/emacsos/contacts.org`, plus anything under
`~/.emacs.d/emacsos/contacts/`. Each entry is a name with a phone number near
it. Search for the requested name:

```elisp
(shell-command-to-string
 "grep -rinE -A2 'NAME' ~/.emacs.d/emacsos/contacts.org ~/.emacs.d/emacsos/contacts/ 2>/dev/null")
```

From the matching block, take the phone number — digits with an optional
leading `+`. Prefer E.164 (leading `+` and country code).

- **No match** → tell the user "No contact named X" and STOP. Never invent a
  number, never dial.
- **More than one match** → list them and ask which. STOP — don't guess.

## 2. Confirm before dialing (MANDATORY)

Confirmation is YOUR job, not the command's — `emacos-call` just dials. State
exactly who and what number ("Call Ana at +1 415 555 0123?") and wait for the
user to confirm. Only continue after they say yes.

## 3. Dial — call the deterministic primitive (`eval_elisp`)

Once confirmed, dial by evaluating `emacos-call` with the resolved number (a
NUMBER, never a name). `emacos-call` is a plain emacs command that dials the
modem and returns a status string:

```elisp
(emacos-call "+14155550123")
```

- `"dialing: <call-path>"` → the call is ringing; tell the user it's dialing.
- `"error: no modem found"` / `"error: dial failed (modem not registered?)"` /
  `"error: invalid number: ..."` → surface the reason; do not retry blindly.

## 4. Hang up (on request)

When the user asks to end the call:

```elisp
(emacos-hang-up)
```

Returns `"hung-up: ..."` or `"error: ..."`.

## Rules

- `emacos-call` takes a phone NUMBER, never a name — you MUST resolve the number
  from the contact files first.
- Never fabricate a number. If you can't find it, say so.
- Always confirm the specific name + number with the user before dialing.
- Just read the contact files to find the number; don't copy their contents
  elsewhere.
