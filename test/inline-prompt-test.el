;;; inline-prompt-test.el --- Tests for Inline prompt aliases  -*- lexical-binding: t; -*-

;;; Commentary:
;; ERT coverage for prompt abbreviations and aliases.

;;; Code:

(require 'ert)
(require 'cl-lib)

(let* ((this-file (or load-file-name buffer-file-name))
       (root (file-name-directory
              (directory-file-name
               (file-name-directory this-file)))))
  (add-to-list 'load-path root))

(require 'inline-prompt)

(setq inline-prompt-history-file nil)
(remove-hook 'kill-emacs-hook #'inline--save-prompt-history)

(defmacro inline-test-with-available-skills (skills &rest body)
  "Run BODY with `inline--available-skills' returning SKILLS."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'inline--available-skills)
              (lambda (&optional _buffer) ,skills)))
     ,@body))

(ert-deftest inline-prompt-directives-accept-skill-aliases ()
  (inline-test-with-available-skills
      '("translate" "expand" "polish" "english-coach")
    (let ((parsed (inline--prompt-directives
                   "/tr\n/exp\nTighten this function."
                   '(:context-scope around :origin-buffer nil))))
      (should (equal (plist-get parsed :instruction)
                     "Tighten this function."))
      (should (equal (sort (copy-sequence (plist-get parsed :skills))
                           #'string-lessp)
                     '("expand" "translate")))
      (should (eq (plist-get parsed :context-scope) 'around)))))

(ert-deftest inline-prompt-directives-accept-generic-and-value-aliases ()
  (inline-test-with-available-skills
      '("translate" "expand" "polish" "english-coach")
    (let ((parsed (inline--prompt-directives
                   "/s tr,exp,translate\n/ctx b\nExplain the changes."
                   '(:context-scope around :origin-buffer nil))))
      (should (equal (plist-get parsed :instruction)
                     "Explain the changes."))
      (should (equal (sort (copy-sequence (plist-get parsed :skills))
                           #'string-lessp)
                     '("expand" "translate")))
      (should (eq (plist-get parsed :context-scope) 'buffer)))))

(ert-deftest inline-prompt-directives-preserve-unknown-directives ()
  (inline-test-with-available-skills
      '("translate" "polish")
    (let ((parsed (inline--prompt-directives
                   "/unknown\nLeave this line untouched."
                   '(:context-scope around :origin-buffer nil))))
      (should (equal (plist-get parsed :instruction)
                     "/unknown\nLeave this line untouched."))
      (should (null (plist-get parsed :skills)))
      (should (eq (plist-get parsed :context-scope) 'around)))))

(ert-deftest inline-prompt-directives-reject-active-alias-collisions ()
  (let ((inline-prompt-skill-aliases '(("translate" . ("s")))))
    (inline-test-with-available-skills
        '("translate")
      (should-error
       (inline--prompt-directives "/translate"
                                  '(:context-scope around :origin-buffer nil))
       :type 'user-error))))

(ert-deftest inline-prompt-header-shows-short-forms ()
  (with-temp-buffer
    (inline--insert-header
     'inline
     '(:file "example.el"
       :line 1
       :column 0
       :target-kind line
       :lines 1
       :chars 10
       :preview "example"))
    (let ((header (buffer-string)))
      (should (string-match-p "Available skills:" header))
      (should (string-match-p "translate" header))
      (should (string-match-p "/tr, /tl" header))
      (should (string-match-p "expand" header))
      (should (string-match-p "/exp, /ex" header))
      (should (string-match-p "english-coach" header))
      (should (string-match-p "/ec, /eng" header)))))

(ert-deftest inline-prompt-help-shows-none-when-no-skills-are-loaded ()
  (let ((help (string-join (inline--prompt-help-lines nil) "\n")))
    (should (string-match-p "Available skills:" help))
    (should (string-match-p "  none" help))))

(ert-deftest inline-prompt-open-sets-header-line-format ()
  (inline-test-with-available-skills
      '("translate" "expand" "polish" "english-coach")
    (let ((origin (generate-new-buffer " *inline-origin*")))
      (unwind-protect
          (with-current-buffer origin
            (insert "hello world\n")
            (setq-local buffer-file-name "/tmp/example.txt")
            (let ((pop-up-windows nil)
                  (display-buffer-overriding-action
                   '((display-buffer-same-window))))
              (inline--open-prompt 'inline
                                   '(:start 1 :end 6 :kind line))
              (with-current-buffer inline-prompt-buffer-name
                (should (stringp header-line-format))
                (should (string-match-p "/tr translate" header-line-format))
                (should (string-match-p "/exp expand" header-line-format))
                (should (string-match-p "/pol polish" header-line-format))
                (should-not (string-match-p "/ref refactor" header-line-format))
                (should-not (string-match-p "/s " header-line-format))
                (should-not (string-match-p "/ctx " header-line-format))
                (kill-buffer (current-buffer)))))
        (when (buffer-live-p origin)
          (kill-buffer origin))))))

(ert-deftest inline-available-skills-include-bundled-skills-outside-projects ()
  (with-temp-buffer
    (setq default-directory "/tmp/")
    (let ((skills (inline--available-skills (current-buffer))))
      (should (member "translate" skills))
      (should (member "expand" skills))
      (should (member "polish" skills))
      (should (member "english-coach" skills)))))

(ert-deftest inline-expand-opens-with-expand-skill-preselected ()
  (let ((origin (generate-new-buffer " *inline-expand-origin*")))
    (unwind-protect
        (with-current-buffer origin
          (insert "short paragraph\n")
          (setq-local buffer-file-name "/tmp/example.txt")
          (let ((pop-up-windows nil)
                (display-buffer-overriding-action
                 '((display-buffer-same-window))))
            (inline-expand)
            (with-current-buffer inline-prompt-buffer-name
              (should (equal (plist-get inline--prompt-context :skills)
                             '("expand")))
              (kill-buffer (current-buffer)))))
      (when (buffer-live-p origin)
        (kill-buffer origin)))))

(ert-deftest inline-user-prompt-includes-generated-request-metadata ()
  (with-temp-buffer
    (emacs-lisp-mode)
    (setq-local buffer-file-name "/tmp/example.el")
    (insert "(message \"hello\")\n")
    (let* ((task (inline--make-task
                  :type 'inline
                  :buffer (current-buffer)
                  :file buffer-file-name
                  :skills '("translate")
                  :context-scope 'around
                  :target-kind 'line
                  :start-marker (copy-marker (point-min))
                  :end-marker (copy-marker (point-max) t)))
           (prompt (inline--build-user-prompt task
                                              "Translate this."
                                              (buffer-substring-no-properties
                                               (point-min) (point-max)))))
      (should (string-match-p "Request Context:" prompt))
      (should (string-match-p "- File Type: el" prompt))
      (should (string-match-p "- Major Mode: emacs-lisp-mode" prompt))
      (should (string-match-p "- Target Kind: Line" prompt))
      (should (string-match-p "Instruction:\nTranslate this\\." prompt)))))

(ert-deftest inline-system-prompt-remains-static-without-request-metadata ()
  (let ((system (inline--build-system-prompt nil nil)))
    (should (string-match-p (regexp-quote inline-system-prompt) system))
    (should-not (string-match-p "Major Mode:" system))
    (should-not (string-match-p "File Type:" system))))

(provide 'inline-prompt-test)

;;; inline-prompt-test.el ends here
