# CLAUDE.md

Guidance for Claude Code working in this repository. The tool-agnostic guide (project
overview, three-phase workflow, Layers model, phone-UX conventions, live infra) lives in
`AGENTS.md`, imported here so it loads alongside this file and so Codex (which reads
`AGENTS.md`) picks up the same guidance:

@AGENTS.md

EmacsOS is a malleable, agent-customizable, local-first operating system built on Emacs for small touchscreen devices.  Two surfaces matter most: the **phone client** (elisp — `os.el`, `chat.el`, friends, plus the dockerized phone simulator under `server/simulation/`) and **`emacsos-server`** (Python + FastAPI under `server/`, the HTTP gateway between the phone and the [`assist`](https://github.com/pierrel/assist) agent).

## Three-phase development workflow

Non-trivial changes follow a **design phase**, a **coding phase**, and a **review phase**.  Each phase has a named subagent team.  The point is to (1) separate "what should we build" from "build it" so the design has a chance to be wrong cheaply, (2) give the implementation a clear contract to satisfy, and (3) surface anything reviewers (including automated ones like GitHub Copilot) flag once the diff is real.

This applies to: anything touching `chat.el`, `os.el`, the wire protocol between phone and server, `emacsos_server/app.py`, the phone simulator (`server/simulation/`), or how assist is loaded.  It also applies to deploy/install plumbing (`Makefile`'s `phone-install` / `local-deploy` targets, `deploy/`).

It does NOT apply to: trivial fixes, doc edits, single-file refactors with no behavior change.

### Phase 1 — Design

Spawn the design team via the `Agent` tool **before writing any code**.

| Role | Subagent type | Responsibility |
| --- | --- | --- |
| **Architect** | `Plan` | Owns the implementation plan.  Reads the affected modules, names the files to touch, calls out the trade-offs, and lists risks/edge cases.  Output is a numbered plan with file:line references. |
| **Investigator** *(optional)* | `Explore` | When the architect needs more codebase grounding than they can do solo — finds prior patterns, locates similar plumbing, surveys existing tests/fixtures.  Spawn only if the plan needs concrete file references the architect doesn't yet have. |
| **Researcher** *(optional)* | `general-purpose` | When the design depends on external info (Emacs API behavior, url-http internals, FastAPI / Starlette nuances, LangChain / `deepagents` patterns when the change touches how assist is wired in).  Skip when the question is purely internal. |

**The architect produces a written plan; the main Claude (you) reads it, redirects if anything looks wrong, then runs the design-review team below.**  Do not skip the redirect step — design agents have no memory of the user's prior corrections, so they can re-introduce mistakes the user has already pushed back on.  If the plan conflicts with `auto-memory feedback` or session context, fix the plan before review.

**Design-review team.**  Before handing off to coding, spawn these reviewers (each `general-purpose`, in parallel) and brief each on the plan + their specific lens.  You read every report and revise the plan where reviewers' feedback is well-founded; push back in your own notes when it isn't.

| Lens | What to brief the reviewer to look for |
| --- | --- |
| **Simplicity** | Is the simplest design that meets the requirements?  Are there layers, abstractions, or knobs the requirements don't justify?  Would a smaller change cover the same ground? |
| **Agentic best practices** | Does the design align with current LangChain / LangGraph / `deepagents` patterns where relevant (assist-side: middleware composition, tool surface; emacsos-side: how the phone's chat surface composes with assist's agent stream)?  Anything that fights the framework rather than working with it? |
| **User guidance & intention** | Does the plan match what the user actually asked for (and the spirit behind it)?  Does it respect prior corrections from `auto-memory feedback` and session context?  Does it introduce work the user didn't ask for?  Does it respect the phone-shaped UX constraints (320x240, T9 keyboard, single-buffer focus)? |
| **Clean interfaces** | Are the new module/function boundaries cohesive?  Are responsibilities well-separated between phone (`chat.el`, `os.el`) and server (`emacsos_server/`)?  Is the wire protocol between them small and obvious?  Are names accurate? |
| **Threat model / attack surface** *(propose the security challenges BEFORE any code — heavier when the change adds a network listener, runs as root, handles untrusted input, or shells out to `mmcli`/system tools)* | Enumerate what the design newly exposes and how it's contained, at design time: every untrusted input (an inbound SMS, a request body, an AT/`mmcli` arg) and the sink it reaches (shell/`mmcli`/path); authn/authz on any new endpoint; resource bounds (body size, read length, connection timeouts, poll/retry caps); the bind exposure of a new listener (a root daemon on `0.0.0.0`); where secrets live (never argv/logs/tracked — flow via env/stdin). Prefer containment by construction over a steerable guard. The design doc records the surface + mitigations so Phase-2's adversarial-security reviewer has a spec to test against. |

The architect (or the main Claude when revising the plan directly) treats the reviewers as advisors, not gates: address what's right, justify what isn't.  Document any rejected suggestions briefly in the plan so the rationale survives into Phase 2.

### Phase 2 — Coding

The main Claude (you) writes the code, runs the tests + smoke, and ships.  The code-review team is a peer-review gate before pushing.

| Role | Subagent type | Responsibility |
| --- | --- | --- |
| **Implementer** | (you, the main Claude) | Writes the edits using `Edit` / `Write` against the design from Phase 1.  Runs ERT (`make test-elisp`), pytest (`make test-server`), and — when wire shape or boot order changed — the dockerized smoke (`make smoke`). |
| **Re-tester** | (you, the main Claude) | After fixing review findings, re-runs the relevant tests + smoke to confirm no regression. |

**Code-review team.**  Once the first complete implementation exists (ERT + pytest pass, no obvious regressions), spawn these reviewers (each `general-purpose`, in parallel) and brief each on the uncommitted diff + their specific lens.  You read every report, fix what's well-founded, and push back where it isn't.

| Lens | What to brief the reviewer to look for |
| --- | --- |
| **Simplicity** | Is the implementation as small as it can be while still satisfying the design?  Dead branches?  Premature abstractions?  Knobs nobody asked for? |
| **Clean code** | Naming, function size, layering, error handling.  Bugs, missing edge cases, leaks, race conditions.  For elisp: marker insertion-types, buffer-local vs global state, read-only text properties.  For server: async / executor boundaries, lock pairing, generator cleanup. |
| **Adversarial security** *(mandatory; run HARD for new network/root/untrusted-input-facing code, ideally a dedicated pass)* | Don't check that validation "looks present" — *try to break it*, testing the design doc's threat model.  Attacker-controlled value → a sink (shell/`mmcli`/path); an unauthenticated or under-authorized endpoint; resource exhaustion (unbounded body/read, slowloris, a cap with a negative/overflow bypass); a root listener's bind exposure; a secret leaking to argv/logs/tracked files.  **Why heavier here:** the `sms-forward` root daemon passed the full local loop, then took 7 Copilot rounds of *real* hardening (slowloris timeout, body-cap + its negative-`Content-Length` bypass, bind config, injection) — that gap is what this lens closes.  Confirm each Phase-1 mitigation is present and by-construction. |
| **Readability** | Can someone reading this fresh in three months understand what it does and why?  Where are the load-bearing comments missing?  Where are comments restating obvious code? |
| **Existing patterns** | Does this follow conventions already established elsewhere in the repo (page-rendering style in `os.el`, the back-channel mechanism in `phone.py`, the way wire events are encoded in `stream.py`)?  Is it reinventing something we already have? |
| **Design adherence** | Does the diff implement what the Phase-1 plan committed to?  Are deviations called out and justified, or did they slip in unannounced? |
| **Refactoring opportunities** | Is there code outside the diff that this change makes easier to simplify?  Note them — but do NOT widen the scope of this PR unless the user asks. |

Each reviewer should return a numbered findings list with severity (BLOCKER / IMPORTANT / NIT) and a "ship it" or "block on these N items" bottom line.  Fix BLOCKER and IMPORTANT items, then re-run the relevant tests.

### Phase 3 — Review (GitHub Copilot iteration)

After Phase 2, push the branch and verify CI passes.  Then run a GitHub Copilot review loop.

**Setup.**  Open the PR (or push to an existing one).  If CI doesn't pass first, fix that before requesting Copilot — there's no point reviewing a broken build.

**Requesting a Copilot review** (the magic incantation — Copilot is a Bot reviewer and the regular `--add-reviewer copilot-pull-request-reviewer` form is rejected with "not a collaborator"; the working form is the `@`-prefixed alias):

```bash
gh pr edit <PR#> --add-reviewer "@copilot"
gh api repos/<owner>/<repo>/pulls/<PR#>/requested_reviewers --jq '.users[] | {login, type}'
# confirm Copilot (login "Copilot", type "Bot") is queued
```

A push to an existing PR may auto-trigger a Copilot review even without an explicit re-request — check the queue before re-requesting redundantly.

**Iteration loop.**  Per round:

1. Wait ~10 minutes for Copilot to post the review (use `ScheduleWakeup` with `delaySeconds: 660-720` so the harness re-invokes you when it's time; don't poll).
2. Fetch the review and inline comments:
   ```bash
   gh api repos/<owner>/<repo>/pulls/<PR#>/comments
   ```
   Filter to the head commit's comments to see the latest round only.
3. Triage each comment with opinions:
   - **Address it** if the concern is real and aligned with the design — fix the code, push, move on.
   - **Push back** if it's a false positive, already-addressed, or it would push the implementation away from the Phase-1 design.  Stick to the design — Copilot has no context for the trade-offs your design team weighed.
   - Watch for **re-flagged false positives**: Copilot frequently keeps the same backlog of "concerns" across rounds even after the code addresses them.  Verify in the current file (`grep -n` on the named identifier) and don't re-fix.
4. After fixing, push and re-request Copilot for the next round.
5. **Resolve & reply** to comments before moving on:
   - For comments that are addressed in code, resolve the conversation thread (GraphQL `resolveReviewThread`) so the PR view stays clean.
   - For comments you're declining (false positive, scope, design-aligned trade-off), post a short reply on the thread (`POST /repos/<owner>/<repo>/pulls/<PR#>/comments/<comment_id>/replies`) explaining the rationale, then resolve.

**Cap: 7 iterations.**  Copilot review converges asymptotically, not absolutely — once you've passed ~6 rounds, expect mostly re-flagged items with diminishing-returns new findings.  Stop after round 7 regardless of state.

**After the loop, update the PR description.**  If the review surfaced anything that warrants a *design* change (not just a code fix) — a new edge case the design didn't account for, a contract that needs to be tightened, a follow-up explicitly accepted as a v1 trade-off — call it out in the PR description under a "Design changes from review" or "Known limitations" section.  Code comments alone aren't enough; the PR description is what humans read at merge time.

**Useful GraphQL for resolving threads:**

```bash
# List unresolved review threads on a PR
gh api graphql -f query='
  query { repository(owner:"<owner>", name:"<repo>") {
    pullRequest(number: <PR#>) {
      reviewThreads(first: 50) { nodes {
        id isResolved comments(first: 5) { nodes { body path line author { login } } }
      } } } } }'

# Resolve one
gh api graphql -f query='
  mutation { resolveReviewThread(input: { threadId: "<THREAD_ID>" }) {
    thread { isResolved } } }'
```

## Branching strategy

Standard feature-branch flow.  Default to it for any non-trivial change.

1. **Branch off `main` per feature.**  Pick a short, kebab-case name that describes the change (verb-led when natural — `streaming-responses`, `assist-pyproject-cleanup`, `chat-button-sizing-and-roadmap`).  Avoid umbrella names that don't say what's actually being done.

   **Always branch off `main` — never off another feature branch.**  Stacked PRs entangle two unrelated changes in one diff: the reviewer can't tell which lines belong to which feature, and merging one rebases the other.  If your work depends on an unmerged branch, *wait for it to merge* (or ask the user to merge it) before starting yours.

2. **Commit on the feature branch.**  Multiple commits per logically distinct change are fine; the user reviews the final diff at PR time.  Make a NEW commit, never amend.  Push as work progresses (`git push -u origin <branch>`) so the history survives a clone loss.

3. **Merge to `main` when the branch is ready.**  "Ready" means: all three phases of the Three-phase development workflow above are complete (design + design-review team feedback considered, code + code-review team findings addressed, Copilot review iteration converged or capped), `make test-elisp` and `make test-server` pass, and the smoke passes (`ASSIST_MODEL_URL=... make smoke`) when the change touches the wire protocol or boot path.  Prefer fast-forward merges (`git merge --ff-only <branch>`) so `main` stays linear; rebase if the branch has diverged.

4. **Phone deploy from a feature branch is OK — but understand the trade-off.**  `make phone-install` / `make local-deploy` work from any branch.  But deploying a *second* feature branch overwrites the first on the phone — `scp` doesn't preserve unrelated changes from a previous deploy.  If multiple unmerged features need to be live on the phone simultaneously, merge the older one to `main` first so the newer feature branch can rebase onto it.

5. **Keep feature branches around briefly after merge.**  Don't immediately delete the local or remote branch — they're useful if a follow-up question or quick revert is needed.  Garden them out periodically.

Direct commits to `main` are reserved for trivial fixes (typo, doc tweak) that wouldn't benefit from review.  Anything touching `chat.el`, `os.el`, `emacsos_server/`, the wire protocol, or deploy plumbing goes through a feature branch.

## Project conventions

- **Layers: deterministic emacs primitives + an interpretive agent (read README "Layers").**  Everything the device *does* is an emacs interactive command, and the dividing line is *determinism*.  Emacs commands are **deterministic primitives** — concrete arg in, same action out, no model in the loop, no callback into the agent (e.g. `(emacos-call "+14155550123")` just dials).  The **agent is the interpretive layer**: turning fuzzy intent ("call Ana") into a concrete primitive call — resolution, disambiguation, confirmation — is the agent's job and lives in a **skill**, never in the primitive.  So build a feature as *a deterministic command (shared by user taps and agent elisp) + a skill that resolves intent down to that command's args*.  Skills don't add bespoke server tools; they direct the agent to evaluate elisp (initiate a command, or define+persist new functionality).  Agent-platform services that aren't device control (the model, conversation memory, config git-versioning/rollback) stay server-side.
- **Commits to feature branches don't need explicit confirmation; commits to `main` do.**  On a feature branch, commit and push as the work progresses — the user reviews the diff at PR time, not before each commit.  Direct commits to `main` (or anything that lands on `main` without going through a PR + review) still require the user's explicit go-ahead.
- **No new docs unless asked.**  Don't write tutorial docs, design docs, or README sections that weren't requested.  Design docs for a *specific feature* (under `docs/`) are fine when the feature is non-trivial — mirror the existing format (`docs/2026-05-17-streaming-responses.org` is a good template).
- **The phone is the user.**  Every UI decision happens on a 320x240 screen with a T9 keyboard.  Default to fewer buttons, larger hit targets, less text on screen.  When in doubt, test on the phone (or the dockerized simulator) rather than reasoning from desktop intuitions.
- **Real-phone smoke after refactors that touch the boot path.**  Unit tests don't catch entry-point regressions — the `manage.web` package split crash-looped systemd until `__main__.py` was added (this is an assist incident, but the principle applies to emacsos boot too).  After a layout refactor, run `make smoke` and, if the change touches `os.el` or `chat.el`, deploy to the phone (`make local-deploy`) and exercise the affected page by hand.
- **assist is a sibling checkout, not a PyPI package.**  The `Makefile` installs assist editably from `$(ASSIST_REPO_DIR)` (default `../assist`) with `pip install -e ../assist -c ../assist/requirements.txt` — the constraints flag pins versions without pulling in assist's dev tooling.  When bumping assist: `cd ../assist && git pull && cd ../emacsos && rm -rf server/.venv && make setup-server`.
- **No real local paths in tracked files.**  Don't commit `/home/<user>/...`, real IPs/hostnames, or absolute paths from your machine — they leak operator identity, deploy topology, and (for shared repos) the existence of internal hosts.  Operator-specific paths flow through env vars and Makefile variables (`PHONE_EMACSOS_DIR`, `PHONE_INIT_SNIPPET`, `DEV_BOX_URL`, `ASSIST_REPO_DIR`).  Before committing: `git ls-files | xargs grep -nE "/home/[a-z]+|/Users/[a-z]+|192\.168\."` should return nothing.
