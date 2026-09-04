;;; dtach-shell.el --- Manage dtach shell sessions over SSH  -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; Author: Pierre
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1") (vterm "0.0.2"))
;; Keywords: terminals, processes
;; URL: https://github.com/pierrel/dtach-shell

;;; Commentary:

;; Emacs bindings for managing dtach shell sessions on remote hosts.
;;
;; The main entry point is `dtach-shell', which prompts for a remote host
;; (from ~/.ssh/config by default) and a session name, then opens a vterm
;; buffer connected via SSH to that dtach session.
;;
;; Buffer names follow the convention: *dtach-shell - HOST - SESSION*

;;; Code:

(require 'cl-lib)

(declare-function vterm "vterm" (&optional buffer-name))
(declare-function vterm-send-string "vterm" (string &optional paste-p))
(defvar vterm-min-window-width)
(defvar vterm-kill-buffer-on-exit)
(defvar vterm-shell)
(defvar vterm-mode-map)

(defvar-local dtach-shell--remote-host nil
  "The remote host this dtach-shell vterm buffer is connected to.
Set when the buffer is created; used for directory-tracking context.")

(defvar-local dtach-shell--session-name nil
  "The dtach session name this vterm buffer is connected to.
Set when the buffer is created; used by `dtach-shell-reconnect' to
re-launch ssh with the same parameters after a disconnect.")

(defgroup dtach-shell nil
  "Manage dtach shell sessions on remote hosts."
  :group 'terminals
  :prefix "dtach-shell-")

