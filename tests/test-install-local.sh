#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT HUP INT TERM

destination="$temporary/local \"quoted\"; inert/emacsos"
mkdir -p "$destination"
printf '%s\n' keep >"$destination/sentinel"

make -C "$repo" install-local LOCAL_EMACSOS_DIR="$destination" \
  >"$temporary/install.out"

cmp "$repo/chat.el" "$destination/chat.el"
cmp "$repo/assist-web.el" "$destination/assist-web.el"
[ "$(stat -c '%a' "$destination/chat.el")" = 644 ]
[ "$(stat -c '%a' "$destination/assist-web.el")" = 644 ]
[ "$(cat "$destination/sentinel")" = keep ]
[ "$(find "$destination" -maxdepth 1 -type f -printf '%f\n' | sort | tr '\n' ' ')" = \
  "assist-web.el chat.el sentinel " ]
grep -Fq 'Credentials, certificates, and Emacs configuration were not changed.' \
  "$temporary/install.out"
grep -Fq 'Set emacos-assist-web-api-url to your HTTPS Assist phone API endpoint.' \
  "$temporary/install.out"

if make -C "$repo" install-local LOCAL_EMACSOS_DIR= \
    >"$temporary/empty.out" 2>&1; then
  echo 'install-local accepted an empty LOCAL_EMACSOS_DIR' >&2
  exit 1
fi
grep -Fq 'LOCAL_EMACSOS_DIR must not be empty' "$temporary/empty.out"

mkdir -p "$temporary/home"
INSTALL_DESTINATION="$destination" HOME="$temporary/home" \
  emacs -Q --batch -L "$destination" --eval \
  "(progn
     (require 'assist-web)
     (let ((checks (list (featurep 'chat)
                         (featurep 'assist-web)
                         (commandp 'emacos-assist-web-open-thread)
                         (with-temp-buffer
                           (emacos-assist-web-mode)
                           (eq (key-binding (kbd \"C-c C-a s\"))
                               #'emacos-conversation-send))
                         (equal (file-truename
                                 (symbol-file 'emacos--chat-enable-presentation 'defun))
                                (file-truename
                                 (expand-file-name \"chat.el\"
                                                   (getenv \"INSTALL_DESTINATION\"))))
                         (equal (file-truename
                                 (symbol-file 'emacos-assist-web-open-thread 'defun))
                                (file-truename
                                 (expand-file-name \"assist-web.el\"
                                                   (getenv \"INSTALL_DESTINATION\")))))))
       (unless (seq-every-p #'identity checks)
         (error \"installed Assist thread client failed its load smoke: %S\" checks))))"

echo 'install-local tests passed'
