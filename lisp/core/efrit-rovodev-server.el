;;; efrit-rovodev-server.el --- Rovodev HTTP server client -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Free Software Foundation, Inc.

;; Author: Steve Yegge <steve.yegge@gmail.com>
;; Version: 0.4.1
;; Package-Requires: ((emacs "28.1"))
;; Keywords: tools, convenience, ai
;; URL: https://github.com/stevey/efrit

;;; Commentary:
;; HTTP client for Rovodev server mode (persistent server).
;; Best suited for efrit-chat and efrit-agent (multi-turn conversations).
;;
;; CRITICAL FINDINGS FROM TESTING:
;; - Server requires --disable-session-token flag
;; - 7 SSE event types: user-prompt, part_start, part_delta, 
;;   on_call_tools_start, tool-return, request-usage, close
;; - MUST accumulate part_delta events for full response
;; - MUST consume entire stream (wait for 'close') before next message
;; - Stream consumption blocking required (single-threaded per session)
;;
;; Pure Executor principle: This module only communicates with the server.
;; It does NOT decide what to send - that comes from Claude.

;;; Code:

(require 'json)
(require 'url)
(require 'url-http)
(require 'efrit-config)
(require 'efrit-log)
(require 'efrit-rovodev-manager)

;;; Session Management

(defvar-local efrit-rovodev--session-id nil
  "Current Rovodev session ID for this buffer.")

(defvar-local efrit-rovodev--stream-active nil
  "Non-nil when SSE stream is being consumed for this session.")

(defvar-local efrit-rovodev--pending-messages nil
  "Queue of messages waiting for stream to complete.")

(defun efrit-rovodev-server-ensure-session (port)
  "Ensure session exists for current buffer on PORT.
Creates new session if needed. Returns session ID."
  (unless efrit-rovodev--session-id
    (setq efrit-rovodev--session-id
          (efrit-rovodev-server--create-session port)))
  efrit-rovodev--session-id)

(defun efrit-rovodev-server--create-session (port)
  "Create new session on Rovodev server at PORT.
Returns session ID string."
  (efrit-log 'info "Creating Rovodev session on port %d" port)
  (let* ((url (format "http://localhost:%d/v3/sessions/create" port))
         (response (efrit-rovodev-server--http-post url nil)))
    (let ((session-id (alist-get 'session_id response)))
      (efrit-log 'debug "Created session: %s" session-id)
      session-id)))

(defun efrit-rovodev-server--restore-session (port session-id)
  "Restore existing SESSION-ID on server at PORT."
  (efrit-log 'info "Restoring Rovodev session: %s" session-id)
  (let ((url (format "http://localhost:%d/v3/sessions/%s/restore" 
                     port session-id)))
    (efrit-rovodev-server--http-post url nil)))

;;; HTTP Request Helpers

(defun efrit-rovodev-server--http-post (url data)
  "POST DATA to URL, return parsed JSON response.
Handles errors and returns alist."
  (let* ((url-request-method "POST")
         (url-request-extra-headers
          (when data
            '(("Content-Type" . "application/json"))))
         (url-request-data
          (when data
            (encode-coding-string (json-encode data) 'utf-8)))
         (response-buffer nil))
    
    (with-temp-buffer
      (setq response-buffer (current-buffer))
      (condition-case err
          (progn
            (url-insert-file-contents url)
            (goto-char (point-min))
            (let* ((json-object-type 'alist)
                   (json-array-type 'list)
                   (json-key-type 'symbol))
              (json-read)))
        (file-error
         ;; Handle HTTP errors
         (efrit-rovodev-server--handle-http-error err))))))

(defun efrit-rovodev-server--http-get (url)
  "GET from URL, return parsed JSON response."
  (let ((url-request-method "GET"))
    (with-temp-buffer
      (url-insert-file-contents url)
      (goto-char (point-min))
      (let* ((json-object-type 'alist)
             (json-array-type 'list)
             (json-key-type 'symbol))
        (json-read)))))

(defun efrit-rovodev-server--handle-http-error (err)
  "Parse HTTP error ERR from Rovodev server.
Handles 404, 422 (validation), 401 (auth) responses."
  (let* ((error-data (cdr err))
         (status-string (car error-data))
         (error-message
          (cond
           ((string-match-p "404" status-string)
            "Session not found")
           ((string-match-p "422" status-string)
            "Validation error: Check request format")
           ((string-match-p "401" status-string)
            "Authentication required (missing --disable-session-token flag?)")
           (t
            (format "HTTP error: %s" status-string)))))
    (error "Rovodev: %s" error-message)))

;;; Message Sending and Streaming

(defun efrit-rovodev-server-send-message (port session-id message callback)
  "Send MESSAGE to Rovodev server at PORT for SESSION-ID.
Calls CALLBACK with (response error) when stream completes.
CRITICAL: Blocks if stream is active (single-threaded per session)."
  (if efrit-rovodev--stream-active
      ;; Queue message for later
      (progn
        (push (list message callback) efrit-rovodev--pending-messages)
        (efrit-log 'debug "Queuing message (stream active)"))
    ;; Send immediately
    (efrit-rovodev-server--do-send-message port session-id message callback)))

(defun efrit-rovodev-server--do-send-message (port session-id message callback)
  "Internal: Actually send MESSAGE to server.
Sets stream active flag and processes message."
  (setq efrit-rovodev--stream-active t)
  
  ;; Set the message
  (condition-case err
      (progn
        (efrit-rovodev-server--set-message port message)
        
        ;; Stream the response
        (efrit-rovodev-server--stream
         port session-id
         (lambda (response error)
           (setq efrit-rovodev--stream-active nil)
           (funcall callback response error)
           
           ;; Process queued messages
           (when-let ((next-msg (pop efrit-rovodev--pending-messages)))
             (efrit-rovodev-server--do-send-message
              port session-id
              (car next-msg)
              (cadr next-msg))))))
    (error
     (setq efrit-rovodev--stream-active nil)
     (funcall callback nil (error-message-string err)))))

(defun efrit-rovodev-server--set-message (port message)
  "Set MESSAGE on Rovodev server at PORT for current session."
  (let ((url (format "http://localhost:%d/v3/set_chat_message" port))
        (data `((message . ,message)
                (enable_deep_plan . :json-false))))
    (efrit-rovodev-server--http-post url data)))

(defun efrit-rovodev-server--stream (port session-id callback)
  "Stream response from Rovodev server at PORT for SESSION-ID.
Calls CALLBACK with (response error) when stream completes.
CRITICAL: Must consume entire stream (wait for 'close' event)."
  (let ((url (format "http://localhost:%d/v3/stream_chat" port))
        (buffer (generate-new-buffer " *rovodev-stream*"))
        (start-time (float-time)))
    
    (efrit-log 'debug "Starting SSE stream")
    
    (condition-case err
        (with-current-buffer buffer
          ;; Use url-retrieve for streaming
          (url-retrieve
           url
           (lambda (status)
             (efrit-rovodev-server--handle-stream-response
              status buffer callback start-time))
           nil t))
      (error
       (efrit-log 'error "Stream error: %s" (error-message-string err))
       (when (buffer-live-p buffer)
         (kill-buffer buffer))
       (funcall callback nil (error-message-string err))))))

(defun efrit-rovodev-server--handle-stream-response (status buffer callback start-time)
  "Handle streaming response in BUFFER with STATUS.
Calls CALLBACK when stream completes."
  (let ((elapsed (- (float-time) start-time)))
    (if (plist-get status :error)
        (progn
          (efrit-log 'error "Stream failed: %S" (plist-get status :error))
          (funcall callback nil (format "Stream error: %S" (plist-get status :error)))
          (kill-buffer buffer))
      
      (with-current-buffer buffer
        ;; Skip HTTP headers
        (goto-char (point-min))
        (re-search-forward "\r?\n\r?\n" nil t)
        
        ;; Parse SSE events
        (let ((response (efrit-rovodev-server--parse-sse-stream (current-buffer))))
          (efrit-log 'info "Stream completed in %.1fs" elapsed)
          (funcall callback response nil)
          (kill-buffer buffer))))))

;;; SSE Event Parsing

(defun efrit-rovodev-server--parse-sse-stream (buffer)
  "Parse SSE events from BUFFER.
Returns accumulated response text.
CRITICAL: Must accumulate part_delta events."
  (with-current-buffer buffer
    (let ((accumulated-text "")
          (events '())
          (current-event nil)
          (current-data "")
          (stream-complete nil))
      
      (goto-char (point-min))
      (while (not (eobp))
        (let ((line (buffer-substring-no-properties
                     (line-beginning-position)
                     (line-end-position))))
          
          (cond
           ;; Event type line
           ((string-prefix-p "event: " line)
            (setq current-event (substring line 7)))
           
           ;; Data line
           ((string-prefix-p "data: " line)
            (setq current-data (substring line 6)))
           
           ;; Empty line - event complete
           ((string-empty-p (string-trim line))
            (when current-event
              ;; Parse and process event
              (let* ((event-type (intern current-event))
                     (parsed-data
                      (condition-case nil
                          (let ((json-object-type 'alist)
                                (json-array-type 'list)
                                (json-key-type 'symbol))
                            (json-read-from-string current-data))
                        (error nil))))
                
                (push (cons event-type parsed-data) events)
                
                ;; Handle specific event types
                (pcase event-type
                  ('part_delta
                   ;; CRITICAL: Accumulate streaming text
                   (when-let ((delta (alist-get 'content_delta parsed-data)))
                     (setq accumulated-text (concat accumulated-text delta))
                     (efrit-log 'debug "Delta: %s" (substring delta 0 (min 50 (length delta))))))
                  
                  ('close
                   ;; Stream complete
                   (setq stream-complete t)
                   (efrit-log 'debug "Stream close event received"))
                  
                  ('on_call_tools_start
                   ;; Tool execution begins
                   (when-let ((tool-name (alist-get 'tool_name parsed-data)))
                     (efrit-log 'info "Tool execution: %s" tool-name)))
                  
                  ('tool-return
                   ;; Tool result available
                   (when-let ((tool-id (alist-get 'tool_call_id parsed-data)))
                     (efrit-log 'debug "Tool completed: %s" tool-id)))
                  
                  (_ nil)))
              
              (setq current-event nil
                    current-data ""))))
          
          (forward-line 1)))
      
      ;; Return accumulated text if stream completed
      (if stream-complete
          accumulated-text
        (progn
          (efrit-log 'warn "Stream incomplete (no close event)")
          accumulated-text)))))

;;; High-Level Request Interface

(defun efrit-rovodev-server-request (prompt callback)
  "Send PROMPT to Rovodev server, call CALLBACK with (response error).
Ensures server is running and session exists.
This is the main entry point for server mode requests."
  (condition-case err
      (let* ((port (efrit-rovodev-manager-ensure-server-running))
             (session-id (efrit-rovodev-server-ensure-session port)))
        
        (efrit-log 'info "Sending message to session %s" session-id)
        
        (efrit-rovodev-server-send-message
         port session-id prompt callback))
    (error
     (efrit-log 'error "Server request failed: %s" (error-message-string err))
     (funcall callback nil (error-message-string err)))))

;;; Utility Functions

(defun efrit-rovodev-server-test (prompt)
  "Test server mode with PROMPT.
Displays result in message area."
  (interactive "sPrompt: ")
  (efrit-rovodev-server-request
   prompt
   (lambda (response error)
     (if error
         (message "ERROR: %s" error)
       (message "SUCCESS: %s" (substring response 0 (min 200 (length response))))))))

(provide 'efrit-rovodev-server)

;;; efrit-rovodev-server.el ends here
