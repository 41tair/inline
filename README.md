# Inline

Inline is a non-blocking AI editing workflow for Emacs. It runs region rewrite tasks asynchronously, applies successful results atomically, and keeps all task state in a global dashboard.

## Features

- A single region-based `inline` command for code and prose transformations.
- Optional repository-local `skills/` prompts for tasks like translation, expansion, polishing, and English coaching.
- Atomic in-place apply (`atomic-change-group`) for single-step undo.
- Conflict detection when the target region changed before apply.
- Global dashboard for task status, preview, error inspection, and task control.
- Project rules injection from `AGENTS.md` (searched upward from the source file).
- OpenAI-compatible backend with support for both Chat Completions and Responses APIs.

## Requirements

- Emacs `27.1+`
- Network access to a compatible API endpoint
- API key via environment variable or `auth-source`

## Installation

Clone this repository, then load it from your Emacs config:

```emacs-lisp
(add-to-list 'load-path "/path/to/inline")
(require 'inline)
```

Enable the minor mode per buffer (or from mode hooks):

```emacs-lisp
(add-hook 'prog-mode-hook #'inline-mode)
;; or: (inline-mode 1) in a single buffer
```

## Available Usage Options

Inline exposes one primary workflow and a few compatibility shortcuts.

### Primary command

- `M-x inline` or `C-c i i`

This opens a single prompt page for the current target. The target is chosen in this order:

- active region, if one is selected
- current defun in `prog-mode`
- current paragraph in text-like buffers
- current line as a final fallback

After opening the prompt:

1. Enter a natural-language instruction.
2. Optionally add prompt directives such as:
   - `/translate`
   - `/tr`, `/tl`
   - `/expand`
   - `/exp`, `/ex`
   - `/polish`
   - `/pol`, `/pl`
   - `/english-coach`
   - `/ec`, `/eng`
   - `/skill NAME[,NAME]`
   - `/s NAME[,NAME]`
   - `/context around`
   - `/context buffer`
   - `/ctx around`, `/ctx buffer`
   - `/ctx a`, `/ctx b`
3. Submit with `C-c C-c` or cancel with `C-c C-k`.

Inline runs the request asynchronously, applies successful results atomically, and tracks the task in the dashboard.
The prompt uses `header-line-format` to keep the primary skill short forms visible while you type. The buffer body shows the currently available skills with their aliases. Bundled package skills are available even outside a project workspace, and the body explicitly shows `none` only when no skills are discoverable at all.

### Compatibility commands

- `M-x inline-fill` or `C-c i f`
- `M-x inline-expand` or `C-c i e`

### Dashboard and prompt navigation

- `M-x inline-dashboard` or `C-c i d` opens the global task dashboard
- `M-p` / `M-n` browse prompt history
- `C-r` / `C-s` search prompt history

### Context options

- `/context around` sends only the target plus configured surrounding lines
- `/context buffer` sends the target plus the entire current buffer as reference context
- `/ctx around` and `/ctx a` are abbreviations for `/context around`
- `/ctx buffer` and `/ctx b` are abbreviations for `/context buffer`

The full buffer is not sent by default.

## Configuration Instructions

### 1. Configure backend access

Default configuration reads:

- `INLINE_OPENAI_URL` for `inline-api-url`
- `INLINE_OPENAI_KEY` for `inline-api-key-env`
- `INLINE_OPENAI_MODEL` for `inline-model`

Example using Chat Completions:

```bash
export INLINE_OPENAI_URL="https://api.openai.com/v1/chat/completions"
export INLINE_OPENAI_KEY="<your-key>"
export INLINE_OPENAI_MODEL="gpt-4o-mini"
```

Example using Responses:

```bash
export INLINE_OPENAI_URL="https://api.openai.com/v1/responses"
export INLINE_OPENAI_KEY="<your-key>"
export INLINE_OPENAI_MODEL="gpt-4.1-mini"
```

Inline detects `/v1/responses` automatically and sends `instructions` + `input`. Other endpoints use a Chat Completions-style `messages` payload.

If you prefer `auth-source` instead of environment variables:

