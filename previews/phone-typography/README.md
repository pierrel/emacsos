# Phone typography studies

Preview-only work. No product code, phone startup files, persistent agent configuration, defaults, services, or keyboard source are changed.

Open `index.html` in a browser. It works directly from disk with bundled fonts and no remote requests. Eight directions, six views, size/weight/leading/tracking controls, dark/light surfaces, visible/hidden keyboard, and paired baseline comparison. Each phone frame scrolls. Selected controls persist in the URL; Reset restores the starting study. Download links provide seven PNG contact sheets. Eight individual `*-phone.png` images are 720 × 1440 physical-pixel browser approximations.

First visual recommendation: **IBM Plex Sans + IBM Plex Mono**, with **Inter + JetBrains Mono** as the quieter alternative and **Source Sans 3 + Source Code Pro** for reading. Compare regular prose at 18–20 logical pixels, semibold headings, and 1.35–1.45 leading. Keep code fixed-pitch. Manrope is the geometric option, Geist the crisp systematic option, Atkinson Next the distinctive-letterform option, and Source Serif 4 the editorial reading wildcard. This is visual judgment, not evidence from a phone trial.

## Actual-phone specimen, Root delivery only

`phone-specimen.el` defines `emacsos-type-study-show`. It opens **\*Phone font studies\*** containing a tappable index and all eight named directions. Each section includes 12/14/16-point prose, 14-point UI/numbers/ambiguous letters, a 16-point heading, and 13-point monospace code. Scroll normally; `n`/`p` move between font sections and `i` returns to the index. Current theme, global faces, mode line, and external keyboard remain in place. The only styling changes are text properties in this buffer and buffer-local line spacing/wrapping.

`phone-fonts/` contains 19 static TTFs and all parent OFL licenses, about 3.5 MB. The original Droid family is already installed on the phone. Each preview derivative has a unique family (`Phone Type 02` etc.) and visible samples carry the original parent's familiar name. Distinct naming prevents collision with existing fonts and avoids reserved-name reuse after instancing. `phone-fonts/manifest.json` records parent assets, axes, weights, and hashes. These static instances pin text optical sizes, normal width, and exact regular/semibold weights, rather than depending on variable-font selection in PGTK.

Root must stage these assets using the already authorized phone mechanism. Do not broaden credentials or change service ownership to make this preview work. In a shell **as the actual Emacs UI user**, after staging `phone-fonts/` and the Lisp file into a private preview directory:

```sh
font_preview_source=/path/to/staged/phone-fonts
font_preview_dest="${XDG_DATA_HOME:-$HOME/.local/share}/fonts/emacsos-phone-type-study"
mkdir -p "$font_preview_dest"
cp "$font_preview_source"/*.ttf "$font_preview_source"/*-OFL.txt "$font_preview_dest/"
fc-cache -f "$font_preview_dest"
fc-match 'Phone Type 02'
fc-match 'Phone Code 02'
```

These commands add preview fonts only. They do not assign default font families. In the **actual graphical Emacs instance**, using its existing authorized evaluation route:

```elisp
(progn
  (clear-font-cache)
  (load "/path/to/staged/phone-specimen.el" nil t)
  (emacsos-type-study-show))
```

Every intended family and heading weight is checked before the buffer is created. A font lookup resolving to another family, or a semibold lookup resolving to regular, raises an error. Do not waive that error or silently accept fallback. A terminal/batch Emacs cannot establish the graphical font rendering. If Root has no authorized evaluation or install route, keep the assets ready and report the actual access boundary. Phone visibility and user acceptance remain unverified until Root reports them.

Remove the preview buffer with ordinary buffer commands when finished. Root can later remove only the dedicated `emacsos-phone-type-study` font directory and refresh that user's font cache. No automatic cleanup or configuration rewrite is performed here.

## Geometry and baseline evidence

The current OpenRC source configures 720 × 1440 at Sway scale 2, yielding **360 × 720 logical pixels**. The current keyboard launcher passes `-H 300 -L 300`; the browser models a 300-logical-pixel keyboard and a 23-pixel bottom mode line, leaving 397 pixels of content with keyboard visible. These are source-derived dimensions; live Sway geometry and Emacs face metrics were not accessible to Root's SSH identity. The mode-line height, font pixel size, margins, colors, row spacing, and keyboard key geometry in the browser are approximations/proposed styling. Emacs point heights must not be read as exact CSS pixels without its real DPI metrics.

Root observed phone Fontconfig resolving generic monospace to **Droid Sans Mono** and sans-serif to **Droid Sans**. OpenRC requests `Monospace-14` and height 140. Chat enables `variable-pitch-mode`; the actual effective face sizes/families after agent configuration remain unmeasured. The three bundled Droid TTFs were copied from the phone by Root. `font-manifest.json` records their hashes and provenance. The Apache license accompanies them.

The browser's Droid card uses **the same proposed size, spacing, and palette** as the alternatives. It is a family control, not a screenshot or a faithful baseline of the current full UI. The browser holds keyboard lettering at Droid to isolate Emacs text changes. Keyboard visual structure is approximate. The existing UI structure is grounded in `chat.el` (roles, Markdown heading scale, code), `phone-sms-chat.el` (roles, synthetic number, sent suffix), `network.el` (seven-line chooser), and `os.el` (bottom mode line). Broader prose and terminal views are synthetic specimens. The network/UI view explores proportional text; current character-cell button math must remain fixed-pitch until separately addressed in implementation.

## Font provenance

Original fonts and OFL licenses come from the pinned Google Fonts distribution revision in `font-manifest.json`; primary designer/publisher links are on the preview. Parent font files are unmodified. Manrope is the OFL Google Fonts v4 distribution, not the differently licensed current v5 release. Modified static phone derivatives retain every license and use distinct family names. The manifest records hashes for every original asset and license; the phone manifest covers derivatives.

## Checks and reproduction

`checks.json` records browser geometry, working controls, state persistence/reset, six views, baseline A/B, eight loaded font directions, all original asset hashes, zero remote requests, and zero page errors. `capture.mjs` produces seven contact sheets plus eight individual phone-sized images. Browser checks use Chromium with bundled fonts; they do not prove Emacs rendering.

Local Lisp checks: `check-parens`, load in `emacs -Q --batch`, and full-buffer rendering with **font preflight mocked only for the batch rendering check**, verifying eight named sections and unchanged global default attributes. Actual font lookup, semibold selection, physical screen appearance, and visible phone-buffer delivery belong to Root's phone check. The meaningful fixes from local checks were removal of an invalid `(require 'font)` (font functions are built in) and a corrected numeric range-control input in the browser capture harness. No broad product review or product test suite was run because product code is untouched.

Reproduce browser checks using an existing Node/Chromium installation:

```sh
npm install --prefix .tools playwright --no-audit --no-fund
TYPE_STUDY_CHROMIUM=/path/to/chromium node capture.mjs
```

`fetch-fonts.py` downloads the current Google Fonts revision and writes a new manifest; it is not needed to view the pinned artifact. `build-phone-fonts.py` requires FontTools and reproduces static derivatives from the pinned local assets. A rerun may alter generated metadata; preserve the delivered manifests as exact artifact identity.
