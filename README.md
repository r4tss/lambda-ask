# Lambda-ask

Quick, read-only answers from Claude about the code at point. The code and what the language server knows about it go along with the question, so Claude rarely has to look anything up.

It uses your Claude subscription login through `claude -p`, so no API key is needed.

## Features

- **Ask about code.** Questions are sent with the selection (or the function at point), the file and line, and the project root.
- **Language server context.** If Eglot is running, the hover signatures of the symbols in that code are sent too, so Claude doesn't have to look up types.
- **Read-only.** Claude only gets the `Read`, `Grep` and `Glob` tools. It runs in its own directory with settings files, MCP servers, skills, hooks and CLAUDE.md turned off. It can read the current project and installed library sources (Cargo registry, Go modules, Python site-packages, `/usr/include`, configurable).
- **Streaming answers** in a Markdown buffer. Code blocks are highlighted with the matching tree-sitter mode when it's installed. Tool calls show in the echo area.
- **Follow-ups** resume the same conversation. The whole conversation is kept in a history buffer.
- **Rewrite.** The answer replaces the selected region in place.
- **Multi-file changes.** Claude returns a summary and a unified diff, which you review and apply hunk by hunk.
- **Teacher mode.** Claude explains concepts, gives hints and small next steps, and never writes the solution. You can hand in your own code for an A–F grade.
- **TODO list.** Claude keeps a checklist across a conversation, shown at the top of the answer.
- **Usage in the header line.** Context fill, and the 5-hour and 7-day subscription limits.

## Requirements

- Emacs 30.1 or later
- [markdown-mode](https://github.com/jrblevin/markdown-mode)
- The [Claude Code](https://claude.com/claude-code) CLI (`claude`), logged in. Version 2.1.304 or later is needed, since it uses `--restricted`, `--safe-mode` and `--permission-prompts`. Check with `claude --version`.
- Optional: Eglot (hover context), evil (selection handling and review keys), tree-sitter grammars (code highlighting)

## Installation

Clone the repository, then add it to your config:

```elisp
(use-package lambda-ask
  :ensure nil
  :load-path "/path/to/lambda-ask"
  :commands (lambda-ask-ask lambda-ask-followup lambda-ask-followup-scope
             lambda-ask-rewrite lambda-ask-change lambda-ask-grade
             lambda-ask-toggle-teacher lambda-ask-show
             lambda-ask-show-history lambda-ask-toggle-side lambda-ask-stop))
```

Or, on Emacs 30 or later, straight from the repository:

```elisp
(use-package lambda-ask
  :vc (:url "https://github.com/r4tss/lambda-ask" :rev :newest))
```

No keys are bound by default. Here is an example with a prefix map:

```elisp
(defvar-keymap my/lambda-ask-map
  "a" #'lambda-ask-ask
  "f" #'lambda-ask-followup
  "F" #'lambda-ask-followup-scope
  "r" #'lambda-ask-rewrite
  "c" #'lambda-ask-change
  "g" #'lambda-ask-grade
  "t" #'lambda-ask-toggle-teacher
  "l" #'lambda-ask-show
  "h" #'lambda-ask-show-history
  "w" #'lambda-ask-toggle-side
  "k" #'lambda-ask-stop)
(global-set-key (kbd "C-c a") my/lambda-ask-map)
```

If you use evil, you'll probably want the answer buffers in motion state:

```elisp
(with-eval-after-load 'lambda-ask
  (evil-set-initial-state 'lambda-ask-mode 'motion)
  (setq lambda-ask-evil-diff-keys t))
```

## Commands

| Command | What it does |
| --- | --- |
| `lambda-ask-ask` | Ask about the selection or the function at point. Starts a new conversation. |
| `lambda-ask-followup` | Ask in the last conversation. |
| `lambda-ask-followup-scope` | Follow up, and send the selection or function at point too. |
| `lambda-ask-rewrite` | Rewrite the selection or function at point in place. |
| `lambda-ask-change` | Ask for a change across files, as a diff to review. |
| `lambda-ask-grade` | Hand in code for grading (teacher mode). |
| `lambda-ask-toggle-teacher` | Switch between normal and teacher mode. Starts a new conversation. |
| `lambda-ask-show` | Show the latest answer, or hide it if it's showing. Keeps its scroll position. |
| `lambda-ask-show-history` | Show the whole conversation. |
| `lambda-ask-toggle-side` | Move the answer window between the right side and the bottom. |
| `lambda-ask-todo-toggle` | Check or uncheck the TODO item on this line (`x` in the answer buffer). |
| `lambda-ask-stop` | Stop Claude mid-answer. |

In teacher mode, `lambda-ask-rewrite` and `lambda-ask-change` are refused.

### Reviewing a change

`lambda-ask-change` opens a read-only `*lambda-ask-diff*` buffer in `diff-mode`, with its keys for reviewing listed in the mode line: `C-c C-a` applies a hunk, `k` drops one, `n` / `p` move between them and `q` closes. A diff that names files outside the project is refused; it stays in the history buffer.

With evil, you can set `lambda-ask-evil-diff-keys` to `t` to get these keys in normal state in that buffer:

| Key | Action |
| --- | --- |
| `a` | Apply hunk |
| `d` | Drop hunk |
| `A` | Apply all |
| `n` / `p` | Next / previous hunk |
| `q` | Close |

## Customization

`M-x customize-group RET lambda-ask`

| Option | Default | Meaning |
| --- | --- | --- |
| `lambda-ask-executable` | `"claude"` | The command to run. |
| `lambda-ask-model` | `"sonnet"` | Model alias or full name for `--model`. |
| `lambda-ask-dir` | `user-emacs-directory/claude/` | Directory Claude runs in, away from any project's CLAUDE.md and memory. |
| `lambda-ask-library-dirs` | Cargo, Go, Python, `/usr/include` | Library sources outside the project that Claude may read. Wildcards allowed. |
| `lambda-ask-side` | `right` | Where the answer window goes: `right` or `bottom`. |
| `lambda-ask-teacher` | `nil` | Non-nil for teacher mode. |
| `lambda-ask-evil-diff-keys` | `nil` | Non-nil for single-letter evil keys in the diff buffer. |
| `lambda-ask-max-hovers` | `40` | Most distinct symbols to look up per request. |
| `lambda-ask-hover-chars` | `300` | Longest hover text to send for one symbol. |

## How it works

Each request starts `claude -p` with `--output-format stream-json` and reads the events as they arrive. It passes a system prompt, `--tools Read Grep Glob`, `--restricted`, `--safe-mode` and `--strict-mcp-config`, and `--add-dir` for the project and the library directories. Follow-ups use `--resume` with the session ID from the last result.

The context and rate-limit figures in the header line come from fields in the CLI's output (`usage`, `modelUsage` and `rate_limit_event`). Not all of these are documented, so that display may stop working if the CLI changes. The rest of the package keeps working without it.

Claude is only given a project to read, found with `project-current`. Outside a project, or when the project root is your home directory or `/`, the commands refuse to run instead of exposing a broader directory.

## Privacy

The selected code, the file path, and the hover text are sent to Anthropic through the `claude` CLI. Claude can also read any file in the project directory and in the configured library directories. Take anything you don't want it to read out of `lambda-ask-library-dirs`, and don't run it in a project that contains secrets.
