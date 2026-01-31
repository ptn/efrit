;;; test-rovodev-integration.el --- Integration tests for Rovodev CLI -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Free Software Foundation, Inc.

;; Author: Efrit Team
;; Keywords: tests, rovodev, integration

;;; Commentary:
;; Integration tests for Rovodev CLI adapter.
;; These tests require actual Rovodev CLI to be installed and configured.
;;
;; Run with:
;;   emacs -batch -L lisp/core -L lisp/interfaces -l ert \
;;     -l test/test-rovodev-integration.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)

;;; Prerequisites Tests

(ert-deftest test-rovodev-cli-available ()
  "Verify Rovodev CLI is installed and accessible."
  (should (= 0 (call-process "which" nil nil nil "acli")))
  (should (= 0 (call-process "acli" nil nil nil "--version"))))

(ert-deftest test-rovodev-config-exists ()
  "Verify Rovodev configuration file exists."
  (should (file-exists-p (expand-file-name "~/.rovodev/config.yml"))))

;;; Configuration Tests (require implementation)

(ert-deftest test-rovodev-configuration-options ()
  "Test that Rovodev configuration options are defined."
  :expected-result (if (boundp 'efrit-use-rovodev) :passed :failed)
  (when (boundp 'efrit-use-rovodev)
    (should (memq efrit-use-rovodev '(nil oneshot server hybrid)))
    (should (boundp 'efrit-rovodev-oneshot-timeout))
    (should (>= efrit-rovodev-oneshot-timeout 60))
    (should (boundp 'efrit-rovodev-server-port))
    (should (= efrit-rovodev-server-port 8123))))

;;; Exit Code Handling Tests

(ert-deftest test-rovodev-exit-code-parsing ()
  "Test that exit codes are properly ignored and stdout is parsed."
  :expected-result (if (fboundp 'efrit-rovodev--is-success-output) :passed :failed)
  (when (fboundp 'efrit-rovodev--is-success-output)
    ;; Success case - has response marker
    (should (efrit-rovodev--is-success-output 
             "Working in /tmp\n─── Response ───\nResult here"))
    
    ;; Error case - contains error keyword
    (should-not (efrit-rovodev--is-success-output 
                 "Error: Something failed"))
    
    ;; Edge case - nonsense output
    (should-not (efrit-rovodev--is-success-output 
                 "Random output without marker"))))

;;; SSE Event Parsing Tests

(ert-deftest test-rovodev-sse-event-types ()
  "Test parsing of all 7 SSE event types."
  :expected-result (if (fboundp 'efrit-rovodev--parse-sse-stream) :passed :failed)
  (when (fboundp 'efrit-rovodev--parse-sse-stream)
    (let ((sample-stream "event: part_start
data: {\"message_id\": \"123\"}

event: part_delta
data: {\"content_delta\": \"Hello\"}

event: part_delta
data: {\"content_delta\": \" World\"}

event: close
data: {}

"))
      (with-temp-buffer
        (insert sample-stream)
        (let ((events (efrit-rovodev--parse-sse-stream (current-buffer))))
          (should (= (length events) 4))
          (should (eq (caar events) 'part_start))
          (should (eq (caadr events) 'part_delta))
          (should (eq (car (nth 2 events)) 'part_delta))
          (should (eq (car (nth 3 events)) 'close)))))))

(ert-deftest test-rovodev-part-delta-accumulation ()
  "Test that part_delta events are accumulated correctly."
  :expected-result (if (fboundp 'efrit-rovodev--handle-sse-response) :passed :failed)
  (when (fboundp 'efrit-rovodev--handle-sse-response)
    (let ((sample-stream "event: part_delta
data: {\"content_delta\": \"Hello\"}

event: part_delta
data: {\"content_delta\": \" \"}

event: part_delta
data: {\"content_delta\": \"World\"}

event: close
data: {}

")
          (result nil))
      (with-temp-buffer
        (insert sample-stream)
        (efrit-rovodev--handle-sse-response 
         (current-buffer)
         (lambda (response error)
           (setq result response)))
        (should (equal result "Hello World"))))))

;;; Stream Consumption Tests

(ert-deftest test-rovodev-stream-blocking ()
  "Test that stream consumption blocking works."
  :expected-result (if (fboundp 'efrit-rovodev-server-send-message) :passed :failed)
  (when (fboundp 'efrit-rovodev-server-send-message)
    (with-temp-buffer
      (let ((efrit-rovodev--stream-active t)
            (efrit-rovodev--pending-messages nil))
        ;; Attempt to send message while stream active
        (efrit-rovodev-server-send-message 
         8123 "session-123" "test message"
         (lambda (r e) nil))
        ;; Should have queued the message
        (should (= (length efrit-rovodev--pending-messages) 1))))))

;;; Error Response Parsing Tests

(ert-deftest test-rovodev-http-404-error ()
  "Test parsing of HTTP 404 session not found error."
  :expected-result (if (fboundp 'efrit-rovodev--handle-http-error) :passed :failed)
  (when (fboundp 'efrit-rovodev--handle-http-error)
    (let ((response (make-hash-table :test 'equal)))
      (puthash "detail" "Session not found" response)
      (should-error (efrit-rovodev--handle-http-error 
                     '(:code 404) response)
                    :type 'error))))

(ert-deftest test-rovodev-http-422-validation-error ()
  "Test parsing of HTTP 422 Pydantic validation error."
  :expected-result (if (fboundp 'efrit-rovodev--handle-http-error) :passed :failed)
  (when (fboundp 'efrit-rovodev--handle-http-error)
    (let* ((error-detail (make-hash-table :test 'equal))
           (response (make-hash-table :test 'equal)))
      (puthash "type" "missing" error-detail)
      (puthash "loc" ["body" "message"] error-detail)
      (puthash "msg" "Field required" error-detail)
      (puthash "detail" (vector error-detail) response)
      (should-error (efrit-rovodev--handle-http-error 
                     '(:code 422) response)
                    :type 'error))))

(ert-deftest test-rovodev-http-401-auth-error ()
  "Test parsing of HTTP 401 authentication error."
  :expected-result (if (fboundp 'efrit-rovodev--handle-http-error) :passed :failed)
  (when (fboundp 'efrit-rovodev--handle-http-error)
    (let ((response (make-hash-table :test 'equal)))
      (puthash "detail" "Authentication required" response)
      (condition-case err
          (efrit-rovodev--handle-http-error '(:code 401) response)
        (error
         ;; Should mention the --disable-session-token flag
         (should (string-match-p "--disable-session-token" 
                                (error-message-string err))))))))

;;; Server Healthcheck Tests (requires running server)

(ert-deftest test-rovodev-server-healthcheck-live ()
  "Test server healthcheck with live server (requires server running)."
  :tags '(:integration :requires-server)
  :expected-result (if (fboundp 'efrit-rovodev-server-healthcheck) :passed :failed)
  (when (fboundp 'efrit-rovodev-server-healthcheck)
    (skip-unless (= 0 (call-process "curl" nil nil nil "-s" 
                                    "http://localhost:8123/healthcheck")))
    (let ((health (efrit-rovodev-server-healthcheck 8123)))
      (should health)
      (should (equal (plist-get health :status) "healthy"))
      (should (plist-get health :version))
      (should (plist-get health :mcp-servers)))))

;;; Session Management Tests (requires running server)

(ert-deftest test-rovodev-session-creation ()
  "Test session creation with live server."
  :tags '(:integration :requires-server)
  :expected-result (if (fboundp 'efrit-rovodev--create-session) :passed :failed)
  (when (fboundp 'efrit-rovodev--create-session)
    (skip-unless (= 0 (call-process "curl" nil nil nil "-s" 
                                    "http://localhost:8123/healthcheck")))
    (let ((session-id (efrit-rovodev--create-session 8123)))
      (should session-id)
      (should (stringp session-id))
      (should (> (length session-id) 0)))))

;;; One-Shot Mode Tests

(ert-deftest test-rovodev-oneshot-simple-command ()
  "Test simple one-shot command execution."
  :tags '(:integration :slow)
  :expected-result (if (fboundp 'efrit-rovodev-oneshot-execute) :passed :failed)
  (when (fboundp 'efrit-rovodev-oneshot-execute)
    (let ((result nil)
          (error-result nil))
      (efrit-rovodev-oneshot-execute 
       "What is 2+2?"
       (lambda (response error)
         (setq result response)
         (setq error-result error)))
      
      ;; Wait for completion (max 90 seconds)
      (with-timeout (90 (ert-fail "One-shot command timed out"))
        (while (and (not result) (not error-result))
          (accept-process-output nil 0.1)))
      
      (should-not error-result)
      (should result)
      (should (stringp result))
      (should (> (length result) 0)))))

;;; Helper Functions for Manual Testing

(defun test-rovodev-manual-oneshot ()
  "Manually test one-shot mode (for interactive testing)."
  (interactive)
  (unless (fboundp 'efrit-rovodev-oneshot-execute)
    (error "Rovodev oneshot implementation not loaded"))
  (let ((command (read-string "Command: " "What is 2+2?")))
    (message "Executing one-shot command: %s" command)
    (efrit-rovodev-oneshot-execute 
     command
     (lambda (response error)
       (if error
           (message "ERROR: %s" error)
         (message "SUCCESS: %s" response))))))

(defun test-rovodev-manual-server ()
  "Manually test server mode (for interactive testing)."
  (interactive)
  (unless (fboundp 'efrit-rovodev-server-send-message)
    (error "Rovodev server implementation not loaded"))
  (let* ((port (read-number "Port: " 8123))
         (session-id (efrit-rovodev--ensure-session port))
         (message (read-string "Message: " "Hello")))
    (message "Sending to session %s: %s" session-id message)
    (efrit-rovodev-server-send-message 
     port session-id message
     (lambda (response error)
       (if error
           (message "ERROR: %s" error)
         (message "SUCCESS: %s" response))))))

(provide 'test-rovodev-integration)

;;; test-rovodev-integration.el ends here
