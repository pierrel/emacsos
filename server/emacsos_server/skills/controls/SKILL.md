---
name: controls
description: "Control the phone's cellular data, screen brightness, or flashlight. Load for requests such as 'turn mobile data off', 'dim the screen', 'set brightness to 75%', or 'turn on the flashlight'."
---

# Phone controls

Resolve the request to one explicit state, then use `eval_elisp` to invoke the
matching public deterministic command. Never call a private function, the
platform backend, a root helper, or a shell command.

## Cellular data

Use an explicit boolean. Ordinarily this changes only the named NetworkManager
data profile; it does not power off the modem or disable call and SMS
registration. If cellular-on finds the observed stale state where
ModemManager has no modem object, the same authorized action performs one
bounded fixed-service recovery before activating the profile. Do not retry a
failed or timed-out request blindly.

```elisp
(emacsos-net-set-cell t)
(emacsos-net-set-cell nil)
```

## Brightness

Brightness accepts only 25, 50, 75, or 100. For a relative request, choose the
next value in that fixed set. If the current level is needed to resolve “dim”
or “brighter”, evaluate `emacsos-pinephone-controls-brightness` first and stop
and report brightness as unavailable if it is nil. Never choose zero or an
arbitrary value.

```elisp
(emacsos-controls-set-brightness 50)
```

## Flashlight

Use the explicit symbol `on` or `off`.

```elisp
(emacsos-controls-set-flashlight 'on)
(emacsos-controls-set-flashlight 'off)
```

`pending: ...` means the asynchronous operation started. Report that
it is pending, not complete. `error: ...` means it did not start; surface the
reason and do not retry blindly. The phone's Controls row is authoritative for
terminal success or failure. Brightness and flashlight run through a bounded
five-second root helper.
