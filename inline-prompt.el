;;; inline-prompt.el --- Inline prompt buffer and commands  -*- lexical-binding: t; -*-

;;; Commentary:
;; Prompt buffer workflow for Inline.

;;; Code:

(require 'inline-core)
(require 'thingatpt)
(require 'subr-x)

(defcustom inline-prompt-buffer-name "*Inline Prompt*"
  "Name of the Inline prompt buffer."
  :type 'string
  :group 'inline)

(defcustom inline-prompt-history-file
  (locate-user-emacs-file "inline-prompt-history")
  "File to persist Inline prompt history."
  :type 'file
  :group 'inline)

(defcustom inline-prompt-history-max 200
  "Maximum number of history entries to keep."
  :type 'integer
  :group 'inline)

(defcustom inline-prompt-directive-aliases
  '(("skill" . ("s"))
    ("context" . ("ctx")))
  "Alias table for built-in prompt directives.
Each entry is of the form (CANONICAL . ALIASES), where CANONICAL is the
directive name without the leading slash and ALIASES is a list of accepted
short forms."
  :type '(alist :key-type string :value-type (repeat string))
  :group 'inline)

(defcustom inline-prompt-context-value-aliases
  '(("around" . ("a"))
    ("buffer" . ("b")))
  "Alias table for prompt context values.
Each entry is of the form (CANONICAL . ALIASES), where CANONICAL is the
normalized context scope and ALIASES is a list of accepted short forms."
  :type '(alist :key-type string :value-type (repeat string))
  :group 'inline)

(defcustom inline-prompt-skill-aliases
  '(("translate" . ("tr" "tl"))
    ("expand" . ("exp" "ex"))
    ("polish" . ("pol" "pl"))
    ("english-coach" . ("ec" "eng")))
  "Alias table for prompt skill commands.
Each entry is of the form (CANONICAL . ALIASES), where CANONICAL is the skill
name and ALIASES is a list of accepted short forms."
  :type '(alist :key-type string :value-type (repeat string))
  :group 'inline)

(defvar inline--prompt-history nil
  "List of prompt history entries, most recent first.")

(defvar inline--prompt-history-loaded nil
  "Whether prompt history has been loaded from disk.")

(defvar inline--prompt-history-index -1
  "Current history index in the prompt buffer.")

(defvar inline--prompt-history-stash ""
  "Stashed current input before history navigation.")

(defvar-local inline--prompt-start nil
  "Marker for the start of editable input in the prompt buffer.")

(defvar-local inline--prompt-context nil
  "Plist of prompt context for the current buffer.")

(defvar-local inline--prompt-origin-buffer nil
  "Buffer where the prompt was initiated.")

(defun inline--alias-map (definitions &optional allowed)
  "Return alias hash table built from DEFINITIONS.
DEFINITIONS should be an alist of (CANONICAL . ALIASES). When ALLOWED is non-nil,
only canonical names present in ALLOWED are included. Signal `user-error' when
two active canonical names claim the same alias."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (entry definitions)
      (let* ((canonical (car entry))
             (aliases (cdr entry)))
        (when (or (null allowed) (member canonical allowed))
          (dolist (alias aliases)
            (let ((existing (gethash alias table)))
              (cond
               ((null existing)
                (puthash alias canonical table))
               ((string-equal existing canonical)
                nil)
               (t
                (user-error "Inline: alias /%s is declared for both /%s and /%s"
                            alias existing canonical))))))))
    table))

(defun inline--directive-command (name)
  "Return canonical directive command for NAME."
  (or (gethash name (inline--alias-map inline-prompt-directive-aliases))
      name))

(defun inline--context-scope-value (value)
  "Return canonical context scope for VALUE."
  (or (gethash value (inline--alias-map inline-prompt-context-value-aliases))
      value))

(defun inline--normalize-skill-name (name available)
  "Return canonical skill name for NAME when present in AVAILABLE."
  (cond
   ((member name available) name)
   (t
    (gethash name
             (inline--alias-map inline-prompt-skill-aliases available)))))

(defun inline--check-prompt-alias-collisions (available)
  "Signal `user-error' when active prompt aliases collide.
AVAILABLE is the list of active skill names for the current buffer."
  (let ((directive-map (inline--alias-map inline-prompt-directive-aliases))
        (skill-map (inline--alias-map inline-prompt-skill-aliases available)))
    (maphash
     (lambda (alias skill)
       (when-let ((directive (gethash alias directive-map)))
         (user-error "Inline: alias /%s is declared for both /%s and /%s"
                     alias directive skill)))
     skill-map)))

(defun inline--primary-alias (canonical definitions)
  "Return primary alias for CANONICAL from DEFINITIONS."
  (car (cdr (assoc-string canonical definitions t))))

(defun inline--prompt-help-command-entries (available)
  "Return visible prompt help command entries for AVAILABLE skills."
  (let ((entries nil))
    (dolist (skill available)
      (when-let ((alias (inline--primary-alias skill inline-prompt-skill-aliases)))
        (push (cons (format "/%s" alias) skill) entries)))
    (nreverse entries)))

(defun inline--format-prompt-help-columns (entries)
  "Format ENTRIES as two-column prompt help lines."
  (let ((lines nil))
    (while entries
      (let* ((left (pop entries))
             (right (pop entries))
             (left-text (format "  %-4s %s" (car left) (cdr left)))
             (line (if right
                       (format "%-26s %s"
                               left-text
                               (format "%-4s %s" (car right) (cdr right)))
                     left-text)))
        (push line lines)))
    (nreverse lines)))

(defun inline--skill-aliases-for-display (skill)
  "Return visible alias string for SKILL."
  (when-let ((aliases (cdr (assoc-string skill inline-prompt-skill-aliases t))))
    (string-join (mapcar (lambda (alias) (format "/%s" alias)) aliases) ", ")))

(defun inline--prompt-skill-lines (available)
  "Return visible skill inventory lines for AVAILABLE."
  (if available
      (cons "Available skills:"
            (mapcar (lambda (skill)
                      (if-let ((aliases (inline--skill-aliases-for-display skill)))
                          (format "  %-14s %s" skill aliases)
                        (format "  %s" skill)))
                    available))
    '("Available skills:" "  none")))

(defun inline--prompt-help-lines (available)
  "Return visible prompt help lines for AVAILABLE skills."
  (inline--prompt-skill-lines available))

(defun inline--prompt-header-line (available)
  "Return compact prompt header line for AVAILABLE skills."
  (string-join
   (mapcar (lambda (entry)
             (format "%s %s" (car entry) (cdr entry)))
           (inline--prompt-help-command-entries available))
   "   "))

(defun inline--ensure-history-loaded ()
  "Load history from `inline-prompt-history-file' if needed."
  (unless inline--prompt-history-loaded
    (setq inline--prompt-history-loaded t)
    (when (and inline-prompt-history-file
               (file-readable-p inline-prompt-history-file))
      (condition-case _
          (with-temp-buffer
            (insert-file-contents inline-prompt-history-file)
            (goto-char (point-min))
            (let ((data (read (current-buffer))))
              (when (and (listp data) (cl-every #'stringp data))
                (setq inline--prompt-history data))))
        (error nil)))))

(defun inline--save-prompt-history ()
  "Persist history to `inline-prompt-history-file'."
  (when inline-prompt-history-file
    (let ((dir (file-name-directory inline-prompt-history-file)))
      (when (and dir (not (file-directory-p dir)))
        (make-directory dir t)))
    (with-temp-file inline-prompt-history-file
      (prin1 inline--prompt-history (current-buffer)))))

(defun inline--history-add (text)
  "Add TEXT to prompt history."
  (let ((trimmed (string-trim text)))
    (when (not (string-empty-p trimmed))
      (unless (string= trimmed (car inline--prompt-history))
        (push trimmed inline--prompt-history))
      (when (> (length inline--prompt-history) inline-prompt-history-max)
        (setcdr (nthcdr (1- inline-prompt-history-max) inline--prompt-history) nil)))))

(defun inline--prompt-current-input ()
  "Return current input from the prompt buffer."
  (buffer-substring-no-properties inline--prompt-start (point-max)))

(defun inline--prompt-set-input (text)
  "Replace the editable input with TEXT."
  (let ((inhibit-read-only t))
    (delete-region inline--prompt-start (point-max))
    (goto-char (point-max))
    (insert text)))

(defun inline--history-match-p (query entry)
  "Return non-nil if ENTRY matches QUERY."
  (if (string-empty-p query)
      t
    (string-match-p (regexp-quote query) entry)))

(defun inline--history-find (query start-index step)
  "Find history index matching QUERY starting from START-INDEX.
STEP should be 1 (older) or -1 (newer)."
  (let* ((hist inline--prompt-history)
         (len (length hist))
         (idx (if (>= start-index 0)
                  (+ start-index step)
                (if (> step 0) 0 (1- len))))
         (found nil))
    (while (and (>= idx 0) (< idx len) (not found))
      (when (inline--history-match-p query (nth idx hist))
        (setq found idx))
      (unless found
        (setq idx (+ idx step))))
    found))

(defun inline--history-search (direction)
  "Incremental history search. DIRECTION: 1 for older, -1 for newer."
  (inline--ensure-history-loaded)
  (when (= inline--prompt-history-index -1)
    (setq inline--prompt-history-stash (inline--prompt-current-input)))
  (let ((query "")
        (last-query "")
        (index inline--prompt-history-index)
        (step direction)
        (done nil)
        (hist inline--prompt-history))
    (while (not done)
      (let ((key (read-key (format "History %s: %s"
                                   (if (> step 0) "backward" "forward")
                                   query))))
        (cond
         ((or (eq key ?\r) (eq key ?\n))
          (setq done t))
         ((eq key ?\C-g)
          (keyboard-quit))
         ((or (eq key 127) (eq key ?\b))
          (when (> (length query) 0)
            (setq query (substring query 0 -1))))
         ((eq key ?\C-r)
          (setq step 1))
         ((eq key ?\C-s)
          (setq step -1))
         ((characterp key)
          (setq query (concat query (string key))))))
      (unless done
        (when (not (string= query last-query))
          (setq index -1))
        (setq last-query query)
        (let ((match (inline--history-find query index step)))
          (when match
            (setq index match)
            (setq inline--prompt-history-index match)
            (inline--prompt-set-input (nth match hist)))))))
  (message ""))

(defun inline-prompt-history-prev ()
  "Insert previous history entry."
  (interactive)
  (inline--ensure-history-loaded)
  (when (= inline--prompt-history-index -1)
    (setq inline--prompt-history-stash (inline--prompt-current-input)))
  (let ((next (1+ inline--prompt-history-index)))
    (if (>= next (length inline--prompt-history))
        (user-error "No older history")
      (setq inline--prompt-history-index next)
      (inline--prompt-set-input (nth inline--prompt-history-index inline--prompt-history)))))

(defun inline-prompt-history-next ()
  "Insert next history entry."
  (interactive)
  (inline--ensure-history-loaded)
  (cond
   ((= inline--prompt-history-index -1)
    (user-error "No newer history"))
   ((= inline--prompt-history-index 0)
    (setq inline--prompt-history-index -1)
    (inline--prompt-set-input (or inline--prompt-history-stash "")))
   (t
    (setq inline--prompt-history-index (1- inline--prompt-history-index))
    (inline--prompt-set-input (nth inline--prompt-history-index inline--prompt-history)))))

(defun inline-prompt-history-search-backward ()
  "Search history backward (older)."
  (interactive)
  (inline--history-search 1))

(defun inline-prompt-history-search-forward ()
  "Search history forward (newer)."
  (interactive)
  (inline--history-search -1))

(defvar inline-prompt-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map text-mode-map)
    (define-key map (kbd "C-c C-c") #'inline-prompt-submit)
    (define-key map (kbd "C-c C-k") #'inline-prompt-cancel)
    (define-key map (kbd "M-p") #'inline-prompt-history-prev)
    (define-key map (kbd "M-n") #'inline-prompt-history-next)
    (define-key map (kbd "C-r") #'inline-prompt-history-search-backward)
    (define-key map (kbd "C-s") #'inline-prompt-history-search-forward)
    map)
  "Keymap for `inline-prompt-mode'.")

(define-derived-mode inline-prompt-mode text-mode "Inline-Prompt"
  "Major mode for Inline prompt buffers."
  (setq-local buffer-read-only nil)
  (setq-local truncate-lines nil))

(defun inline--defun-bounds ()
  "Return bounds of the current defun, or nil."
  (save-excursion
    (condition-case nil
        (let (start end)
          (end-of-defun)
          (setq end (point))
          (beginning-of-defun)
          (setq start (point))
          (when (< start end)
            (cons start end)))
      (error nil))))

(defun inline--line-bounds ()
  "Return bounds of the current line."
  (cons (line-beginning-position)
        (line-beginning-position 2)))

(defun inline--target-at-point ()
  "Return a plist describing the current target."
  (cond
   ((use-region-p)
    (list :start (region-beginning)
          :end (region-end)
          :kind 'selection))
   ((derived-mode-p 'prog-mode)
    (if-let ((bounds (inline--defun-bounds)))
        (list :start (car bounds)
              :end (cdr bounds)
              :kind 'defun)
      (let ((bounds (inline--line-bounds)))
        (list :start (car bounds)
              :end (cdr bounds)
              :kind 'line))))
   ((bounds-of-thing-at-point 'paragraph)
    (let ((bounds (bounds-of-thing-at-point 'paragraph)))
      (list :start (car bounds)
            :end (cdr bounds)
            :kind 'paragraph)))
   (t
    (let ((bounds (inline--line-bounds)))
      (list :start (car bounds)
            :end (cdr bounds)
            :kind 'line)))))

(defun inline--region-summary (start end)
  "Return a plist summary of region START END."
  (let* ((text (buffer-substring-no-properties start end))
         (lines (max 1 (count-lines start end)))
         (chars (- end start))
         (first-line (car (split-string text "\n")))
         (preview (truncate-string-to-width (or first-line "") 80 nil nil "...")))
    (list :lines lines :chars chars :preview preview)))

(defun inline--insert-header (type info)
  "Insert a read-only header for TYPE using INFO plist."
  (let ((start (point)))
    (insert (format "Inline Prompt (%s)\n" (capitalize (symbol-name type))))
    (insert (format "File: %s:%d:%d\n"
                    (plist-get info :file)
                    (plist-get info :line)
                    (plist-get info :column)))
    (insert (format "Target: %s, %d lines, %d chars\n"
                    (capitalize (symbol-name (plist-get info :target-kind)))
                    (plist-get info :lines)
                    (plist-get info :chars)))
    (insert (format "Preview: %s\n" (plist-get info :preview)))
    (dolist (line (or (plist-get info :help-lines)
                      (inline--prompt-help-lines
                       (mapcar #'car inline-prompt-skill-aliases))))
      (insert line "\n"))
    (insert "\n")
    (add-text-properties start (point)
                         '(read-only t front-sticky t rear-nonsticky t))))

(defun inline--open-prompt (type target &optional defaults initial-input)
  "Open the Inline prompt buffer for TYPE.
TARGET identifies the replacement range. DEFAULTS seeds prompt metadata.
INITIAL-INPUT pre-populates the editable area."
  (inline--ensure-history-loaded)
  (let* ((origin (current-buffer))
         (start (plist-get target :start))
         (end (plist-get target :end))
         (file (or (buffer-file-name origin) (buffer-name origin)))
         (line (line-number-at-pos start))
         (column (save-excursion (goto-char start) (current-column)))
         (summary (inline--region-summary start end))
         (available-skills (inline--available-skills origin))
         (buf (get-buffer-create inline-prompt-buffer-name))
         (info (list :file file
                     :line line
                     :column column
                     :target-kind (plist-get target :kind)
                     :lines (plist-get summary :lines)
                     :chars (plist-get summary :chars)
                     :preview (plist-get summary :preview)
                     :help-lines (inline--prompt-help-lines available-skills))))
    (with-current-buffer buf
      (inline-prompt-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (inline--insert-header type info)
        (when initial-input
          (insert initial-input)))
      (setq-local header-line-format
                  (inline--prompt-header-line available-skills))
      (setq inline--prompt-start (point-marker))
      (setq inline--prompt-context
            (list :type type
                  :skills (plist-get defaults :skills)
                  :context-scope (or (plist-get defaults :context-scope) 'around)
                  :target-kind (plist-get target :kind)
                  :origin-buffer origin
                  :start-marker (with-current-buffer origin (copy-marker start))
                  :end-marker (with-current-buffer origin (copy-marker end t))
                  :file file
                  :line line
                  :column column))
      (setq inline--prompt-origin-buffer origin)
      (setq inline--prompt-history-index -1)
      (setq inline--prompt-history-stash "")
      (goto-char (point-max)))
    (pop-to-buffer buf)))

(defun inline--parse-skill-list (text)
  "Parse skill list from TEXT."
  (cl-remove-if
   #'string-empty-p
   (mapcar #'string-trim
           (split-string text "[,[:space:]]+" t))))

(defun inline--prompt-directives (text context)
  "Parse TEXT for prompt directives using CONTEXT."
  (let ((skills (copy-sequence (or (plist-get context :skills) nil)))
        (context-scope (or (plist-get context :context-scope) 'around))
        (available (inline--available-skills (plist-get context :origin-buffer)))
        (body-lines nil))
    (inline--check-prompt-alias-collisions available)
    (dolist (line (split-string text "\n"))
      (let ((trimmed (string-trim-left line)))
        (if (string-match "\\`/\\([[:alnum:]-]+\\)\\(?:\\s-+\\(.+\\)\\)?\\s-*\\'" trimmed)
            (let* ((raw-command (downcase (match-string 1 trimmed)))
                   (args (match-string 2 trimmed))
                   (command (inline--directive-command raw-command)))
              (cond
               ((and args (string= command "context"))
                (pcase (inline--context-scope-value (downcase args))
                  ("buffer" (setq context-scope 'buffer))
                  ("around" (setq context-scope 'around))
                  (_ (push line body-lines))))
               ((and args (member command '("skill" "skills")))
                (let ((matched nil))
                  (dolist (name (inline--parse-skill-list args))
                    (when-let ((skill (inline--normalize-skill-name
                                       (downcase name)
                                       available)))
                      (setq matched t)
                      (cl-pushnew skill skills :test #'string-equal)))
                  (unless matched
                    (push line body-lines))))
               ((null args)
                (if-let ((skill (inline--normalize-skill-name raw-command available)))
                    (cl-pushnew skill skills :test #'string-equal)
                  (push line body-lines)))
               (t
                (push line body-lines))))
          (push line body-lines))))
    (list :instruction (string-trim (string-join (nreverse body-lines) "\n"))
          :skills skills
          :context-scope context-scope)))

(defun inline-prompt-submit ()
  "Submit the prompt from the prompt buffer."
  (interactive)
  (let* ((text (inline--prompt-current-input))
         (parsed (inline--prompt-directives text inline--prompt-context))
         (instruction (plist-get parsed :instruction))
         (skills (plist-get parsed :skills))
         (context-scope (plist-get parsed :context-scope))
         (context inline--prompt-context)
         (origin inline--prompt-origin-buffer))
    (when (and (string-empty-p instruction)
               (null skills))
      (user-error "Inline: prompt is empty"))
    (inline--history-add text)
    (inline--save-prompt-history)
    (inline--enqueue-task (plist-put (plist-put context :skills skills)
                                     :context-scope context-scope)
                          instruction)
    (kill-buffer (current-buffer))
    (when (buffer-live-p origin)
      (pop-to-buffer origin))))

(defun inline-prompt-cancel ()
  "Cancel the prompt and return to the origin buffer."
  (interactive)
  (let ((origin inline--prompt-origin-buffer))
    (kill-buffer (current-buffer))
    (when (buffer-live-p origin)
      (pop-to-buffer origin))))

(defun inline ()
  "Start a generic Inline request for the current target."
  (interactive)
  (inline--open-prompt 'inline (inline--target-at-point)))

(defun inline-fill ()
  "Start an Inline Fill request for the current target."
  (interactive)
  (inline--open-prompt 'fill (inline--target-at-point)))

(defun inline-expand ()
  "Start an Inline Expand request for the current target."
  (interactive)
  (inline--open-prompt 'expand
                       (inline--target-at-point)
                       '(:skills ("expand"))))

(add-hook 'kill-emacs-hook #'inline--save-prompt-history)

(provide 'inline-prompt)

;;; inline-prompt.el ends here