(defcustom dtach-shell-socket-dir "/tmp"
  "Directory for dtach socket files on remote hosts."
  :type 'string
  :group 'dtach-shell)

(defcustom dtach-shell-socket-prefix "dtach-shell-"
  "Prefix prepended to session names to form socket file names."
  :type 'string
  :group 'dtach-shell)

(defcustom dtach-shell-default-shell "/bin/bash"
  "Shell executable to launch in new dtach sessions."
  :type 'string
  :group 'dtach-shell)

(defcustom dtach-shell-ssh-config-file (expand-file-name "~/.ssh/config")
  "Path to the SSH client configuration file used to discover hosts."
  :type 'file
  :group 'dtach-shell)

(defcustom dtach-shell-min-window-width 1
  "Minimum pty width (in columns) for dtach-shell vterm buffers.
Bound buffer-locally to `vterm-min-window-width'.  vterm's default
of 80 keeps the pty at least 80 columns wide even when the window
is narrower, which causes the remote shell to draw past the visible
area and the window to scroll horizontally.  A small value here
lets the pty track the actual window width."
  :type 'integer
  :group 'dtach-shell)

(defcustom dtach-shell-connection-timeout 10
  "Seconds to wait when connecting to a remote host during session discovery.
If the connection is not established within this time, or if the host
requires interactive authentication, the attempt is aborted and an error
is signalled."
  :type 'integer
  :group 'dtach-shell)


;;; Pure / non-interactive helpers

(defun dtach-shell--parse-ssh-config (&optional config-file)
  "Return a list of host names from the SSH config file.
Uses CONFIG-FILE, falling back to `dtach-shell-ssh-config-file'.
Wildcard patterns (containing * or ?) are excluded."
  (let ((file (or config-file dtach-shell-ssh-config-file))
        hosts)
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (while (re-search-forward
                "^[[:space:]]*Host[[:space:]]+\\([^\n]+\\)" nil t)
          (let ((spec (string-trim (match-string 1))))
            (dolist (token (split-string spec))
              (unless (string-match-p "[*?]" token)
                (push token hosts)))))))
    (nreverse hosts)))

(defun dtach-shell--socket-path (session)
  "Return the absolute remote socket path for SESSION."
  (concat (file-name-as-directory dtach-shell-socket-dir)
          dtach-shell-socket-prefix
          session))

(defun dtach-shell--buffer-name (host session)
  "Return the vterm buffer name for HOST and SESSION."
  (format "*dtach-shell - %s - %s*" host session))

(defun dtach-shell--find-buffer (host session)
  "Return an existing live buffer for HOST and SESSION, or nil."
  (let ((buf (get-buffer (dtach-shell--buffer-name host session))))
    (and (buffer-live-p buf) buf)))

(defun dtach-shell--install-buffer-keybindings ()
  "Install dtach-shell commands in the current dtach-shell buffer.

`C-c d' always opens the host/session prompt.  `C-c S-d' reconnects the
current dtach-shell buffer."
  ;; `local-set-key' would modify the shared `vterm-mode-map', affecting
  ;; every vterm buffer.  Copy it first so these bindings are genuinely
  ;; buffer-local.
  (let ((map (copy-keymap (current-local-map))))
    (define-key map (kbd "C-c S-d") #'dtach-shell-reconnect)
    (define-key map (kbd "C-c d") #'dtach-shell)
    (use-local-map map)))

(defun dtach-shell--clear-legacy-vterm-keybindings ()
  "Remove shared vterm bindings left by older dtach-shell versions.

Versions that used `local-set-key' directly could have installed these
bindings into `vterm-mode-map'."
  (when (boundp 'vterm-mode-map)
    (dolist (key '("C-c d" "C-c S-d"))
      (when (eq (lookup-key vterm-mode-map (kbd key))
                #'dtach-shell-reconnect)
        (define-key vterm-mode-map (kbd key) nil)))))

(with-eval-after-load 'vterm
  (dtach-shell--clear-legacy-vterm-keybindings))

(defun dtach-shell--build-attach-command (host session)
  "Return the shell command string to attach to SESSION on HOST."
  (format "ssh -t -- %s dtach -a %s"
          (shell-quote-argument host)
          (shell-quote-argument (dtach-shell--socket-path session))))

(defun dtach-shell--build-new-session-command (host session)
  "Return the shell command string to create SESSION on HOST."
  (format "ssh -t -- %s dtach -c %s %s"
          (shell-quote-argument host)
          (shell-quote-argument (dtach-shell--socket-path session))
          (shell-quote-argument dtach-shell-default-shell)))

(defun dtach-shell--parse-session-names (ls-output)
  "Parse dtach session names from LS-OUTPUT of the socket directory.
LS-OUTPUT is the raw text produced by listing socket files on the
remote host.  Only files whose base name starts with
`dtach-shell-socket-prefix' are considered."
  (let ((prefix-re (regexp-quote dtach-shell-socket-prefix))
        sessions)
    (dolist (line (split-string ls-output "\n" t))
      (let ((filename (file-name-nondirectory (string-trim line))))
        (when (string-match (concat "^" prefix-re "\\(.+\\)$") filename)
          (push (match-string 1 filename) sessions))))
    (nreverse sessions)))


;;; Buffer lifecycle

(defun dtach-shell--detach-on-kill ()
  "Send the dtach detach character before the vterm buffer is killed.
When a dtach-shell buffer is killed directly (rather than by pressing the
dtach detach key inside the terminal), SSH is terminated abruptly and the
remote sshd kills the dtach process before it can persist.  Sending the
detach character first \\(ASCII 28, C-\\\\\\) tells dtach to detach
gracefully, keeping the session alive so it can be reattached later."
  (when (and (buffer-live-p (current-buffer))
             dtach-shell--remote-host
             (process-live-p (get-buffer-process (current-buffer))))
    (vterm-send-string (char-to-string ?\C-\\))
    (sit-for 0.2)))


;;; Side-effectful helpers (SSH, vterm)

(defun dtach-shell--get-remote-sessions (host)
  "Query HOST via SSH and return a list of existing dtach session names.
Uses BatchMode=yes so that hosts requiring interactive authentication fail
immediately rather than hanging.  The connection attempt is bounded by
`dtach-shell-connection-timeout'.
Signals an error if the SSH connection cannot be established."
  ;; Pin `default-directory' to a local path so the SSH client always
  ;; runs locally — when called from a buffer whose default-directory
  ;; is a TRAMP path, the inherited cwd would otherwise leak into
  ;; process startup and (in the case of vterm) cause the command to
  ;; run on the wrong host entirely.
  (let* ((default-directory temporary-file-directory)
         (remote-cmd
          (format "find %s -maxdepth 1 -name %s -type s 2>/dev/null"
                  (shell-quote-argument dtach-shell-socket-dir)
                  (shell-quote-argument
                   (concat dtach-shell-socket-prefix "*"))))
         (buf (generate-new-buffer " *dtach-shell-discovery*"))
         exit-code)
    (unwind-protect
        (progn
          (message "Connecting to %s..." host)
          (setq exit-code
                (call-process "ssh" nil buf nil
                              "-o" (format "ConnectTimeout=%d"
                                           dtach-shell-connection-timeout)
                              "-o" "BatchMode=yes"
                              "--"
                              host remote-cmd))
          (if (zerop exit-code)
              (let ((sessions (dtach-shell--parse-session-names
                               (with-current-buffer buf (buffer-string)))))
                (if sessions
                    (message "Found %d session(s) on %s: %s"
                             (length sessions) host
                             (mapconcat #'identity sessions ", "))
                  (message "No existing sessions on %s." host))
                sessions)
            (error "Cannot connect to %s (ssh exited with code %d%s)"
                   host exit-code
                   (if (= exit-code 255)
                       " — check that key-based auth is set up; BatchMode=yes \
is used during discovery so interactive prompts are not supported"
                     ""))))
      (kill-buffer buf))))

(defun dtach-shell--open-vterm (host session command)
  "Open (or switch to) a vterm buffer for HOST and SESSION running COMMAND.
COMMAND is passed to vterm via `vterm-shell'.

For new buffers, `default-directory' is initialised to a TRAMP path for HOST
so that `find-file' and other commands operate on the remote filesystem from
the start.  Once the remote shell emits a directory-tracking sequence (see
`dtach-shell-shell-integration-snippet'), vterm updates `default-directory'
automatically to reflect the shell's current working directory."
  (require 'vterm)
  (let ((buf-name (dtach-shell--buffer-name host session)))
    (if (get-buffer buf-name)
        (pop-to-buffer buf-name)
      (message "Opening dtach session '%s' on %s..." session host)
      ;; Pin `default-directory' local around the vterm call.  vterm's
      ;; underlying `make-process' uses `:file-handler t', which means
      ;; that if default-directory is a TRAMP path the shell would be
      ;; started ON that remote host rather than locally — and our
      ;; vterm-shell (`ssh -t -- HOST dtach -a SOCKET`) would then run on
      ;; the wrong machine, failing to attach to the local-launched
      ;; dtach session.  The buffer's default-directory is reset to
      ;; the desired TRAMP path further down once vterm is up.
      ;;
      ;; `vterm-kill-buffer-on-exit' is bound to nil here (not buffer-locally
      ;; later) because vterm-mode reads it at init time to decide whether to
      ;; install a sentinel at all, and the sentinel itself reads it from
      ;; whatever buffer is current at exit-time — neither path consults a
      ;; buffer-local value.  Dynamic-binding it to nil here means no sentinel
      ;; is installed, so the buffer survives an ssh disconnect and
      ;; `dtach-shell-reconnect' has something to operate on.
      (let ((default-directory temporary-file-directory)
            (vterm-shell command)
            (vterm-min-window-width dtach-shell-min-window-width)
            (vterm-kill-buffer-on-exit nil))
        (vterm buf-name))
      (with-current-buffer buf-name
        (setq-local dtach-shell--remote-host host)
        (setq-local dtach-shell--session-name session)
        ;; `vterm-mode' resets `vterm-min-window-width' from the global
        ;; default, so re-pin it buffer-locally to allow the pty to track
        ;; the actual (possibly narrow) window width.
        (setq-local vterm-min-window-width dtach-shell-min-window-width)
        ;; Seed default-directory with a TRAMP path so C-x f immediately
        ;; browses the remote host.  vterm will refine this to the shell's
        ;; actual cwd once the first prompt fires (if shell integration is
        ;; configured — see `dtach-shell-show-shell-integration').
        (setq-local default-directory (format "/ssh:%s:" host))
        ;; Gracefully detach from dtach before the buffer is killed so the
        ;; remote session persists and can be reattached later.
        (add-hook 'kill-buffer-hook #'dtach-shell--detach-on-kill nil t)
        (dtach-shell--install-buffer-keybindings)))))


;;; Shell integration

(defconst dtach-shell-shell-integration-bash
  "\
# dtach-shell / vterm directory tracking
# Add these lines to ~/.bashrc on each remote host.
vterm_printf() { printf \"\\e]%s\\007\" \"$1\"; }
vterm_prompt_end() { vterm_printf \"51;A$(whoami)@$(hostname):$(pwd)\"; }
PROMPT_COMMAND=\"${PROMPT_COMMAND:+${PROMPT_COMMAND};}vterm_prompt_end\""
  "Bash snippet to add to ~/.bashrc on remote hosts.
When the remote shell sources this, it emits the current working directory
with each prompt.  vterm picks this up and updates `default-directory' in the
Emacs buffer to the corresponding TRAMP path, so `find-file' always opens in
the shell's actual cwd.")

(defconst dtach-shell-shell-integration-zsh
  "\
# dtach-shell / vterm directory tracking
# Add these lines to ~/.zshrc on each remote host.
vterm_printf() { printf \"\\e]%s\\007\" \"$1\"; }
vterm_prompt_end() { vterm_printf \"51;A$(whoami)@$(hostname):$(pwd)\"; }
precmd_functions+=(vterm_prompt_end)"
  "Zsh snippet to add to ~/.zshrc on remote hosts.
See `dtach-shell-shell-integration-bash' for details.")

;;;###autoload
(defun dtach-shell-show-shell-integration (shell)
  "Display the shell integration snippet for SHELL in a help buffer.
SHELL is either \\='bash or \\='zsh.  Copy the snippet into ~/.bashrc or
~/.zshrc on each remote host you connect to with `dtach-shell'."
  (interactive (list (intern (completing-read "Shell: " '("bash" "zsh") nil t))))
  (let ((snippet (pcase shell
                   ('bash dtach-shell-shell-integration-bash)
                   ('zsh  dtach-shell-shell-integration-zsh)
                   (_ (user-error "Unknown shell: %s" shell)))))
    (with-help-window "*dtach-shell integration*"
      (princ (format "Add the following to ~/.%src on each remote host:\n\n" shell))
      (princ snippet)
      (princ "\n\nAfter sourcing this, vterm will track the shell's cwd and update\n")
      (princ "`default-directory' automatically with each prompt.\n"))))


;;; Interactive entry point

;;;###autoload
(defun dtach-shell (host session &optional known-sessions)
  "Connect to dtach SESSION on HOST, creating it when it does not exist.

Interactively, HOST is selected from the hosts in `dtach-shell-ssh-config-file'
and SESSION is chosen from running sessions on that host (or a new name may be
entered).

If a buffer for HOST/SESSION already exists it is simply displayed.
Otherwise a new vterm buffer is opened with an SSH connection to the dtach
session (attaching to an existing one or starting a fresh one).

KNOWN-SESSIONS, when non-nil, is the list of session names already retrieved
from the host.  It is passed automatically when called interactively so that
no second SSH round-trip is needed to decide between attach and create."
  (interactive
   (let* ((hosts (dtach-shell--parse-ssh-config))
          (host  (completing-read "Remote host: " hosts nil nil))
          (sessions (condition-case err
                        (dtach-shell--get-remote-sessions host)
                      (error (user-error "%s" (error-message-string err)))))
          (session  (completing-read "Session (new or existing): "
                                     sessions nil nil)))
     (list host session sessions)))
  (let ((existing (dtach-shell--find-buffer host session)))
    (if existing
        (progn
          (message "Switching to existing buffer for '%s' on %s." session host)
          (pop-to-buffer existing))
      (let* ((sessions (or known-sessions
                           (condition-case err
                               (dtach-shell--get-remote-sessions host)
                             (error (user-error "%s" (error-message-string err))))))
             (cmd (if (member session sessions)
                      (progn
                        (message "Attaching to existing session '%s' on %s..."
                                 session host)
                        (dtach-shell--build-attach-command host session))
                    (progn
                      (message "Creating new session '%s' on %s..."
                               session host)
                      (dtach-shell--build-new-session-command host session)))))
        (dtach-shell--open-vterm host session cmd)))))

;;;###autoload
(defun dtach-shell-reconnect ()
  "Refresh a dtach-shell vterm buffer by reconnecting to its session.
The current buffer is killed, then a fresh SSH connection to the same host
and session is opened under the original buffer name.  This works whether
the existing connection is live or disconnected."
  (interactive)
  (unless (and dtach-shell--remote-host dtach-shell--session-name)
    (user-error "Not a dtach-shell buffer"))
  (let ((host dtach-shell--remote-host)
        (session dtach-shell--session-name))
    (kill-buffer (current-buffer))
    ;; We already know this session exists: reconnecting should attach
    ;; directly rather than discovering sessions first.
    (dtach-shell host session (list session))
    (message "Reconnected to %s/%s" host session)))

(global-set-key (kbd "C-c d") #'dtach-shell)
(global-set-key (kbd "C-c S-d") #'dtach-shell-reconnect)

(provide 'dtach-shell)
;;; dtach-shell.el ends here
