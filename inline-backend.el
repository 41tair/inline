;;; inline-backend.el --- Inline backend integrations  -*- lexical-binding: t; -*-

;;; Commentary:
;; HTTP backend and request/response helpers.

;;; Code:

(require 'inline-core)
(require 'cl-lib)
(require 'json)
(require 'url)
(require 'url-http)
(require 'auth-source)
(require 'subr-x)

(defun inline--responses-endpoint-p ()
  "Return non-nil when `inline-api-url' targets the Responses API."
  (when inline-api-url
    (let ((url (replace-regexp-in-string "/+$" "" inline-api-url)))
      (string-match-p "/v1/responses\\'" url))))

(defun inline--api-key ()
  "Return API key from env or auth-source."
  (or (and inline-api-key-env
           (getenv inline-api-key-env))
      (when inline-api-auth-source
        (let* ((spec (append inline-api-auth-source '(:max 1)))
               (found (apply #'auth-source-search spec))
               (secret (plist-get (car found) :secret)))
          (cond
           ((functionp secret) (funcall secret))
           ((stringp secret) secret)
           (t nil))))))

(defun inline-request-builder-openai (task)
  "Build an OpenAI-compatible request object for TASK."
  (if (inline--responses-endpoint-p)
      (let ((payload `((model . ,inline-model)
                       (temperature . ,inline-temperature)
                       (instructions . ,(inline-task-system-prompt task))
                       (input . ,(inline-task-user-prompt task)))))
        (when inline-max-tokens
          (setf (alist-get 'max_output_tokens payload) inline-max-tokens))
        payload)
    (let ((payload `((model . ,inline-model)
                     (temperature . ,inline-temperature)
                     (messages .
                               [((role . "system") (content . ,(inline-task-system-prompt task)))
                                ((role . "user") (content . ,(inline-task-user-prompt task)))]))))
      (when inline-max-tokens
        (setf (alist-get 'max_tokens payload) inline-max-tokens))
      payload)))

(defun inline--responses-content-text (content)
  "Extract concatenated text from Responses API CONTENT."
  (let ((parts nil))
    (cond
     ((vectorp content)
      (dotimes (i (length content))
        (let* ((item (aref content i))
               (text (or (alist-get 'text item)
                         (alist-get 'output_text item))))
          (when (stringp text)
            (push text parts)))))
     ((listp content)
      (dolist (item content)
        (let ((text (or (alist-get 'text item)
                        (alist-get 'output_text item))))
          (when (stringp text)
            (push text parts))))))
    (when parts
      (string-join (nreverse parts) "\n"))))

(defun inline--responses-output-text (data)
  "Extract model text from Responses API DATA."
  (or
   (let ((output-text (alist-get 'output_text data)))
     (when (stringp output-text)
       output-text))
   (let ((parts nil)
         (output (alist-get 'output data)))
     (cond
      ((vectorp output)
       (dotimes (i (length output))
         (let* ((item (aref output i))
                (content (alist-get 'content item))
                (text (or (alist-get 'text item)
                          (alist-get 'output_text item)
                          (inline--responses-content-text content))))
           (when (stringp text)
             (push text parts)))))
      ((listp output)
       (dolist (item output)
         (let* ((content (alist-get 'content item))
                (text (or (alist-get 'text item)
                          (alist-get 'output_text item)
                          (inline--responses-content-text content))))
           (when (stringp text)
             (push text parts))))))
     (when parts
       (string-join (nreverse parts) "\n")))))

(defun inline-response-parser-openai (body)
  "Extract response text from an OpenAI-compatible BODY.
Falls back to BODY if parsing fails."
  (condition-case _
      (let* ((json-object-type 'alist)
             (json-array-type 'vector)
             (json-key-type 'symbol)
             (data (json-read-from-string body))
             (choices (alist-get 'choices data)))
        (or
         (inline--responses-output-text data)
         (cond
          ((vectorp choices)
           (let* ((choice (aref choices 0))
                  (message (alist-get 'message choice))
                  (content (or (alist-get 'content message)
                               (alist-get 'text choice))))
             (or content body)))
          ((listp choices)
           (let* ((choice (car choices))
                  (message (alist-get 'message choice))
                  (content (or (alist-get 'content message)
                               (alist-get 'text choice))))
             (or content body)))
          (t body))))
    (error body)))

(defun inline-response-cleaner-strip-fences (text)
  "Strip Markdown code fences from TEXT when the entire response is fenced."
  (let ((trimmed (string-trim text)))
    (if (and (string-prefix-p "```" trimmed)
             (string-suffix-p "```" trimmed))
        (let* ((lines (split-string trimmed "\n"))
               (body (string-join (butlast (cdr lines)) "\n")))
          (string-trim body))
      text)))

(defun inline-backend-http (task request callback)
  "Send REQUEST for TASK via HTTP and invoke CALLBACK."
  (let ((key (inline--api-key)))
    (unless inline-api-url
      (funcall callback task :error "inline-api-url is not set")
      (cl-return-from inline-backend-http))
    (unless (and key (not (string-empty-p key)))
      (funcall callback task :error "API key not found (env/auth-source)")
      (cl-return-from inline-backend-http))
    (let* ((url-request-method "POST")
           (url-request-extra-headers
            (append `(("Content-Type" . "application/json")
                      ("Authorization" . ,(concat "Bearer " key)))
                    inline-api-extra-headers))
           (url-request-data (json-encode request))
           (buffer (url-retrieve inline-api-url
                                 #'inline--backend-http-callback
                                 (list task callback)
                                 t t)))
      (when (buffer-live-p buffer)
        (setf (inline-task-response-buffer task) buffer
              (inline-task-process task) (get-buffer-process buffer))))))

(defun inline--backend-http-callback (status task callback)
  "Handle HTTP response for TASK and invoke CALLBACK."
  (unwind-protect
      (let* ((err (plist-get status :error))
             (http-status url-http-response-status)
             (body ""))
        (goto-char (point-min))
        (when (re-search-forward "\r?\n\r?\n" nil t)
          (setq body (buffer-substring-no-properties (point) (point-max))))
        (let ((trimmed (string-trim body)))
          (cond
           ((and http-status (>= http-status 200) (< http-status 300))
            (funcall callback task :ok body))
           ((and http-status (not (string-empty-p trimmed)))
            (funcall callback task :error (format "HTTP %s: %s" http-status trimmed)))
           (err
            (funcall callback task :error (format "%s" err)))
           (http-status
            (funcall callback task :error (format "HTTP %s" http-status)))
           (t
            (funcall callback task :error "HTTP request failed")))))
    (when (buffer-live-p (current-buffer))
      (kill-buffer (current-buffer)))))

(provide 'inline-backend)

;;; inline-backend.el ends here
