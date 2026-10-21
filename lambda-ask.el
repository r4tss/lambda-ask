;;; lambda-ask.el --- Ask Claude about the code at point -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Edvin Jakobsson

;; Author: Edvin Jakobsson <edj7467@gmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (markdown-mode "2.6"))
;; Keywords: tools, convenience
;; URL: https://github.com/r4tss/lambda-ask

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Ask Claude about code, or have it rewrite code.  Runs `claude -p'
;; (subscription login, no API key) with its own system prompt, from its
;; own directory, and without settings, MCP servers or skills, so no
;; CLAUDE.md, memory or hooks get in.  Claude can only read: the project
;; and installed library sources (`lambda-ask-library-dirs').
;;
;; Code blocks are highlighted with LANG-ts-mode when that grammar is
;; installed, so any language treesit-auto knows works.

;;; Code:

(require 'diff-mode)
(require 'let-alist)
(require 'markdown-mode)
(require 'project)
(require 'pulse)
(require 'seq)
(require 'subr-x)

;; Optional integrations, used only when present.
(declare-function eglot-current-server "eglot")
(declare-function eglot-path-to-uri "eglot")
(declare-function jsonrpc-request "jsonrpc")
(declare-function evil-visual-state-p "evil-states")
(declare-function evil-exit-visual-state "evil-states")
(declare-function evil-local-set-key "evil-core")
(declare-function visual-fill-column-mode "visual-fill-column")
(defvar eglot--managed-mode)
(defvar evil-visual-beginning)
(defvar evil-visual-end)

(defgroup lambda-ask nil
  "Ask Claude about code from Emacs."
  :group 'tools
  :prefix "lambda-ask-")

(defcustom lambda-ask-executable "claude"
  "The `claude' command to run."
  :type 'string)

(defcustom lambda-ask-model "sonnet"
  "Model alias or full name passed to `claude --model'."
  :type 'string)

(defconst lambda-ask-system-prompt
  "You are a programming assistant inside Emacs. The user asks quick
questions about the code they are looking at, and sometimes asks you to
rewrite it. Answer tersely in Markdown, with code in fenced blocks tagged
with their language. You can read the project, including dependencies
installed inside it, and the library sources listed below. Before saying
a library has some API, check which version the project uses in its
manifest or lockfile, and read that version's source when you have it.
Symbol info from the language server, when present, is authoritative for
types and signatures."
  "System prompt for normal mode, where Claude answers and writes code.")

(defconst lambda-ask-teacher-prompt
  "You are a programming teacher inside Emacs. The user learns by
writing the code themselves, so never write the solution for them: no
complete functions or implementations, unless they say \"show me the
solution\". A line or two showing some syntax or an API is fine.
- When they describe something they want to build, explain the concepts
  involved, point them to the APIs to use, and break the work into small
  steps. Give the first step as a concrete task, such as the signature
  of a function to write and what it should do.
- When they ask for a hint, give the smallest hint that unblocks them,
  and a bigger one only if they ask again.
- When they submit code for grading, give a grade from A to F with short
  reasons: correctness, edge cases, idiomatic style, clarity. Point out
  problems as questions or hints, not fixes. Then give the next step.
Be concise and answer in Markdown. You can read the project, including
dependencies installed inside it, and the library sources listed below.
Before pointing to some API, check which version the project uses and
read that version's source when you have it."
  "System prompt for teacher mode.")

;; The TODO rule goes in the message rather than the system prompt, so
;; that it can show the conversation's current items.
(defvar lambda-ask--todos nil
  "TODO items of the current conversation, as (DONE . TEXT) pairs.")

(defconst lambda-ask-todo-rule
  "These are my TODO items for what we're working on:
%s

Only if this exchange changes them (a task came up, such as a step of a
plan, an item got done or turned out wrong), end your answer with a
```todo block holding the whole updated list, one item per line, with
\"- [ ] \" for open and \"- [X] \" for done items. Otherwise leave it out."
  "Message tail that lets Claude update the TODO list.
The %s is replaced with the current items.")

(defcustom lambda-ask-teacher nil
  "Non-nil when Claude teaches instead of writing code."
  :type 'boolean)

(defcustom lambda-ask-library-dirs
  '("~/.cargo/registry/src"                  ; Rust crates
    "~/go/pkg/mod"                           ; Go modules
    "/usr/lib/python3*/site-packages"        ; Python, system
    "~/.local/lib/python3*/site-packages"    ; Python, pip --user
    "/usr/include")                          ; C and C++ headers
  "Library sources outside projects that Claude may read, if they exist.
Wildcards are allowed.  Dependencies inside a project, like node_modules
or .venv, are readable already."
  :type '(repeat string))

;; Part of the message rather than the system prompt, since a resumed
;; conversation keeps the system prompt it started with.
(defconst lambda-ask-rewrite-rule
  "Rewrite this code accordingly. Your final message is pasted into the
file in place of it, so it must contain only the new code, keeping the
original indentation: no code fences, no explanation."
  "Instruction added to a rewrite request.")

(defconst lambda-ask-change-rule
  "Make this change. You can't edit files, so your final message must be
a short summary, a few lines starting with \"- \" that say what changes
where and why, followed by a unified diff of every file to change, in a
single ```diff block. Use paths relative to the project root with
a/ and b/ prefixes, like git diff, and read each file first so the
context lines match it exactly."
  "Instruction added to a change request.")

(defcustom lambda-ask-dir (expand-file-name "claude/" user-emacs-directory)
  "Directory Claude runs in, away from any project's CLAUDE.md and memory."
  :type 'directory)

(defvar lambda-ask-session nil
  "ID of the last conversation, for follow-ups.")

(defvar lambda-ask--process nil
  "The latest `claude' process, which may have finished.")

(defvar lambda-ask--ctx-tokens nil
  "Input tokens of the last request, i.e. how full the context is now.")

(defvar lambda-ask--ctx-window nil
  "Context window of the model in tokens, from its last result.")

(defvar lambda-ask--limits nil
  "Utilization (0 to 1) of the subscription windows, by name, as an alist.")

(defvar-local lambda-ask--view nil
  "Window point and start, as markers, from when the buffer was last hidden.")

(define-derived-mode lambda-ask-mode gfm-view-mode "λ"
  "Mode for the *lambda-ask* answer buffer."
  (setq-local markdown-fontify-code-blocks-natively t)
  ;; Wrap at the window edge, not at `fill-column'.
  (visual-line-mode 1)
  (when (bound-and-true-p visual-fill-column-mode)
    (visual-fill-column-mode -1))
  ;; Remember the scroll position when `q' hides the window.
  (add-hook 'quit-window-hook #'lambda-ask--save-view nil t))

(define-key lambda-ask-mode-map "q" #'quit-window)
(define-key lambda-ask-mode-map "x" #'lambda-ask-todo-toggle)

(defun lambda-ask--buffer (&optional name)
  "The *lambda-ask* buffer, which holds the latest answer, or the one called NAME."
  (setq name (or name "*lambda-ask*"))
  (or (get-buffer name)
      (with-current-buffer (get-buffer-create name)
        (lambda-ask-mode)
        (current-buffer))))

(defun lambda-ask--history ()
  "Buffer with every question and answer of the current conversation."
  (lambda-ask--buffer "*lambda-ask-history*"))

(defcustom lambda-ask-side 'right
  "Where the answer window goes.
Either `right' (full height, 40% wide) or `bottom' (fitted to the
answer, up to half the frame)."
  :type '(choice (const right) (const bottom)))

(defun lambda-ask--fit ()
  "Fit a bottom answer window to the answer, up to half the frame."
  (when-let* (((eq lambda-ask-side 'bottom))
              (window (get-buffer-window (lambda-ask--buffer) t)))
    (fit-window-to-buffer window (/ (frame-height (window-frame window)) 2) 3)))

(defun lambda-ask--append (buffer string &optional face)
  "Append STRING to BUFFER, without scrolling.
With FACE, show it in that face."
  (with-current-buffer buffer
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char (point-max))
        ;; `font-lock-face', since markdown's font-lock would replace `face'.
        (insert (if face (propertize string 'font-lock-face face) string))))))

(defun lambda-ask--erase (buffer)
  "Erase all of BUFFER, even though it is read-only."
  (with-current-buffer buffer
    (let ((inhibit-read-only t))
      (erase-buffer))))

(defun lambda-ask--insert (string &optional face)
  "Append STRING to the latest answer and to the history.
With FACE, show it in that face."
  (lambda-ask--append (lambda-ask--buffer) string face)
  (lambda-ask--append (lambda-ask--history) string face)
  (lambda-ask--fit))

(defun lambda-ask--stream (proc string)
  "Show STRING, a chunk of PROC's answer, but hold back any ```todo block.
The block is taken out of the answer when it ends, so showing it here
would make it flash by.  `lambda-ask--flush' shows what's held back."
  (let* ((held (concat (process-get proc :held) string))
         (bol (with-current-buffer (lambda-ask--buffer)
                (or (zerop (buffer-size))
                    (eq (char-before (point-max)) ?\n))))
         (fence (string-match (if bol "\\(?:\\`\\|\n\\)```todo" "\n```todo")
                              held))
         (cut (cond
               ;; Already hiding the block.
               ((process-get proc :hiding) 0)
               (fence (if (eq (aref held fence) ?\n) (1+ fence) fence))
               (t
                ;; The last line may be the start of a fence; wait for more.
                (let* ((nl (string-match-p "\n[^\n]*\\'" held))
                       (start (if nl (1+ nl) (and bol 0))))
                  (if (and start (string-prefix-p (substring held start) "```todo"))
                      start
                    (length held)))))))
    (when fence (process-put proc :hiding t))
    (when (> cut 0)
      (lambda-ask--insert (substring held 0 cut)))
    (process-put proc :held (substring held cut))))

(defun lambda-ask--flush (proc)
  "Show what `lambda-ask--stream' holds back for PROC, minus its ```todo block."
  (let ((held (process-get proc :held)))
    (process-put proc :held nil)
    (when (and held (not (string-empty-p held)))
      (lambda-ask--insert
       (replace-regexp-in-string "^```todo\n\\(?:.*\n\\)*?```[ \t]*\n?" "" held)))))

(defun lambda-ask--display (buffer)
  "Show BUFFER in the Claude side window."
  (display-buffer buffer `(display-buffer-in-side-window
                           (side . ,lambda-ask-side)
                           (window-width . 0.4) (window-height . 0.4))))

(defun lambda-ask--save-view (&optional window)
  "Remember how WINDOW, or the selected window, is scrolled in its buffer."
  (let ((window (or window (selected-window))))
    (with-current-buffer (window-buffer window)
      (setq lambda-ask--view (cons (copy-marker (window-point window))
                                   (copy-marker (window-start window)))))))

(defun lambda-ask--show ()
  "Show the latest answer, scrolled to where it was when last hidden.
A new question erases the buffer, which puts it back at the top."
  (let* ((buffer (lambda-ask--buffer))
         (window (lambda-ask--display buffer))
         (view (buffer-local-value 'lambda-ask--view buffer)))
    (when view
      (set-window-point window (car view))
      (set-window-start window (cdr view)))
    (lambda-ask--fit)
    window))

;;;###autoload
(defun lambda-ask-show ()
  "Show the latest answer, or hide it if it is already showing.
It comes back scrolled to where it was when hidden."
  (interactive)
  (if-let* ((window (get-buffer-window (lambda-ask--buffer) t)))
      (progn (lambda-ask--save-view window)
             (quit-window nil window))
    (lambda-ask--show)))

(defun lambda-ask--todo-text ()
  "The conversation's TODO items as Markdown, or \"none\"."
  (if lambda-ask--todos
      (mapconcat (lambda (item)
                   (format "- [%s] %s" (if (car item) "X" " ") (cdr item)))
                 lambda-ask--todos "\n")
    "none"))

(defun lambda-ask--todo-render ()
  "Draw the TODO items at the top of the answer, replacing the old ones."
  (with-current-buffer (lambda-ask--buffer)
    (let ((inhibit-read-only t))
      (save-excursion
        (when-let* ((start (text-property-any (point-min) (point-max)
                                              'lambda-ask-todo-block t)))
          (delete-region start (or (next-single-property-change
                                    start 'lambda-ask-todo-block)
                                   (point-max))))
        (when lambda-ask--todos
          (goto-char (point-min))
          (insert (propertize "**TODO**\n\n" 'lambda-ask-todo-block t))
          (dolist (item lambda-ask--todos)
            (insert (propertize
                     (format "- [%s] %s\n" (if (car item) "X" " ") (cdr item))
                     'lambda-ask-todo-block t
                     'lambda-ask-todo item)))
          (insert (propertize "\n---\n\n" 'lambda-ask-todo-block t)))))
    (lambda-ask--fit)))

(defun lambda-ask-todo-toggle ()
  "Check or uncheck the TODO item on this line."
  (interactive)
  (let ((item (get-text-property (line-beginning-position) 'lambda-ask-todo))
        (line (line-number-at-pos)))
    (unless item (user-error "No TODO item here"))
    (setcar item (not (car item)))
    (lambda-ask--todo-render)
    (goto-char (point-min))
    (forward-line (1- line))))

(defun lambda-ask--take-todos (text todo)
  "Take the ```todo blocks out of TEXT, and use their items as the TODO list.
With TODO nil the items are ignored.  Returns TEXT without those blocks,
and drops them from the streamed answer and history too."
  (let ((regexp "^```todo\n\\(\\(?:.*\n\\)*?\\)```[ \t]*\n?")
        items)
    (dolist (buffer (list (lambda-ask--buffer) (lambda-ask--history)))
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (save-excursion
            (goto-char (point-min))
            (while (re-search-forward regexp nil t)
              (replace-match ""))))))
    (while (string-match regexp text)
      (let ((block (match-string 1 text)))
        (setq text (replace-match "" t t text))
        (dolist (line (split-string block "\n" t))
          ;; "- [X] Do x" -> (t . "Do x"), "* Do y" -> (nil . "Do y")
          (when (and (not (string-match-p "\\`[ \t]*#" line))
                     (string-match "\\`[ \t]*[-*]?[ \t]*\\(?:\\[\\([ xX-]?\\)\\]\\)?[ \t]*\\(.*?\\)[ \t]*\\'"
                                   line))
            (let ((done (member (match-string 1 line) '("x" "X")))
                  (item (match-string 2 line)))
              (unless (string-empty-p item)
                (push (cons (and done t) item) items)))))))
    (when todo
      (when items
        (setq lambda-ask--todos (nreverse items)))
      (lambda-ask--todo-render))
    text))

;;;###autoload
(defun lambda-ask-show-history ()
  "Show the whole conversation, at the latest question."
  (interactive)
  (let ((window (lambda-ask--display (lambda-ask--history))))
    (with-current-buffer (window-buffer window)
      (goto-char (point-max))
      (re-search-backward "^# [λ✎]" nil t)
      (set-window-point window (point))
      (set-window-start window (point)))))

;;;###autoload
(defun lambda-ask-toggle-side ()
  "Move the Claude window between the right side and the bottom."
  (interactive)
  (setq lambda-ask-side (if (eq lambda-ask-side 'right) 'bottom 'right))
  (let ((history (get-buffer-window (lambda-ask--history) t)))
    (dolist (buffer (list (lambda-ask--buffer) (lambda-ask--history)))
      (when-let* ((window (get-buffer-window buffer t)))
        (lambda-ask--save-view window)
        (delete-window window)))
    (if history (lambda-ask-show-history) (lambda-ask--show))))

(defun lambda-ask--replace (target text)
  "Put TEXT in place of TARGET, a (BEG . END) pair of markers."
  (let ((beg (car target))
        (end (cdr target))
        ;; Drop code fences, in case Claude added them anyway.
        (text (replace-regexp-in-string
               "\\`[ \t]*```.*\n\\|\n?[ \t]*```[ \t]*\\'" "" text))
        lang)
    (with-current-buffer (marker-buffer beg)
      (when (and (eq (char-before end) ?\n)
                 (not (string-suffix-p "\n" text)))
        (setq text (concat text "\n")))
      (save-excursion
        (delete-region beg end)
        (goto-char beg)
        (insert text))
      (pulse-momentary-highlight-region beg end)
      ;; rust-ts-mode -> rust, for the history's code block.
      (setq lang (replace-regexp-in-string "\\(-ts\\)?-mode\\'" ""
                                           (symbol-name major-mode))))
    (lambda-ask--append (lambda-ask--history)
                        (format "```%s\n%s%s```\n" lang text
                                (if (string-suffix-p "\n" text) "" "\n")))
    (message "λ rewritten (u to undo)")))

(defun lambda-ask--unsafe-files (diff)
  "File names in the headers of DIFF that could lead outside the project.
`diff-mode' resolves them against the project root, dropping leading
directories until one exists, so \"a/../x\", \"a/~/x\" and \"a//x\"
would reach outside it.  /dev/null, for new and deleted files, is fine."
  (let ((start 0) unsafe)
    (while (string-match "^\\(?:---\\|\\+\\+\\+\\|Index:\\|diff\\) +\\(.+\\)$"
                         diff start)
      (setq start (match-end 0))
      (dolist (name (split-string (match-string 1 diff) "[ \t]+" t))
        (when (and (not (equal name "/dev/null"))
                   (seq-some (lambda (part)
                               (or (member part '("" ".."))
                                   (string-prefix-p "~" part)))
                             (split-string name "/")))
          (push name unsafe))))
    (delete-dups (nreverse unsafe))))

(defun lambda-ask--show-diff (text project)
  "Show the diff in Claude's final message TEXT for review.
Hunks are applied to buffers from PROJECT, the project root.  A diff
naming files that could be outside it is refused."
  (let* ((start (string-match "^```diff\n" text))
         (body (and start (match-end 0)))
         (summary (string-trim (substring text 0 (or start 0))))
         (diff (if start
                   (substring text body
                              (string-match "^```[ \t]*$" text body))
                 text))
         (unsafe (lambda-ask--unsafe-files diff))
         (buffer (get-buffer-create "*lambda-ask-diff*")))
    (lambda-ask--append (lambda-ask--history)
                        (format "%s\n\n```diff\n%s```\n" summary diff))
    (if unsafe
        (message "λ refused: the diff names files outside the project (%s), see M-x lambda-ask-show-history"
                 (string-join unsafe ", "))
      (lambda-ask--review-diff buffer summary diff project))))

(defcustom lambda-ask-evil-diff-keys nil
  "Non-nil to bind single-letter review keys in the diff buffer, for evil.
In normal state, a applies a hunk, d drops it, A applies all of them,
n and p move between hunks and q closes.  Otherwise use `diff-mode's
own keys, which the mode line lists."
  :type 'boolean)

(defun lambda-ask--short-key (command)
  "The shortest key for COMMAND in the current buffer, as a string."
  (if-let* ((keys (where-is-internal command)))
      (car (sort (mapcar #'key-description keys) :key #'length))
    (concat "M-x " (symbol-name command))))

(defun lambda-ask--review-diff (buffer summary diff project)
  "Show SUMMARY and DIFF in BUFFER, set up to apply hunks to PROJECT."
  (with-current-buffer buffer
    (let ((inhibit-read-only t))
      (remove-overlays)
      (erase-buffer)
      ;; The summary goes above the diff, where diff-mode ignores it.
      ;; Indented, so its "- " lines can't pass for removed lines.
      (insert (replace-regexp-in-string "^" "  " summary) "\n\n")
      (overlay-put (make-overlay (point-min) (point)) 'face 'font-lock-doc-face)
      (insert diff)
      (diff-mode)
      (setq default-directory project)
      ;; Claude often gets the line counts in hunk headers wrong.
      (diff-fixup-modifs (point-min) (point-max)))
    ;; Read-only, so diff-mode's single-letter keys work.
    (read-only-mode 1)
    (let ((evil (and lambda-ask-evil-diff-keys (fboundp 'evil-local-set-key)))
          (keys '((diff-apply-hunk "a" "apply hunk")
                  (diff-hunk-kill "d" "drop hunk")
                  (diff-apply-buffer "A" "apply all")
                  (diff-hunk-next "n" "next hunk")
                  (diff-hunk-prev "p" "prev hunk")
                  (quit-window "q" "close"))))
      ;; Review keys for this buffer only; evil-collection's are behind g.
      (when evil
        (dolist (key keys)
          (evil-local-set-key 'normal (nth 1 key) (car key))))
      ;; The mode line becomes a key guide, with diff-mode's own keys
      ;; when the evil ones are off.
      (setq mode-line-format
            (concat " λ  "
                    (mapconcat (lambda (key)
                                 (concat (propertize
                                          (if evil
                                              (nth 1 key)
                                            (lambda-ask--short-key (car key)))
                                          'face 'help-key-binding)
                                         " " (nth 2 key)))
                               keys "   "))))
    (goto-char (point-min)))
  (pop-to-buffer buffer)
  (message "λ changes ready for review"))

(defun lambda-ask--tokens (n)
  "Format token count N compactly: 842, 12.3k."
  (if (< n 1000) (number-to-string n) (format "%.1fk" (/ n 1000.0))))

(defun lambda-ask--input-tokens (usage)
  "Input tokens in the USAGE alist, cache reads and writes included."
  (+ (or (alist-get 'input_tokens usage) 0)
     (or (alist-get 'cache_read_input_tokens usage) 0)
     (or (alist-get 'cache_creation_input_tokens usage) 0)))

(defun lambda-ask--show-usage ()
  "Show context fill and rate-limit use in the header lines."
  (let* ((limit (lambda (key label)
                  (when-let* ((u (alist-get key lambda-ask--limits)))
                    (format "%s %d%%" label (round (* 100 u))))))
         (parts
          (delq nil
                (list (when lambda-ask--ctx-tokens
                        (format "ctx %s%s"
                                (lambda-ask--tokens lambda-ask--ctx-tokens)
                                (if lambda-ask--ctx-window
                                    (format " (%d%%)"
                                            (round (* 100.0 lambda-ask--ctx-tokens)
                                                   lambda-ask--ctx-window))
                                  "")))
                      (funcall limit 'five_hour "5h")
                      (funcall limit 'seven_day "7d"))))
         ;; `header-line-format' treats % as a construct, so escape it.
         (text (and parts
                    (replace-regexp-in-string
                     "%" "%%" (concat " " (string-join parts " · ")) t t))))
    (dolist (buffer (list (lambda-ask--buffer) (lambda-ask--history)))
      (with-current-buffer buffer
        (setq header-line-format text)
        (force-mode-line-update)))))

(defun lambda-ask--add-usage (proc json)
  "Update the context size and window from PROC and the result event JSON."
  (setq lambda-ask--ctx-tokens (or (process-get proc :context) lambda-ask--ctx-tokens))
  (when-let* ((model (cdar (alist-get 'modelUsage json)))
              (window (alist-get 'contextWindow model))
              ((numberp window)))
    (setq lambda-ask--ctx-window window))
  (lambda-ask--show-usage))

(defun lambda-ask--handle (proc json)
  "Act on one JSON event from PROC.
Asks stream their answer into *lambda-ask*; rewrites and changes wait for
the final message and put it in the code or in a diff.
The usage events (`rate_limit_event' and the result's `modelUsage') are
not documented, so a missing or odd field there is ignored quietly."
  (let ((target (process-get proc :target)))
    (pcase (alist-get 'type json)
      ("stream_event"
       (let-alist json
         (when (and (not target) (equal .event.delta.type "text_delta"))
           (if (process-get proc :todo)
               (lambda-ask--stream proc .event.delta.text)
             (lambda-ask--insert .event.delta.text)))))
      ("rate_limit_event"
       (ignore-errors
         (let-alist json
           (dolist (w .rate_limit_info.unifiedWindows)
             (when-let* (((consp w))
                         (utilization (alist-get 'utilization (cdr w)))
                         ((numberp utilization)))
               (setf (alist-get (car w) lambda-ask--limits) utilization)))))
       (lambda-ask--show-usage))
      ;; Tool calls, shown in the echo area: λ ⟶ Grep WebSocketStream
      ("assistant"
       (let-alist json
         (when .message.usage
           (process-put proc :context (lambda-ask--input-tokens .message.usage)))
         (dolist (block .message.content)
           (when (equal (alist-get 'type block) "tool_use")
             (message "λ ⟶ %s %s" (alist-get 'name block)
                      (truncate-string-to-width
                       (format "%s" (cdar (alist-get 'input block))) 70))))))
      ("result"
       (ignore-errors (lambda-ask--add-usage proc json))
       (lambda-ask--flush proc)
       (cond ((eq (alist-get 'is_error json) t)
              (lambda-ask--insert (format "\n%s\n" (alist-get 'result json))
                                  'error)
              (when target (message "λ failed, see M-x lambda-ask-show-history")))
             (t
              (setq lambda-ask-session (alist-get 'session_id json))
              (let ((text (lambda-ask--take-todos (alist-get 'result json)
                                                  (process-get proc :todo))))
                (cond ((eq target 'diff)
                       (lambda-ask--show-diff text (process-get proc :project)))
                      ((and target (buffer-live-p (marker-buffer (car target))))
                       (lambda-ask--replace target text))))))))))

(defun lambda-ask--filter (proc output)
  "Process filter for PROC: parse its OUTPUT as lines of JSON events.
Incomplete trailing lines are kept in PROC until the rest arrives."
  (let ((lines (split-string (concat (process-get proc :partial) output) "\n")))
    (process-put proc :partial (car (last lines)))
    (dolist (line (butlast lines))
      (when-let* ((json (ignore-errors
                          (json-parse-string line :object-type 'alist
                                             :array-type 'list))))
        (lambda-ask--handle proc json)))))

(defun lambda-ask--project ()
  "Root of the current project, as a directory name.
Signal a `user-error' outside a project, or when the root is your home
or the filesystem root, since Claude can read everything under it."
  (let ((root (when-let* ((project (project-current)))
                (file-name-as-directory (expand-file-name (project-root project))))))
    (cond ((null root)
           (user-error "Not in a project; lambda-ask only reads inside one"))
          ((member root (list (file-name-as-directory (expand-file-name "~")) "/"))
           (user-error "Project root %s is too broad to share with Claude" root))
          (root))))

(defun lambda-ask--bounds ()
  "Bounds of the selection, or of the function at point."
  (cond ((and (fboundp 'evil-visual-state-p) (evil-visual-state-p))
         (prog1 (cons (marker-position evil-visual-beginning)
                      (marker-position evil-visual-end))
           (evil-exit-visual-state)))
        ((use-region-p) (cons (region-beginning) (region-end)))
        ((bounds-of-thing-at-point 'defun))))

(defcustom lambda-ask-max-hovers 40
  "Most distinct symbols to look up per request."
  :type 'integer)

(defcustom lambda-ask-hover-chars 300
  "Longest hover text to send for one symbol."
  :type 'integer)

(defun lambda-ask--hover-text (contents)
  "Flatten an LSP hover CONTENTS value to a string."
  (cond ((stringp contents) contents)
        ((and (listp contents) (plist-get contents :value)))
        ((vectorp contents)
         (string-join (delq nil (mapcar #'lambda-ask--hover-text contents)) "\n"))))

(defun lambda-ask--lsp-position-params ()
  "LSP TextDocumentPositionParams for point, built without eglot internals."
  (list :textDocument
        (list :uri (if (fboundp 'eglot-path-to-uri)
                       (eglot-path-to-uri buffer-file-name)
                     (concat "file://" (expand-file-name buffer-file-name))))
        :position
        (list :line (1- (line-number-at-pos nil t))
              :character (/ (string-bytes
                             (encode-coding-string
                              (buffer-substring-no-properties
                               (line-beginning-position) (point))
                              'utf-16le))
                            2))))

(defun lambda-ask--hovers (bounds)
  "Hover info from eglot for the distinct symbols within BOUNDS.
Keywords, strings and comments are skipped.  Only the signature part of
each hover is kept, and std/core/alloc items are left out."
  (when (and bounds buffer-file-name (bound-and-true-p eglot--managed-mode))
    (let ((server (eglot-current-server))
          seen out)
      (font-lock-ensure (car bounds) (cdr bounds))
      (save-excursion
        (goto-char (car bounds))
        ;; Count lookups, not hovers found: each one may wait for the timeout.
        (while (and (< (length seen) lambda-ask-max-hovers)
                    (re-search-forward "\\_<\\(?:\\sw\\|\\s_\\)\\{3,\\}\\_>"
                                       (cdr bounds) t))
          (let ((name (match-string-no-properties 0))
                (beg (match-beginning 0)))
            (unless (or (member name seen)
                        (save-excursion (nth 8 (syntax-ppss beg)))
                        (seq-intersection
                         (ensure-list (get-text-property beg 'face))
                         '(font-lock-keyword-face
                           font-lock-builtin-face
                           font-lock-preprocessor-face)))
              (push name seen)
              (save-excursion
                (goto-char beg)
                (when-let* ((hover (ignore-errors
                                     (jsonrpc-request
                                      server :textDocument/hover
                                      (lambda-ask--lsp-position-params)
                                      :timeout 1)))
                            (text (lambda-ask--hover-text (plist-get hover :contents)))
                            (sig (string-trim
                                  (or (car (split-string text "\n+---\n+" t)) "")))
                            ((string-match-p "```" sig))
                            ((not (string-match-p
                                   "```rust\n\\(?:std\\|core\\|alloc\\)::" sig))))
                  (push (format "%s:\n%s" name
                                (truncate-string-to-width
                                 sig lambda-ask-hover-chars nil nil "…"))
                        out)))))))
      (nreverse out))))

(defun lambda-ask--context (bounds)
  "Where we are, the code between BOUNDS, and what eglot knows about it."
  (concat
   (format "Project root: %s\nFile: %s, line %d\n\n```\n%s\n```"
           (lambda-ask--project) (or buffer-file-name (buffer-name))
           (line-number-at-pos (if bounds (car bounds) (point)))
           (if bounds (buffer-substring-no-properties (car bounds) (cdr bounds)) ""))
   (when-let* ((hovers (lambda-ask--hovers bounds)))
     (concat "\n\nSymbol info from the language server:\n\n"
             (string-join hovers "\n\n")))))

(defun lambda-ask--run (question prompt &optional resume target todo)
  "Send PROMPT to Claude, logging QUESTION.
With RESUME, continue that session.  With TARGET, a (BEG . END) pair
of markers, replace that code with the answer; with TARGET `diff',
show the answer's diff for review.  A non-nil TODO lets Claude update the
conversation's TODO list (see `lambda-ask-todo-rule')."
  (when (process-live-p lambda-ask--process)
    (user-error "Claude is still thinking"))
  ;; Fail before changing anything if there is no suitable project.
  (lambda-ask--project)
  (make-directory lambda-ask-dir t)
  ;; A new conversation starts with an empty TODO list.
  (unless resume
    (setq lambda-ask--todos nil
          lambda-ask--ctx-tokens nil)
    (lambda-ask--show-usage))
  ;; The history holds the whole conversation, so it starts over with it.
  (let ((history (lambda-ask--history))
        (heading (format "# %s %s\n\n" (if lambda-ask-teacher "✎" "λ") question)))
    (unless resume
      (lambda-ask--erase history))
    (lambda-ask--append history (concat (if (zerop (buffer-size history)) "" "\n\n")
                                        heading))
    (if target
        (message (if (eq target 'diff) "λ drafting changes…" "λ rewriting…"))
      ;; *lambda-ask* only ever holds the latest question and answer.
      (lambda-ask--erase (lambda-ask--buffer))
      (lambda-ask--append (lambda-ask--buffer) heading)
      (lambda-ask--todo-render)
      (lambda-ask--show)))
  (let* ((project (lambda-ask--project))
         (libraries (mapcan (lambda (dir)
                              (file-expand-wildcards (expand-file-name dir)))
                            lambda-ask-library-dirs))
         (default-directory lambda-ask-dir)
         (proc (make-process
                :name "lambda-ask" :noquery t :connection-type 'pipe
                ;; "--restricted" ignores settings files and confines the
                ;; file tools to the working directories, "--safe-mode"
                ;; disables CLAUDE.md, hooks, skills and plugins, and
                ;; "--permission-prompts none" denies anything that would
                ;; prompt, since nobody can answer in print mode.
                :command
                `(,lambda-ask-executable
                  "-p"
                  "--model" ,lambda-ask-model
                  "--output-format" "stream-json" "--verbose"
                  "--include-partial-messages"
                  "--system-prompt"
                  ,(concat (if lambda-ask-teacher
                               lambda-ask-teacher-prompt
                             lambda-ask-system-prompt)
                           "\n\nLibrary sources: "
                           (if libraries (string-join libraries ", ") "none"))
                  "--restricted" "--safe-mode"
                  "--strict-mcp-config" "--disable-slash-commands"
                  "--permission-prompts" "none"
                  "--add-dir" ,project ,@libraries
                  ,@(when resume (list "--resume" resume))
                  "--tools" "Read" "Grep" "Glob")
                :filter #'lambda-ask--filter
                :stderr (get-buffer-create "*lambda-ask-err*")
                :sentinel (lambda (proc event)
                            (cond ((string-prefix-p "finished" event))
                                  ;; Stopped with `lambda-ask-stop'.
                                  ((string-prefix-p "killed" event)
                                   (unless (process-get proc :target)
                                     (lambda-ask--insert "\n\n*stopped*\n" 'shadow))
                                   (message "λ stopped"))
                                  (t
                                   (lambda-ask--insert
                                    (format "\nclaude %s, see *lambda-ask-err*\n"
                                            (string-trim event))
                                    'error)))))))
    (setq lambda-ask--process proc)
    (process-put proc :partial "")
    (process-put proc :target target)
    (process-put proc :project project)
    (process-put proc :todo todo)
    (process-send-string proc (if todo
                                  (concat prompt "\n\n"
                                          (format lambda-ask-todo-rule (lambda-ask--todo-text)))
                                prompt))
    (process-send-eof proc)))

(defun lambda-ask--read (prompt)
  "Read a string with PROMPT, after capturing the selection or function at point.
Returns (STRING BOUNDS CONTEXT).  Capturing comes first because reading
leaves evil's visual state, which loses the selection."
  (let* ((bounds (lambda-ask--bounds))
         (context (lambda-ask--context bounds)))
    (list (read-string prompt) bounds context)))

;;;###autoload
(defun lambda-ask-ask (question _bounds context)
  "Ask Claude QUESTION about the selection or the function at point.
Starts a new conversation.  BOUNDS is unused; CONTEXT is the location,
code and language server info that `lambda-ask--read' captured."
  (interactive (lambda-ask--read "λ "))
  (lambda-ask--run question
                   (concat question "\n\n" context)
                   nil nil 'add))

(defun lambda-ask--check-followup ()
  "Signal a `user-error' unless a follow-up can be asked now.
Called before prompting, so no one types a question for nothing."
  (when (process-live-p lambda-ask--process)
    (user-error "Claude is still thinking"))
  (unless lambda-ask-session
    (user-error "No conversation to follow up on"))
  (lambda-ask--project))

;;;###autoload
(defun lambda-ask-followup (question)
  "Ask QUESTION in the last conversation."
  (interactive (progn (lambda-ask--check-followup)
                      (list (read-string "λ… "))))
  (lambda-ask--run question question lambda-ask-session nil 'review))

;;;###autoload
(defun lambda-ask-followup-scope (question _bounds context)
  "Like `lambda-ask-followup', but also send the code at point.
QUESTION is the question.  BOUNDS is unused.  CONTEXT is what
`lambda-ask--read' captured: the selection or function at point."
  (interactive (progn (lambda-ask--check-followup)
                      (lambda-ask--read "λ… ")))
  (lambda-ask--run question (concat question "\n\n" context)
                   lambda-ask-session nil 'review))

(defun lambda-ask--writes-code ()
  "Refuse to let Claude write code in teacher mode."
  (when lambda-ask-teacher
    (user-error "✎ Teacher mode: write it yourself (M-x lambda-ask-toggle-teacher to leave)")))

;;;###autoload
(defun lambda-ask-rewrite (instruction bounds context)
  "Rewrite the selection or the function at point following INSTRUCTION.
BOUNDS is the (BEG . END) of the code to replace, and CONTEXT is what
`lambda-ask--read' captured about it.  Continues the last conversation,
so the instruction can refer to it."
  (interactive (progn (lambda-ask--writes-code)
                      (lambda-ask--read "λ rewrite: ")))
  (unless bounds (user-error "Nothing to rewrite"))
  (lambda-ask--run (concat "rewrite: " instruction)
                   (concat instruction "\n\n" lambda-ask-rewrite-rule "\n\n" context)
                   lambda-ask-session
                   (cons (copy-marker (car bounds))
                         (copy-marker (cdr bounds) t))))

;;;###autoload
(defun lambda-ask-change (instruction _bounds context)
  "Ask Claude for a change across files, as a diff to review and apply.
INSTRUCTION says what to change.  BOUNDS is unused.  CONTEXT is what
`lambda-ask--read' captured.  Continues the last conversation."
  (interactive (progn (lambda-ask--writes-code)
                      (lambda-ask--read "λ change: ")))
  (lambda-ask--run (concat "change: " instruction)
                   (concat instruction "\n\n" lambda-ask-change-rule "\n\n" context)
                   lambda-ask-session 'diff))

;;;###autoload
(defun lambda-ask-grade (notes _bounds context)
  "Hand in the selection or the function at point for grading, with NOTES.
BOUNDS is unused.  CONTEXT is what `lambda-ask--read' captured.
Continues the last conversation, so the teacher knows the task."
  (interactive (lambda-ask--read "✎ grade, any notes? "))
  (lambda-ask--run (if (string-empty-p notes) "grade" (concat "grade: " notes))
                   (concat "Grade my attempt." (if (string-empty-p notes) "" " ")
                           notes "\n\n" context)
                   lambda-ask-session nil 'review))

;;;###autoload
(defun lambda-ask-toggle-teacher ()
  "Switch between Claude teaching and Claude writing code.
Starts a new conversation, since one keeps the prompt it started with."
  (interactive)
  (setq lambda-ask-teacher (not lambda-ask-teacher)
        lambda-ask-session nil)
  (message (if lambda-ask-teacher
               "✎ Teacher mode: Claude guides, you write the code"
             "λ Normal mode")))

;;;###autoload
(defun lambda-ask-stop ()
  "Stop Claude mid-answer or mid-rewrite."
  (interactive)
  (if-let* ((proc lambda-ask--process)
            ((process-live-p proc)))
      (kill-process proc)
    (message "λ not thinking")))

(provide 'lambda-ask)
;;; lambda-ask.el ends here
