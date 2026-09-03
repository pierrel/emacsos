---
name: config-apply
description: "Change the user's persistent emacs configuration — cursor color or shape, fonts, theme, keybindings, or anything they want kept after a restart; also undo or revert a config change, or restore an earlier version. Load this before any eval_elisp, apply_config, config_history, or revert_config call so the change is verified live and then saved completely, and so undo requests use the git-backed revert."
---

# Config-apply: verify live, then persist

The user wants to change their emacs configuration and keep it (cursor,
fonts, theme, keybindings — anything that should survive a restart).
Follow this two-step workflow. Stay on the requested change; do not go
exploring unrelated emacs state.

## 1. Verify the change live (`eval_elisp`)

- Apply the change to the running emacs with `eval_elisp`, then read back
  the value you just set to confirm it took effect.
- Probe ONLY what you're changing. Do NOT evaluate `load-path`,
  `(getenv ...)`, `after-init-time`, package internals, or open the init
  file unless the request is specifically about those — that is wandering,
  not verifying, and wastes the turn.

## 2. Persist it (`apply_config`)

- Once it's verified, call `apply_config` with the COMPLETE configuration.
  `apply_config` REPLACES the whole config file — anything you leave out
  is gone after the next restart.
- If the user already has config, you MUST read it first with `get_config`
  before calling `apply_config`, then restate ALL of it plus your change.
  `get_config` returns the last server-recorded config body. Build on that,
  not on whatever was said earlier in the conversation (that may be stale, or
  gone after a New chat). Fold your change into the body it returns and send
  the full replacement. Exception: after an unconfirmed or unrecorded config
  result, stop persistent config work and surface the need to reconcile the
  phone file with history before treating `get_config` as authoritative.
- Persist the DURABLE form, not a one-shot interactive call — usually via
  `default-frame-alist`, `custom-set-variables`, `setq`, or a mode hook.

## Idioms for common requests

Use these as the shape; adapt to whatever the user actually asked for.

- **Cursor color** — live: `(set-cursor-color "COLOR")`; persist:
  `(add-to-list 'default-frame-alist '(cursor-color . "COLOR"))`.
- **Cursor shape** — frame parameter `cursor-type`: `box`, `bar`,
  `(bar . N)` for an N-pixel-wide bar, `hbar`, `(hbar . N)`. Live:
  `(set-frame-parameter nil 'cursor-type '(bar . 3))`; persist via
  `default-frame-alist`.
- **Cursor blinking** — `(blink-cursor-mode 1)` / `(blink-cursor-mode -1)`;
  persist by putting that call in the config.
- **Default font size** — `(set-face-attribute 'default nil :height 140)`
  (height is in 1/10 pt); persist the same call in the config.

For settings not listed here, the same principle holds: find the durable
variable / frame parameter / mode, verify it live, then persist the full
config.

## Undo / revert a change (`revert_config`, `config_history`)

When the user wants to undo a config change ("undo that", "never mind", "put it
back the way it was"), use `revert_config` — do NOT hand-reconstruct and
re-apply the old config from memory.

- To undo the LAST applied change, call `revert_config` with no `target` (the
  default). It writes the prior config to the phone, then records the git
  revert only after that write is confirmed.
- To go back FURTHER ("go back to before the modeline edits"), call
  `config_history` first — it lists recent versions as `<short-sha>  <summary>`,
  newest first — then call `revert_config` with the matching short-sha as
  `target` to restore that version. Pick the sha from history; don't guess it.

The revert is itself recorded, so the user can undo the undo. If `revert_config`
returns `nothing to roll back`, there's no saved change to undo — tell the user.
`reverted-but-broken:` / `restored-but-broken:` means the file was written but
loading or platform finalization errored —
inspect the reported failure. Offer a corrected config or another version only
for a config-load failure; surface a platform-finalization failure as an operator
problem. `reverted-but-unrecorded:` means the phone was written but the undo
commit failed; its result says retrying is safe because history is unchanged.
`restored-but-unrecorded:` means the phone was written but the restore commit
failed; do not retry it. Tell the user the activation and recording outcomes,
and do no further persistent config work before reconciliation.

## When a tool reports a problem

- `eval_elisp` returns `error:` — do NOT retry the same expression; fix the
  elisp or tell the user.
- `apply_config` returns `applied-but-broken` or `applied-but-unrecorded` —
  follow the guidance in that result. For `applied-but-broken`, distinguish a
  config-load failure from a platform-finalization failure before suggesting a
  rollback or corrected config. Do not blindly re-apply the same thing.
- `apply_config` returns `error: config application unconfirmed:` — the server
  could not prove whether the atomic phone-side write completed and did not
  commit it. Surface that uncertainty; do not claim the config is live or
  absent, and stop persistent config work until the phone file and history are
  reconciled.
- `get_config` returns `empty:` — there is no saved config yet; just send a
  complete config with `apply_config`. It returns `error:` — the saved
  config can't be read; tell the user rather than retrying.
