---
name: sms
description: "Prepare a text message on the phone — 'text Ana that I am running late', 'send an SMS to 415-555-0123', 'message the plumber'. Load whenever the user wants to text, message, or send an SMS to a person or number."
---

# Prepare an SMS

Resolve the user's intent to one concrete phone number and exact message body,
then use `eval_elisp` to invoke the deterministic `emacsos-send-message`
proposal command. It shows the complete message on the phone. It does not send.

## Resolve the number

If the user supplied a number, strip spaces, dashes, and parentheses, retain an
optional leading `+`, and prefer E.164 when the country code is clear.

Otherwise search the phone's files with bounded, literal queries through
`eval_elisp`, following the same contact-search discipline as the `call` skill:
list likely home-directory locations, grep only a few text/note candidates with
context and capped output, and widen only if needed. Never invent a number. If
no number is found, say so and stop. If multiple plausible numbers remain, ask
which one and stop.

## Stage the exact proposal

Invoke the public command with the concrete number and the exact requested
message body:

```elisp
(emacsos-send-message "+14155550123" "I am running ten minutes late.")
```

Encode a Lisp string correctly: escape each backslash as `\\`, each double
quote as `\"`, and a requested line break as `\n`. Do not paraphrase,
normalize punctuation, replace quote characters, append a signature, or add
content the user did not request.

- `confirmation-required: confirm on phone` means the proposal is visible.
  Tell the user to inspect it and tap Send, then Confirm send?, on the phone.
  Stop.
- `error: ...` means staging failed. Surface the reason and do not retry blindly.

Never invoke a private `emacsos-sms--...` function, the platform operation
function, the root helper, or either tap handler. Never synthesize confirmation
actions. A conversational yes is not a tap. Never claim a staged proposal was
sent; only the phone's terminal screen is authoritative.
