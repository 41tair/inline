;;; inline-core.el --- Inline AI assistant core  -*- lexical-binding: t; -*-

;; Author: Inline
;; Version: 0.2.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: tools, convenience

;;; Commentary:
;; Core task orchestration and region application.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'project)

(declare-function inline-dashboard-maybe-refresh "inline-dashboard")

(defgroup inline nil
  "Inline AI-assisted programming for Emacs."
  :group 'tools)

(defcustom inline-agents-filenames '("AGENTS.md")
  "Filenames to search for project constraints."
  :type '(repeat string)
  :group 'inline)

(defcustom inline-system-prompt
  "You are Inline, an AI coding assistant.\nFollow project rules strictly.\nReturn only the replacement code for the target region without Markdown fences or explanations."
  "Base system prompt appended after project constraints."
  :type 'string
  :group 'inline)

(defcustom inline-context-before-lines 0
  "Lines of context to include before the target region."
  :type 'integer
  :group 'inline)

(defcustom inline-context-after-lines 0
  "Lines of context to include after the target region."
  :type 'integer
  :group 'inline)

(defcustom inline-api-url (getenv "INLINE_OPENAI_URL")
  "HTTP endpoint for the AI backend."
  :type '(choice (const :tag "Unset" nil) string)
  :group 'inline)

(defcustom inline-api-key-env "INLINE_OPENAI_KEY"
  "Environment variable name for the API key."
  :type 'string
  :group 'inline)

(defcustom inline-api-auth-source nil
  "Auth-source search parameters as a plist, e.g. (:host \"api\" :user \"token\")."
  :type '(choice (const :tag "Unset" nil) plist)
  :group 'inline)

(defcustom inline-api-extra-headers nil
  "Extra HTTP headers for the backend request.
Each element should be a cons cell (Header . Value)."
  :type '(repeat (cons string string))
  :group 'inline)

(defcustom inline-model (or (getenv "INLINE_OPENAI_MODEL") "")
  "Model name for the backend request."
  :type 'string
  :group 'inline)

(defcustom inline-temperature 0.2
  "Sampling temperature for the backend request."
  :type 'number
  :group 'inline)

(defcustom inline-max-tokens nil
  "Max tokens for the backend request."
  :type '(choice (const :tag "Unset" nil) integer)
  :group 'inline)

(defcustom inline-request-timeout 60
  "Timeout in seconds for backend requests."
  :type 'integer
  :group 'inline)

(defcustom inline-max-concurrent 3
  "Maximum number of concurrent running tasks."
  :type 'integer
  :group 'inline)

(defcustom inline-editor-running-tips
  '("You can keep editing while this request runs."
    "Use C-c i d to open the dashboard."
    "Use k in dashboard to stop a running task.")
  "Tips shown in the source buffer while a task is running."
  :type '(repeat string)
  :group 'inline)

(defcustom inline-backend #'inline-backend-http
  "Function used to send backend requests.
Signature: (TASK REQUEST CALLBACK)."
  :type 'function
  :group 'inline)

(defcustom inline-request-builder #'inline-request-builder-openai
  "Function that builds a request object from TASK.
The return value is JSON-encoded before sending."
  :type 'function
  :group 'inline)

(defcustom inline-response-parser #'inline-response-parser-openai
  "Function that extracts model text from raw response body."
  :type 'function
  :group 'inline)

(defcustom inline-response-cleaner #'inline-response-cleaner-strip-fences
  "Function that cleans model output before insertion."
  :type 'function
  :group 'inline)

(defvar inline--tasks nil
  "List of all tasks.")

(defvar inline--task-queue nil
  "Queue of pending tasks.")

(defvar inline--task-counter 0
  "Monotonic counter for task IDs.")

(cl-defstruct (inline-task (:constructor inline--make-task))
  id
  status
  type
  created-at
  started-at
  finished-at
  buffer
  file
  project-root
  project-name
  start-marker
  end-marker
  result-start-marker
  result-end-marker
  start-line
  start-column
  summary
  prompt
  system-prompt
  user-prompt
  request
  response
  raw-response
  error
  original-text
  buffer-mod-tick
  tip-overlay
  process
  response-buffer
  timeout-timer)

(defun inline--project-root (buffer)
  "Return project root for BUFFER, or nil."
  (with-current-buffer buffer
    (when-let ((proj (project-current nil)))
      (project-root proj))))

(defun inline--project-name (root)
  "Return a short name for project ROOT."
  (when root
    (file-name-nondirectory (directory-file-name root))))

(defun inline--agents-file (start-dir)
  "Search upward from START-DIR for an agents file."
  (let ((dir (file-name-as-directory (expand-file-name start-dir)))
        (root (file-name-as-directory (expand-file-name "/")))
        (found nil))
    (while (and dir (not found))
      (dolist (name inline-agents-filenames)
        (let ((path (expand-file-name name dir)))
          (when (file-exists-p path)
            (setq found path))))
      (unless found
        (setq dir (file-name-directory (directory-file-name dir)))
        (when (or (null dir) (string= dir root))
          (setq dir nil))))
    found))

(defun inline--read-file (path)
  "Read file contents from PATH, or nil."
  (when (and path (file-readable-p path))
    (with-temp-buffer
      (insert-file-contents path)
      (buffer-string))))

(defun inline--agents-text (buffer)
  "Return agents file contents for BUFFER, or nil."
  (let* ((file (buffer-file-name buffer))
         (start-dir (if file (file-name-directory file) default-directory))
         (path (inline--agents-file start-dir)))
    (when path
      (inline--read-file path))))

(defun inline--build-system-prompt (agents)
  "Build system prompt with AGENTS prepended."
  (concat
   (when (and agents (not (string-empty-p agents)))
     (format "Project Rules (from AGENTS):\n%s\n\n" agents))
   inline-system-prompt))

(defun inline--context-before (start)
  "Return context before START according to `inline-context-before-lines'."
  (when (> inline-context-before-lines 0)
    (save-excursion
      (goto-char start)
      (forward-line (- inline-context-before-lines))
      (buffer-substring-no-properties (point) start))))

(defun inline--context-after (end)
  "Return context after END according to `inline-context-after-lines'."
  (when (> inline-context-after-lines 0)
    (save-excursion
      (goto-char end)
      (forward-line inline-context-after-lines)
      (buffer-substring-no-properties end (point)))))

(defun inline--defun-name ()
  "Return current defun name if available."
  (when (fboundp 'add-log-current-defun)
    (ignore-errors (add-log-current-defun))))

(defun inline--build-user-prompt (task instruction region-text)
  "Build user prompt for TASK using INSTRUCTION and REGION-TEXT."
  (let* ((file (inline-task-file task))
         (mode (with-current-buffer (inline-task-buffer task)
                 (symbol-name major-mode)))
         (defun (with-current-buffer (inline-task-buffer task)
                  (inline--defun-name)))
         (before (with-current-buffer (inline-task-buffer task)
                   (inline--context-before (marker-position (inline-task-start-marker task)))))
         (after (with-current-buffer (inline-task-buffer task)
                  (inline--context-after (marker-position (inline-task-end-marker task))))))
    (concat
     (format "Mode: %s\n" (capitalize (symbol-name (inline-task-type task))))
     (when defun (format "Symbol: %s\n" defun))
     (format "File: %s\n" file)
     (format "Major mode: %s\n\n" mode)
     "Instruction:\n"
     instruction
     "\n\n"
     (when before
       (format "Context Before:\n%s\n\n" before))
     "Target Region:\n"
     region-text
     "\n\n"
     (when after
       (format "Context After:\n%s\n\n" after))
     "Return only the replacement code.")))

(defun inline--next-task-id ()
  "Return the next task ID string."
  (setq inline--task-counter (1+ inline--task-counter))
  (format "A%03d" inline--task-counter))

(defun inline--task-summary (prompt)
  "Create a summary from PROMPT."
  (let* ((line (car (split-string (string-trim prompt) "\n")))
         (trim (truncate-string-to-width (or line "") 60 nil nil "...")))
    trim))

(defun inline--running-count ()
  "Return count of active tasks."
  (cl-count-if (lambda (task)
                 (memq (inline-task-status task) '(pending running)))
               inline--tasks))

(defun inline--update-mode-line ()
  "Force mode line refresh."
  (force-mode-line-update t))

(defun inline--dashboard-refresh-if-present ()
  "Refresh the dashboard if the dashboard module is loaded."
  (when (fboundp 'inline-dashboard-maybe-refresh)
    (inline-dashboard-maybe-refresh)))

(defun inline--mode-line ()
  "Return mode line indicator."
  (let ((running (inline--running-count)))
    (if (> running 0)
        (format " Inline[%d]" running)
      " Inline")))

(defun inline--task-tip-text (task)
  "Return running tip text for TASK."
  (let* ((tips inline-editor-running-tips)
         (tip (when tips
                (let* ((id (inline-task-id task))
                       (num (if (string-match "[0-9]+" id)
                                (string-to-number (match-string 0 id))
                              0)))
                  (nth (mod num (length tips)) tips)))))
    (format "Inline %s running. %s"
            (inline-task-id task)
            (or tip ""))))

(defun inline--task-show-tip (task)
  "Show running tip overlay for TASK in its source buffer."
  (when-let* ((marker (inline-task-start-marker task))
              (buffer (marker-buffer marker))
              (pos (marker-position marker)))
    (with-current-buffer buffer
      (let* ((line-pos (save-excursion
                         (goto-char pos)
                         (line-beginning-position)))
             (ov (make-overlay line-pos line-pos buffer nil t))
             (text (inline--task-tip-text task)))
        (overlay-put ov 'before-string
                     (propertize (format "[%s]\n" text) 'face 'shadow))
        (overlay-put ov 'evaporate t)
        (overlay-put ov 'priority 1000)
        (setf (inline-task-tip-overlay task) ov)))))

(defun inline--task-hide-tip (task)
  "Remove running tip overlay for TASK."
  (when-let ((ov (inline-task-tip-overlay task)))
    (delete-overlay ov)
    (setf (inline-task-tip-overlay task) nil)))

(defun inline--enqueue-task (context prompt)
  "Create a task from CONTEXT and PROMPT and enqueue it."
  (let* ((origin (plist-get context :origin-buffer))
         (start-marker (plist-get context :start-marker))
         (end-marker (plist-get context :end-marker))
         (file (plist-get context :file))
         (type (plist-get context :type))
         (start (marker-position start-marker))
         (end (marker-position end-marker)))
    (unless (buffer-live-p origin)
      (user-error "Inline: source buffer no longer exists"))
    (unless (and start end (< start end))
      (user-error "Inline: target region no longer exists"))
    (with-current-buffer origin
      (let* ((region-text (buffer-substring-no-properties start end))
             (agents (inline--agents-text origin))
             (system (inline--build-system-prompt agents))
             (task (inline--make-task
                    :id (inline--next-task-id)
                    :status 'pending
                    :type type
                    :created-at (current-time)
                    :buffer origin
                    :file file
                    :project-root (inline--project-root origin)
                    :project-name (inline--project-name (inline--project-root origin))
                    :start-marker (copy-marker start)
                    :end-marker (copy-marker end t)
                    :start-line (line-number-at-pos start)
                    :start-column (save-excursion (goto-char start) (current-column))
                    :summary (inline--task-summary prompt)
                    :prompt prompt
                    :system-prompt system
                    :original-text region-text
                    :buffer-mod-tick (buffer-chars-modified-tick))))
        (setf (inline-task-user-prompt task)
              (inline--build-user-prompt task prompt region-text))
        (setf (inline-task-request task)
              (funcall inline-request-builder task))
        (push task inline--tasks)
        (setq inline--task-queue (nconc inline--task-queue (list task)))
        (inline--dashboard-refresh-if-present)
        (inline--maybe-start-next)
        (message "Inline: Task %s started..." (inline-task-id task))))))

(defun inline--maybe-start-next ()
  "Start queued tasks up to `inline-max-concurrent'."
  (while (and inline--task-queue
              (< (inline--running-count) inline-max-concurrent))
    (let ((task (pop inline--task-queue)))
      (inline--start-task task))))

(defun inline--start-task (task)
  "Start TASK execution."
  (setf (inline-task-status task) 'running
        (inline-task-started-at task) (current-time))
  (inline--task-show-tip task)
  (setf (inline-task-timeout-timer task)
        (run-at-time inline-request-timeout nil #'inline--task-timeout task))
  (funcall inline-backend task (inline-task-request task) #'inline--backend-dispatch)
  (inline--dashboard-refresh-if-present)
  (inline--update-mode-line))

(defun inline--backend-dispatch (task status payload)
  "Dispatch backend STATUS and PAYLOAD for TASK."
  (when (eq (inline-task-status task) 'running)
    (when (inline-task-timeout-timer task)
      (cancel-timer (inline-task-timeout-timer task))
      (setf (inline-task-timeout-timer task) nil))
    (pcase status
      (:ok (inline--task-complete task payload))
      (:error (inline--task-fail task payload 'failed))
      (_ (inline--task-fail task (format "%s" payload) 'failed)))))

(defun inline--task-timeout (task)
  "Mark TASK as timed out and kill its process."
  (when (eq (inline-task-status task) 'running)
    (inline--task-hide-tip task)
    (when-let ((proc (inline-task-process task)))
      (ignore-errors (delete-process proc)))
    (when-let ((buf (inline-task-response-buffer task)))
      (when (buffer-live-p buf)
        (kill-buffer buf)))
    (setf (inline-task-status task) 'timeout
          (inline-task-finished-at task) (current-time)
          (inline-task-error task) "Request timed out"
          (inline-task-timeout-timer task) nil)
    (inline--dashboard-refresh-if-present)
    (inline--update-mode-line)
    (inline--maybe-start-next)
    (message "Inline: Task %s timed out" (inline-task-id task))))

(defun inline--task-fail (task error status)
  "Mark TASK as failed with ERROR and STATUS."
  (inline--task-hide-tip task)
  (setf (inline-task-status task) status
        (inline-task-finished-at task) (current-time)
        (inline-task-error task) error)
  (inline--dashboard-refresh-if-present)
  (inline--update-mode-line)
  (inline--maybe-start-next)
  (message "Inline: Task %s failed" (inline-task-id task)))

(defun inline--search-original (buffer text)
  "Return (START END) for TEXT in BUFFER if unique, else nil."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (let ((matches nil)
            (multiple nil))
        (while (and (not multiple) (search-forward text nil t))
          (push (cons (match-beginning 0) (match-end 0)) matches)
          (when (> (length matches) 1)
            (setq multiple t)))
        (when (and (not multiple) (= (length matches) 1))
          (car matches))))))

(defun inline--locate-region (task)
  "Locate task region. Returns (BUFFER START END) or nil."
  (let* ((start-marker (inline-task-start-marker task))
         (end-marker (inline-task-end-marker task))
         (buffer (or (marker-buffer start-marker)
                     (when (inline-task-file task)
                       (find-file-noselect (inline-task-file task))))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((start (marker-position start-marker))
              (end (marker-position end-marker))
              (original (inline-task-original-text task)))
          (cond
           ((and start end (< start end)
                 (string= (buffer-substring-no-properties start end) original))
            (list buffer start end))
           ((and original (not (string-empty-p original)))
            (when-let ((match (inline--search-original buffer original)))
              (list buffer (car match) (cdr match))))
           (t nil)))))))

(defun inline--apply-result (task response)
  "Apply RESPONSE to TASK region. Returns non-nil on success."
  (when-let ((loc (inline--locate-region task)))
    (pcase-let ((`(,buffer ,start ,end) loc))
      (with-current-buffer buffer
        (save-excursion
          (let ((inhibit-read-only t))
            (atomic-change-group
              (delete-region start end)
              (goto-char start)
              (insert response)
              (let ((new-start start)
                    (new-end (point)))
                (setf (inline-task-result-start-marker task) (copy-marker new-start)
                      (inline-task-result-end-marker task) (copy-marker new-end t))))))
        t))))

(defun inline--task-complete (task raw)
  "Handle completed TASK with RAW response body."
  (inline--task-hide-tip task)
  (setf (inline-task-raw-response task) raw)
  (let* ((parsed (funcall inline-response-parser raw))
         (clean (funcall inline-response-cleaner parsed)))
    (setf (inline-task-response task) clean)
    (if (inline--apply-result task clean)
        (setf (inline-task-status task) 'done
              (inline-task-finished-at task) (current-time))
      (setf (inline-task-status task) 'conflict
            (inline-task-finished-at task) (current-time)
            (inline-task-error task) "Region changed; result not applied")))
  (inline--dashboard-refresh-if-present)
  (inline--update-mode-line)
  (inline--maybe-start-next)
  (message "Inline: Task %s %s"
           (inline-task-id task)
           (pcase (inline-task-status task)
             ('done "completed")
             ('conflict "conflicted")
             (_ "finished"))))

(defun inline-task-kill (task)
  "Kill TASK if running or pending."
  (when (memq (inline-task-status task) '(pending running))
    (inline--task-hide-tip task)
    (when (inline-task-timeout-timer task)
      (cancel-timer (inline-task-timeout-timer task))
      (setf (inline-task-timeout-timer task) nil))
    (when-let ((proc (inline-task-process task)))
      (ignore-errors (delete-process proc)))
    (when-let ((buf (inline-task-response-buffer task)))
      (when (buffer-live-p buf)
        (kill-buffer buf)))
    (setf (inline-task-status task) 'killed
          (inline-task-finished-at task) (current-time))
    (setq inline--task-queue (delq task inline--task-queue))
    (inline--dashboard-refresh-if-present)
    (inline--update-mode-line)
    (inline--maybe-start-next)
    (message "Inline: Task %s killed" (inline-task-id task))))

(defvar inline-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c i f") #'inline-fill)
    (define-key map (kbd "C-c i r") #'inline-refactor)
    (define-key map (kbd "C-c i d") #'inline-dashboard)
    map)
  "Keymap for `inline-mode'.")

(define-minor-mode inline-mode
  "Toggle Inline minor mode."
  :lighter (:eval (inline--mode-line))
  :keymap inline-mode-map)

(provide 'inline-core)

;;; inline-core.el ends here
