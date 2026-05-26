---
name: config-apply
description: "Change the user's persistent emacs configuration — cursor color or shape, fonts, theme, keybindings, or anything they want kept after a restart. Load this before any eval_elisp or apply_config call so the change is verified live and then saved completely."
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
  `get_config` returns the committed config body — the source of truth.
  Build on that, not on whatever was said earlier in the conversation (that
  may be stale, or gone after a New chat). Fold your change into the body it
  returns and send the full replacement.
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

## When a tool reports a problem

- `eval_elisp` returns `error:` — do NOT retry the same expression; fix the
  elisp or tell the user.
- `apply_config` returns `applied-but-broken` or `applied-but-unrecorded` —
  follow the guidance in that result (suggest a rollback / a corrected
  config); do not blindly re-apply the same thing.
- `get_config` returns `empty:` — there is no saved config yet; just send a
  complete config with `apply_config`. It returns `error:` — the saved
  config can't be read; tell the user rather than retrying.
