;;; efrit-rovodev-oneshot.el --- One-shot Rovodev CLI execution -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Free Software Foundation, Inc.

;; Author: Steve Yegge <steve.yegge@gmail.com>
;; Version: 0.4.1
;; Package-Requires: ((emacs "28.1"))
;; Keywords: tools, convenience, ai
;; URL: https://github.com/stevey/efrit

;;; Commentary:
;; Implements one-shot command execution using `acli rovodev run --yolo`.
;; Best suited for efrit-do (single commands).
;;
;; CRITICAL FINDINGS FROM TESTING:
;; - Exit codes are UNRELIABLE (always 0, even for errors)
;; - Must parse stdout for success/error indicators
;; - Timeout must be 90+ seconds for complex tasks
;; - Always use --yolo flag to prevent permission prompts
;;
;; Pure Executor principle: This module only executes CLI commands.
;; It does NOT decide what to execute - that comes from Claude.

;;; Code:

(require 'json)
(require 'efrit-config)
(require 'efrit-log)

;;; One-Shot Execution

(defun efrit-rovodev-oneshot-request (prompt callback)
  "Execute PROMPT via one-shot Rovodev CLI.
Calls CALLBACK with (response error) when complete.
Uses --yolo flag to prevent permission prompts.

CRITICAL: Exit codes are unreliable - parse stdout for errors."
  (let* ((command (list efrit-rovodev-command "rovodev" "run" "--yolo" prompt))
         (buffer (generate-new-buffer " *rovodev-oneshot*"))
         (start-time (float-time))
         (process nil))
    
    (efrit-log 'info "Starting one-shot Rovodev: %s" (substring prompt 0 (min 60 (length prompt))))
    (efrit-log 'debug "Command: %s" (string-join command " "))
    
    (condition-case err
        (progn
          (setq process
                (make-process
                 :name "rovodev-oneshot"
                 :buffer buffer
                 :command command
                 :sentinel (lambda (proc event)
                            (efrit-rovodev-oneshot--handle-completion
                             proc event callback start-time))
                 :filter #'efrit-rovodev-oneshot--filter))
          
          ;; Set up timeout timer
          (run-at-time efrit-rovodev-oneshot-timeout nil
                       (lambda ()
                         (when (and process (process-live-p process))
                           (efrit-log 'error "One-shot timeout after %ds" 
                                      efrit-rovodev-oneshot-timeout)
                           (delete-process process)
                           (funcall callback nil
                                   (format "Rovodev timeout after %d seconds"
                                          efrit-rovodev-oneshot-timeout))))))
      (error
       (efrit-log 'error "Failed to start one-shot process: %s" 
                  (error-message-string err))
       (when (buffer-live-p buffer)
         (kill-buffer buffer))
       (funcall callback nil (error-message-string err))))))

(defun efrit-rovodev-oneshot--filter (proc output)
  "Accumulate OUTPUT from one-shot PROC."
  (when (buffer-live-p (process-buffer proc))
    (with-current-buffer (process-buffer proc)
      (goto-char (point-max))
      (insert output))))

(defun efrit-rovodev-oneshot--handle-completion (proc event callback start-time)
  "Handle completion of one-shot PROC with EVENT.
Calls CALLBACK with parsed response.
CRITICAL: Exit code is unreliable - parse stdout instead."
  (let ((elapsed (- (float-time) start-time))
        (exit-code (process-exit-status proc))
        (buffer (process-buffer proc)))
    
    (efrit-log 'debug "One-shot process completed: exit=%d elapsed=%.1fs event=%s"
               exit-code elapsed (string-trim event))
    
    (if (not (buffer-live-p buffer))
        (funcall callback nil "Process buffer was killed")
      
      (with-current-buffer buffer
        (let ((output (buffer-string)))
          
          ;; CRITICAL: Do NOT rely on exit-code (always 0)
          ;; Parse output for error indicators
          (cond
           ;; Check for error keywords
           ((string-match-p "\\(Error\\|error\\|failed\\|exception\\|Exception\\)" output)
            (efrit-log 'error "One-shot detected error in output")
            (funcall callback nil (format "Rovodev error: %s" output)))
           
           ;; Check for valid response marker and extract content
           ;; Split on "─── Response" header and extract content until footer dashes
           ((string-match "─── Response ─+\n" output)
            (let* ((start (match-end 0))
                   (remaining (substring output start))
                   ;; Find the footer (line of dashes)
                   (end (string-match "\n─+\n" remaining))
                   (response-text (if end
                                     (substring remaining 0 end)
                                   remaining)))
              (efrit-log 'info "One-shot completed successfully in %.1fs" elapsed)
              (funcall callback (efrit-rovodev-oneshot--parse-response (string-trim response-text)) nil)))
           
           ;; Unexpected output format
           (t
            (efrit-log 'warn "One-shot output format unexpected")
            (funcall callback nil (format "Unexpected output format: %s" 
                                         (substring output 0 (min 200 (length output))))))))
        
        ;; Clean up buffer
        (kill-buffer buffer)))))

(defun efrit-rovodev-oneshot--parse-response (response-text)
  "Parse RESPONSE-TEXT from Rovodev output.
Attempts to extract structured response data.
Returns parsed data or raw text if parsing fails."
  (condition-case err
      (let* ((trimmed (string-trim response-text))
             ;; Try to parse as JSON first
             (json-object-type 'alist)
             (json-array-type 'list)
             (json-key-type 'symbol))
        (if (and (> (length trimmed) 0)
                 (memq (aref trimmed 0) '(?{ ?\[)))
            ;; Looks like JSON
            (json-read-from-string trimmed)
          ;; Plain text response
          trimmed))
    (error
     (efrit-log 'debug "Could not parse response as JSON: %s" 
                (error-message-string err))
     response-text)))

;;; Utility Functions

(defun efrit-rovodev-oneshot-test (prompt)
  "Test one-shot execution with PROMPT.
Displays result in message area."
  (interactive "sPrompt: ")
  (efrit-rovodev-oneshot-request
   prompt
   (lambda (response error)
     (if error
         (message "ERROR: %s" error)
       (message "SUCCESS: %S" response)))))

(provide 'efrit-rovodev-oneshot)

;;; efrit-rovodev-oneshot.el ends here
