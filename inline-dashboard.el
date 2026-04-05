;;; inline-dashboard.el --- Inline task dashboard  -*- lexical-binding: t; -*-

;;; Commentary:
;; Global task dashboard for Inline.

;;; Code:

(require 'inline-core)
(require 'tabulated-list)

(defcustom inline-dashboard-buffer-name "*Inline Dashboard*"
  "Name of the Inline dashboard buffer."
  :type 'string
  :group 'inline)

(defcustom inline-dashboard-auto-refresh 1
  "Auto-refresh interval for the dashboard, or nil to disable."
  :type '(choice (const :tag "Disabled" nil) integer)
  :group 'inline)

(defcustom inline-dashboard-time-format "%Y-%m-%d %H:%M:%S"
  "Time format used in the dashboard."
  :type 'string
  :group 'inline)

(defvar inline--dashboard-timer nil
  "Timer for dashboard auto-refresh.")

(defcustom inline-dashboard-error-preview-length 80
  "Number of characters shown for failed task errors when collapsed."
  :type 'integer
  :group 'inline)

(defvar-local inline--dashboard-expanded-errors nil
  "Tasks with expanded error details in this dashboard buffer.")

(defun inline--now-string (time)
  "Format TIME for dashboard display."
  (format-time-string inline-dashboard-time-format time))

(defun inline--dashboard-one-line (text)
  "Return TEXT collapsed into a single line."
  (replace-regexp-in-string
   "[ \t\n\r]+"
   " "
   (string-trim (or text ""))))

(defun inline--dashboard-error-text (task)
  "Return dashboard error text for TASK."
  (let* ((status (inline-task-status task))
         (error-text (inline-task-error task)))
    (if (and (eq status 'failed) error-text)
        (let* ((full (inline--dashboard-one-line error-text))
               (expanded (memq task inline--dashboard-expanded-errors))
               (limit (max 1 inline-dashboard-error-preview-length)))
          (if expanded
              full
            (if (> (length full) limit)
                (concat (substring full 0 limit) "...")
              full)))
      "")))

(defun inline-dashboard-maybe-refresh ()
  "Refresh dashboard if it is visible."
  (when-let ((buf (get-buffer inline-dashboard-buffer-name)))
    (with-current-buffer buf
      (inline-dashboard-refresh))))

(defun inline-dashboard-refresh ()
  "Refresh the dashboard task list."
  (setq tabulated-list-entries
        (mapcar #'inline--dashboard-entry inline--tasks))
  (unless header-line-format
    (tabulated-list-init-header))
  (tabulated-list-print t))

(defun inline--status-face (status)
  "Return face symbol for STATUS."
  (pcase status
    ('running 'success)
    ('done 'font-lock-constant-face)
    ('failed 'error)
    ('timeout 'warning)
    ('conflict 'warning)
    ('killed 'shadow)
    (_ 'default)))

(defun inline--dashboard-entry (task)
  "Return a tabulated list entry for TASK."
  (let* ((status (inline-task-status task))
         (status-str (symbol-name status))
         (time (inline-task-created-at task))
         (source (if (inline-task-project-name task)
                     (format "%s/%s" (inline-task-project-name task)
                             (file-name-nondirectory (inline-task-file task)))
                   (file-name-nondirectory (inline-task-file task))))
         (summary (inline-task-summary task))
         (error-text (inline--dashboard-error-text task)))
    (list task
          (vector
           (inline-task-id task)
           (propertize (capitalize status-str) 'face (inline--status-face status))
           (inline--now-string time)
           source
           summary
           error-text))))

(defvar inline-dashboard-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "g") #'inline-dashboard-refresh)
    (define-key map (kbd "RET") #'inline-dashboard-jump)
    (define-key map (kbd "j") #'inline-dashboard-jump)
    (define-key map (kbd "k") #'inline-dashboard-kill)
    (define-key map (kbd "p") #'inline-dashboard-preview)
    (define-key map (kbd "c") #'inline-dashboard-clear)
    (define-key map (kbd "e") #'inline-dashboard-show-error)
    (define-key map (kbd "TAB") #'inline-dashboard-toggle-error)
    (define-key map [tab] #'inline-dashboard-toggle-error)
    map)
  "Keymap for `inline-dashboard-mode'.")

(define-derived-mode inline-dashboard-mode tabulated-list-mode "Inline-Dashboard"
  "Major mode for the Inline dashboard."
  (setq tabulated-list-format
        [("ID" 6 t)
         ("Status" 10 t)
         ("Time" 19 t)
         ("Source" 30 t)
         ("Summary" 36 t)
         ("Error" 0 nil)])
  (setq tabulated-list-padding 2)
  (setq truncate-lines nil)
  (setq inline--dashboard-expanded-errors nil)
  (add-hook 'tabulated-list-revert-hook #'inline-dashboard-refresh nil t)
  (tabulated-list-init-header))

(defun inline-dashboard ()
  "Open the Inline dashboard."
  (interactive)
  (let ((buf (get-buffer-create inline-dashboard-buffer-name)))
    (with-current-buffer buf
      (inline-dashboard-mode)
      (inline-dashboard-refresh))
    (pop-to-buffer buf)
    (inline--dashboard-auto-refresh-start)))

(defun inline--dashboard-auto-refresh-start ()
  "Start dashboard auto-refresh timer if enabled."
  (when inline-dashboard-auto-refresh
    (when inline--dashboard-timer
      (cancel-timer inline--dashboard-timer))
    (setq inline--dashboard-timer
          (run-at-time inline-dashboard-auto-refresh
                       inline-dashboard-auto-refresh
                       (lambda ()
                         (when (get-buffer inline-dashboard-buffer-name)
                           (with-current-buffer inline-dashboard-buffer-name
                             (inline-dashboard-refresh))))))))

(defun inline-dashboard-jump ()
  "Jump to the task's target region."
  (interactive)
  (let* ((task (tabulated-list-get-id))
         (marker (or (inline-task-result-start-marker task)
                     (inline-task-start-marker task)))
         (buffer (marker-buffer marker)))
    (if (buffer-live-p buffer)
        (progn
          (pop-to-buffer buffer)
          (goto-char (marker-position marker)))
      (when-let ((file (inline-task-file task)))
        (let ((buf (find-file-noselect file)))
          (pop-to-buffer buf)
          (goto-char (point-min))
          (forward-line (1- (inline-task-start-line task)))
          (move-to-column (inline-task-start-column task)))))))

(defun inline-dashboard-kill ()
  "Kill the task at point."
  (interactive)
  (let ((task (tabulated-list-get-id)))
    (inline-task-kill task)
    (inline-dashboard-refresh)))

(defun inline-dashboard-preview ()
  "Preview raw response for task at point."
  (interactive)
  (let* ((task (tabulated-list-get-id))
         (raw (inline-task-raw-response task))
         (buf (get-buffer-create "*Inline Preview*")))
    (if (not raw)
        (message "Inline: no response yet")
      (with-current-buffer buf
        (setq buffer-read-only nil)
        (erase-buffer)
        (insert raw)
        (goto-char (point-min))
        (view-mode 1))
      (pop-to-buffer buf))))

(defun inline-dashboard-toggle-error ()
  "Toggle expanded error details for failed task at point."
  (interactive)
  (let ((task (tabulated-list-get-id)))
    (if (and task
             (eq (inline-task-status task) 'failed)
             (inline-task-error task))
        (progn
          (if (memq task inline--dashboard-expanded-errors)
              (setq inline--dashboard-expanded-errors
                    (delq task inline--dashboard-expanded-errors))
            (push task inline--dashboard-expanded-errors))
          (inline-dashboard-refresh)
          (message "Inline: toggled failed error details"))
      (message "Inline: no failed task error to expand"))))

(defun inline-dashboard-show-error ()
  "Show full task error at point in a dedicated buffer."
  (interactive)
  (let* ((task (tabulated-list-get-id))
         (error-text (and task (inline-task-error task))))
    (if (and task error-text)
        (let ((buf (get-buffer-create "*Inline Error*")))
          (with-current-buffer buf
            (setq buffer-read-only nil)
            (erase-buffer)
            (insert (format "Task: %s\nStatus: %s\n\n%s"
                            (inline-task-id task)
                            (inline-task-status task)
                            error-text))
            (goto-char (point-min))
            (view-mode 1))
          (pop-to-buffer buf))
      (message "Inline: no error for task at point"))))

(defun inline-dashboard-clear ()
  "Clear finished tasks from the dashboard."
  (interactive)
  (setq inline--tasks
        (cl-remove-if (lambda (task)
                        (memq (inline-task-status task)
                              '(done failed timeout conflict killed)))
                      inline--tasks))
  (inline-dashboard-refresh))

(provide 'inline-dashboard)

;;; inline-dashboard.el ends here
