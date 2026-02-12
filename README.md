# Inline

Inline is a non-blocking AI editing workflow for Emacs. It runs fill/refactor tasks asynchronously, applies successful results atomically, and keeps all task state in a global dashboard.

## Features

- Asynchronous region-based `fill` and `refactor` tasks.
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

## Configuration

### Environment variables

Default configuration reads:

- `INLINE_OPENAI_URL` (for `inline-api-url`)
- `INLINE_OPENAI_KEY` (for `inline-api-key-env`)
- `INLINE_OPENAI_MODEL` (for `inline-model`)

Example (Chat Completions API):

```bash
export INLINE_OPENAI_URL="https://api.openai.com/v1/chat/completions"
export INLINE_OPENAI_KEY="<your-key>"
export INLINE_OPENAI_MODEL="gpt-4o-mini"
```

Example (Responses API):

```bash
export INLINE_OPENAI_URL="https://api.openai.com/v1/responses"
export INLINE_OPENAI_KEY="<your-key>"
export INLINE_OPENAI_MODEL="gpt-4.1-mini"
```

Inline detects `/v1/responses` and automatically sends `instructions` + `input`; otherwise it sends Chat Completions-style `messages`.

### Optional auth-source setup

If you do not want API keys in environment variables:

```emacs-lisp
(setq inline-api-key-env nil
      inline-api-auth-source '(:host "api.openai.com" :user "token"))
```

### Common customization variables

- `inline-max-concurrent` (default `3`)
- `inline-request-timeout` (default `60` seconds)
- `inline-temperature` (default `0.2`)
- `inline-max-tokens` (`nil` by default)
- `inline-context-before-lines` / `inline-context-after-lines`
- `inline-api-extra-headers`
- `inline-dashboard-auto-refresh` (default `1` second)

## Usage

1. Select a region.
2. Run one of:
   - `M-x inline-fill` (`C-c i f`)
   - `M-x inline-refactor` (`C-c i r`)
3. Enter instructions in `*Inline Prompt*`.
4. Submit with `C-c C-c` (or cancel with `C-c C-k`).

Tasks run in the background. While running, Inline shows a temporary tip line in the source buffer and a mode-line indicator (`Inline[n]`).

## Keybindings

### `inline-mode`

- `C-c i f` start fill task
- `C-c i r` start refactor task
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

- `inline-fill` and `inline-refactor` require an active region.
- Prompt history is persisted to `~/.emacs.d/inline-prompt-history` by default.
- If region tracking fails due to heavy edits, Inline falls back to locating the original text; ambiguous matches result in `conflict` to avoid unsafe writes.
