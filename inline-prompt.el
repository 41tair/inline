;;; inline-prompt.el --- Inline prompt buffer and commands  -*- lexical-binding: t; -*-

;;; Commentary:
;; Prompt buffer workflow for Inline.

;;; Code:

(require 'inline-core)
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

(defun inline--region-required ()
  "Return (START END) if region is active, otherwise raise an error."
  (unless (use-region-p)
    (user-error "Inline: select a region first"))
  (list (region-beginning) (region-end)))

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
    (insert (format "Region: %d lines, %d chars\n"
                    (plist-get info :lines)
                    (plist-get info :chars)))
    (insert (format "Preview: %s\n" (plist-get info :preview)))
    (insert "\n")
    (add-text-properties start (point)
                         '(read-only t front-sticky t rear-nonsticky t))))

(defun inline--open-prompt (type start end)
  "Open the Inline prompt buffer for TYPE using region START END."
  (inline--ensure-history-loaded)
  (let* ((origin (current-buffer))
         (file (or (buffer-file-name origin) (buffer-name origin)))
         (line (line-number-at-pos start))
         (column (save-excursion (goto-char start) (current-column)))
         (summary (inline--region-summary start end))
         (buf (get-buffer-create inline-prompt-buffer-name))
         (info (list :file file
                     :line line
                     :column column
                     :lines (plist-get summary :lines)
                     :chars (plist-get summary :chars)
                     :preview (plist-get summary :preview))))
    (with-current-buffer buf
      (inline-prompt-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (inline--insert-header type info))
      (setq inline--prompt-start (point-marker))
      (setq inline--prompt-context
            (list :type type
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

(defun inline-prompt-submit ()
  "Submit the prompt from the prompt buffer."
  (interactive)
  (let* ((text (inline--prompt-current-input))
         (trimmed (string-trim text))
         (context inline--prompt-context)
         (origin inline--prompt-origin-buffer))
    (when (string-empty-p trimmed)
      (user-error "Inline: prompt is empty"))
    (inline--history-add text)
    (inline--save-prompt-history)
    (inline--enqueue-task context text)
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

(defun inline-fill ()
  "Start an Inline Fill request for the active region."
  (interactive)
  (cl-destructuring-bind (start end) (inline--region-required)
    (inline--open-prompt 'fill start end)))

(defun inline-refactor ()
  "Start an Inline Refactor request for the active region."
  (interactive)
  (cl-destructuring-bind (start end) (inline--region-required)
    (inline--open-prompt 'refactor start end)))

(add-hook 'kill-emacs-hook #'inline--save-prompt-history)

(provide 'inline-prompt)

;;; inline-prompt.el ends here
