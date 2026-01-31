;;; efrit-rovodev-manager.el --- Rovodev server lifecycle management -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Free Software Foundation, Inc.

;; Author: Steve Yegge <steve.yegge@gmail.com>
;; Version: 0.4.1
;; Package-Requires: ((emacs "28.1"))
;; Keywords: tools, convenience, ai
;; URL: https://github.com/stevey/efrit

;;; Commentary:
;; Manages the lifecycle of Rovodev HTTP server instances.
;; Handles server startup, shutdown, healthchecks, and status tracking.
;;
;; Pure Executor principle: This module only manages process lifecycle.
;; It does NOT make decisions about when to use Rovodev - that's determined
;; by configuration (efrit-use-rovodev).

;;; Code:

(require 'json)
(require 'url)
(require 'efrit-config)
(require 'efrit-log)

;;; Server Process Management

(defvar efrit-rovodev--server-process nil
  "Current Rovodev server process, if any.")

(defvar efrit-rovodev--server-port nil
  "Port of currently running Rovodev server.")

(defvar efrit-rovodev--server-ready nil
  "Non-nil when server is ready and MCP servers loaded.")

(defun efrit-rovodev-manager-server-running-p ()
  "Return non-nil if Rovodev server is running."
  (and efrit-rovodev--server-process
       (process-live-p efrit-rovodev--server-process)))

(defun efrit-rovodev-manager-get-port ()
  "Return port of running Rovodev server, or nil if not running."
  (when (efrit-rovodev-manager-server-running-p)
    efrit-rovodev--server-port))

(defun efrit-rovodev-manager-start-server (&optional port)
  "Start Rovodev server on PORT (default `efrit-rovodev-server-port').
Returns t on success, signals error on failure.
CRITICAL: Always uses --disable-session-token flag for API access."
  (interactive)
  (when (efrit-rovodev-manager-server-running-p)
    (error "Rovodev server already running on port %s" efrit-rovodev--server-port))
  
  (let* ((target-port (or port efrit-rovodev-server-port))
         (command (list efrit-rovodev-command "rovodev" "serve"
                       (number-to-string target-port)
                       "--disable-session-token"))
         (buffer (generate-new-buffer " *rovodev-server*")))
    
    (efrit-log 'info "Starting Rovodev server: %s" (string-join command " "))
    
    (condition-case err
        (progn
          (setq efrit-rovodev--server-process
                (make-process
                 :name "rovodev-server"
                 :buffer buffer
                 :command command
                 :sentinel #'efrit-rovodev-manager--server-sentinel
                 :filter #'efrit-rovodev-manager--server-filter))
          
          (setq efrit-rovodev--server-port target-port
                efrit-rovodev--server-ready nil)
          
          ;; Wait for server to initialize MCP servers
          (efrit-log 'info "Waiting %ds for MCP servers to initialize..."
                     efrit-rovodev-server-startup-wait)
          (sleep-for efrit-rovodev-server-startup-wait)
          
          ;; Verify server is healthy
          (unless (efrit-rovodev-manager-healthcheck target-port)
            (efrit-rovodev-manager-stop-server)
            (error "Rovodev server failed healthcheck"))
          
          (setq efrit-rovodev--server-ready t)
          (message "Rovodev server started on port %d" target-port)
          t)
      (error
       (efrit-log 'error "Failed to start Rovodev server: %s" (error-message-string err))
       (when efrit-rovodev--server-process
         (delete-process efrit-rovodev--server-process)
         (setq efrit-rovodev--server-process nil
               efrit-rovodev--server-port nil))
       (signal (car err) (cdr err))))))

(defun efrit-rovodev-manager-stop-server ()
  "Stop running Rovodev server."
  (interactive)
  (when efrit-rovodev--server-process
    (efrit-log 'info "Stopping Rovodev server on port %s" efrit-rovodev--server-port)
    (let ((buffer (and (processp efrit-rovodev--server-process)
                       (process-buffer efrit-rovodev--server-process))))
      (when (process-live-p efrit-rovodev--server-process)
        (delete-process efrit-rovodev--server-process))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))
    (setq efrit-rovodev--server-process nil
          efrit-rovodev--server-port nil
          efrit-rovodev--server-ready nil)
    (message "Rovodev server stopped")))

(defun efrit-rovodev-manager--server-sentinel (proc event)
  "Handle Rovodev server process PROC state changes (EVENT)."
  (unless (process-live-p proc)
    (efrit-log 'warn "Rovodev server process exited: %s" (string-trim event))
    (setq efrit-rovodev--server-process nil
          efrit-rovodev--server-port nil
          efrit-rovodev--server-ready nil)
    (message "Rovodev server stopped unexpectedly")))

(defun efrit-rovodev-manager--server-filter (proc output)
  "Handle OUTPUT from Rovodev server PROC."
  ;; Log server output for debugging
  (when (buffer-live-p (process-buffer proc))
    (with-current-buffer (process-buffer proc)
      (goto-char (point-max))
      (insert output)))
  ;; Check for ready marker
  (when (string-match-p "Starting server on" output)
    (efrit-log 'info "Rovodev server ready")))

(defun efrit-rovodev-manager-ensure-server-running (&optional port)
  "Ensure Rovodev server is running on PORT.
Starts server if not already running. Returns port number."
  (if (efrit-rovodev-manager-server-running-p)
      (efrit-rovodev-manager-get-port)
    (efrit-rovodev-manager-start-server port)
    (or efrit-rovodev--server-port
        (error "Failed to start Rovodev server"))))

;;; Health Check

(defun efrit-rovodev-manager-healthcheck (port)
  "Check health of Rovodev server on PORT.
Returns health data alist on success, nil on failure."
  (condition-case err
      (let* ((url (format "http://localhost:%d/healthcheck" port))
             (url-request-method "GET")
             (url-request-extra-headers nil)
             (response-buffer nil))
        
        (with-temp-buffer
          (setq response-buffer (current-buffer))
          (url-insert-file-contents url)
          (goto-char (point-min))
          (let* ((json-object-type 'alist)
                 (json-array-type 'list)
                 (json-key-type 'symbol)
                 (data (json-read)))
            (efrit-log 'debug "Healthcheck response: %S" data)
            data)))
    (error
     (efrit-log 'error "Healthcheck failed: %s" (error-message-string err))
     nil)))

(defun efrit-rovodev-manager-wait-for-mcp-servers (port timeout)
  "Wait up to TIMEOUT seconds for MCP servers to be running on PORT.
Returns t if all MCP servers are running, nil on timeout."
  (let ((deadline (+ (float-time) timeout))
        (ready nil))
    (while (and (not ready) (< (float-time) deadline))
      (condition-case nil
          (when-let* ((health (efrit-rovodev-manager-healthcheck port))
                      (mcp-servers (alist-get 'mcp_servers health)))
            (setq ready
                  (cl-every (lambda (server)
                             (equal (cdr server) "running"))
                           mcp-servers)))
        (error nil))
      (unless ready
        (sleep-for 0.5)))
    ready))

(defun efrit-rovodev-manager-status ()
  "Display status of Rovodev server."
  (interactive)
  (if (efrit-rovodev-manager-server-running-p)
      (let* ((port efrit-rovodev--server-port)
             (health (efrit-rovodev-manager-healthcheck port)))
        (if health
            (message "Rovodev server running on port %d\nStatus: %s\nVersion: %s\nMCP servers: %S"
                     port
                     (alist-get 'status health)
                     (alist-get 'version health)
                     (alist-get 'mcp_servers health))
          (message "Rovodev server running on port %d but healthcheck failed" port)))
    (message "Rovodev server not running")))

(provide 'efrit-rovodev-manager)

;;; efrit-rovodev-manager.el ends here