```emacs-lisp
(setq inline-api-key-env nil
      inline-api-auth-source '(:host "api.openai.com" :user "token"))
```

### 2. Enable the mode

Enable Inline per buffer or from hooks:

```emacs-lisp
(inline-mode 1)
;; or
(add-hook 'prog-mode-hook #'inline-mode)
```

### 3. Adjust editing behavior

Common variables:

- `inline-context-before-lines`
- `inline-context-after-lines`
- `inline-prompt-directive-aliases`
- `inline-prompt-context-value-aliases`
- `inline-prompt-skill-aliases`
- `inline-system-prompt`
- `inline-max-concurrent`
- `inline-request-timeout`
- `inline-temperature`
- `inline-max-tokens`
- `inline-editor-running-tips`

Example:

```emacs-lisp
(setq inline-context-before-lines 20
      inline-context-after-lines 20
      inline-request-timeout 90
      inline-temperature 0.1)
```

### 4. Configure project rules and skills

Project rules are loaded from filenames listed in `inline-agents-filenames`, which defaults to:

- `AGENTS.md`

Skills are loaded from directories listed in `inline-skill-directory-names`, which defaults to:

- `skills`
- `.inline/skills`

Each `*.md` or `*.txt` file becomes one available skill. The skill name is taken from the file basename.

### 5. Advanced integration options

These variables are useful if you need to adapt Inline to a different backend or request format:

- `inline-api-extra-headers`
- `inline-backend`
- `inline-request-builder`
- `inline-response-parser`
- `inline-response-cleaner`
- `inline-dashboard-auto-refresh`
- `inline-prompt-history-file`
- `inline-prompt-history-max`

## Skills

Each `*.md` or `*.txt` file becomes one selectable skill. The skill name is the file basename. Selected skills are appended to the system prompt before the request is sent. The unified prompt page can activate them via slash directives such as `/translate`, `/tr`, `/skill polish,english-coach`, or `/s pol,ec`.

Bundled skills also ship with explicit aliases:

- `translate`: `/tr`, `/tl`
- `expand`: `/exp`, `/ex`
- `polish`: `/pol`, `/pl`
- `english-coach`: `/ec`, `/eng`

Aliases are explicit. Inline does not infer arbitrary prefixes, and alias
collisions should be resolved in configuration instead of guessed at runtime.

## Request Context

Inline keeps `inline-system-prompt` focused on stable behavior instructions.
Per-request editing metadata is generated separately and attached to the request
context instead. This context can include:

- operation type
- target kind
- context scope
- file path
- file type or extension
- major mode
- current symbol when available
- selected skills

This repository includes example skills:

- `skills/translate.md`
- `skills/expand.md`
- `skills/polish.md`
- `skills/english-coach.md`

## Keybindings

### `inline-mode`

- `C-c i i` start generic inline task
- `C-c i f` start fill task
- `C-c i e` start expand task
- `C-c i d` open dashboard

### Prompt buffer (`inline-prompt-mode`)

- `C-c C-c` submit
- `C-c C-k` cancel
- `M-p` / `M-n` history previous/next
- `C-r` / `C-s` interactive history search backward/forward

### Dashboard (`inline-dashboard-mode`)

- `RET` / `j` jump to task location
- `k` kill pending/running task
- `p` preview raw response
- `e` show full error in dedicated buffer
- `TAB` expand/collapse failed-task error text
- `c` clear finished tasks (`done`, `failed`, `timeout`, `conflict`, `killed`)
- `g` refresh

## Task Statuses

Dashboard states include:

- `pending`
- `running`
- `done`
- `failed`
- `timeout`
- `conflict`
- `killed`

## Notes

- `inline`, `inline-fill`, and `inline-expand` act on the active region when present, otherwise they infer a local target.
- Prompt history is persisted to `~/.emacs.d/inline-prompt-history` by default.
- Full-buffer context is opt-in through `/context buffer`; Inline does not send the entire buffer by default.
- If region tracking fails due to heavy edits, Inline falls back to locating the original text; ambiguous matches result in `conflict` to avoid unsafe writes.
