# Rovodev CLI Integration Testing Guide

This guide provides a systematic approach to testing the Rovodev CLI integration for Efrit.

## Prerequisites

Before running any tests, ensure:
1. Rovodev CLI (`acli`) is installed
2. `~/.rovodev/config.yml` is configured with model settings
3. Efrit's MCP server can start (`cd mcp && npm install`)
4. You have a working Anthropic API key

## Test Levels

### Level 0: Quick Smoke Test (1 minute)

Verify Rovodev is working at all:

```bash
# Check CLI exists
acli --version

# Quick one-shot test
acli rovodev run "What is 2+2?"

# Should return a response in ~20 seconds
```

### Level 1: Prerequisites Test (5 minutes)

Run the automated prerequisites checker:

```bash
cd /Users/ptorres/code/efrit
chmod +x test/test-rovodev-prerequisites.sh
./test/test-rovodev-prerequisites.sh
```

This verifies:
- ✓ CLI installation
- ✓ Configuration file
- ✓ One-shot mode (with exit code 0 behavior)
- ✓ Server mode (with --disable-session-token)
- ✓ MCP servers status
- ✓ Efrit MCP server can start

**Expected output:** All tests pass with green checkmarks.

**If tests fail:**
- Install acli: https://docs.rovodev.ai/install
- Configure ~/.rovodev/config.yml
- Check port 8123 is available
- Run `npm install` in efrit/mcp directory

### Level 2: Implementation Tests (After coding)

Once you've implemented the integration, test incrementally:

#### Phase 1: Configuration

```elisp
;; In Emacs, evaluate:
(require 'efrit-config)

;; Check variables exist
efrit-use-rovodev                    ; Should be nil (default)
efrit-rovodev-oneshot-timeout        ; Should be 90
efrit-rovodev-server-port            ; Should be 8123
efrit-rovodev-server-startup-wait    ; Should be 5

;; Try setting modes
(setq efrit-use-rovodev 'oneshot)
(setq efrit-use-rovodev 'server)
(setq efrit-use-rovodev 'hybrid)
(setq efrit-use-rovodev nil)
```

#### Phase 2: One-Shot Module

```elisp
;; Load module
(require 'efrit-rovodev-oneshot)

;; Check functions exist
(fboundp 'efrit-rovodev-oneshot-execute)
(fboundp 'efrit-rovodev--handle-oneshot-complete)
(fboundp 'efrit-rovodev--is-success-output)

;; Test exit code parsing
(efrit-rovodev--is-success-output "─── Response ───\nResult")  ; Should be t
(efrit-rovodev--is-success-output "Error: failed")             ; Should be nil

;; Test actual execution (async, takes ~20-45s)
(efrit-rovodev-oneshot-execute 
 "What is 2+2?"
 (lambda (response error)
   (if error
       (message "ERROR: %s" error)
     (message "SUCCESS: %s" response))))
```

#### Phase 3: Server Module

```bash
# Terminal 1: Start server
acli rovodev serve 8123 --disable-session-token

# Wait 5 seconds for MCP servers
sleep 5

# Verify healthy
curl -s http://localhost:8123/healthcheck | jq .
```

```elisp
;; Terminal 2: Emacs
(require 'efrit-rovodev-server)

;; Test healthcheck
(efrit-rovodev-server-healthcheck 8123)
;; Should return: (:status "healthy" :version "0.13.40" :mcp-servers #<hash-table>)

;; Test session creation
(setq test-session-id (efrit-rovodev--create-session 8123))
;; Should return: "w13ad3b1-xxxxx..."

;; Test SSE parsing
(with-temp-buffer
  (insert "event: part_delta\ndata: {\"content_delta\": \"Hello\"}\n\n")
  (insert "event: close\ndata: {}\n\n")
  (efrit-rovodev--parse-sse-stream (current-buffer)))
;; Should return list of events

;; Test message sending (async)
(efrit-rovodev-server-send-message 
 8123 test-session-id "What is 2+2?"
 (lambda (response error)
   (if error
       (message "ERROR: %s" error)
     (message "RESPONSE: %s" response))))
```

#### Phase 4: Integration with efrit-do

```elisp
;; Enable oneshot mode
(setq efrit-use-rovodev 'oneshot)

;; Test efrit-do
M-x efrit-do RET "List files in current directory" RET

;; Should:
;; 1. Take 20-45 seconds
;; 2. Show progress in *efrit-progress* buffer
;; 3. Execute tools via MCP
;; 4. Display results
;; 5. NOT timeout
```

#### Phase 5: Integration with efrit-chat

```bash
# Ensure server is running
acli rovodev serve 8123 --disable-session-token &
```

```elisp
;; Enable server mode
(setq efrit-use-rovodev 'server)

;; Start chat
M-x efrit-chat RET

;; In chat buffer, send messages:
;; "Hello, can you help me?"
;; "Create a test file"
;; "List all files"

;; Should:
;; 1. Create session in <500ms
;; 2. Maintain context across messages
;; 3. Stream responses incrementally
;; 4. NOT show "chat in progress" errors
;; 5. Buffer-local variable efrit-rovodev--session-id should be set
```

### Level 3: Automated Test Suite

Run the ERT tests:

```bash
cd /Users/ptorres/code/efrit

# Run all tests
emacs -batch -L lisp/core -L lisp/interfaces -L test \
  -l ert -l test/test-rovodev-integration.el \
  -f ert-run-tests-batch-and-exit

# Run only fast tests (skip integration)
emacs -batch -L lisp/core -L lisp/interfaces -L test \
  -l ert -l test/test-rovodev-integration.el \
  --eval '(ert-run-tests-batch-and-exit (ert-select-tests (quote (not (tag :integration))))))'

# Run only integration tests (requires server)
emacs -batch -L lisp/core -L lisp/interfaces -L test \
  -l ert -l test/test-rovodev-integration.el \
  --eval '(ert-run-tests-batch-and-exit (ert-select-tests (quote (tag :integration))))'
```

### Level 4: Error Scenario Testing

Test edge cases and error handling:

#### 1. Missing --disable-session-token

```bash
# Start server WITHOUT flag
acli rovodev serve 8124  # note: no --disable-session-token
```

```elisp
(setq efrit-rovodev-server-port 8124)
(setq efrit-use-rovodev 'server)
M-x efrit-chat RET
;; Send a message

;; Should get error mentioning "--disable-session-token flag?"
```

#### 2. Session Not Found

```elisp
(with-current-buffer "*efrit-chat*"
  (setq-local efrit-rovodev--session-id "fake-session-12345")
  ;; Try to send message
  ;; Should get "Session not found" error
)
```

#### 3. Server Not Running

```bash
# Stop server
pkill -f "acli rovodev serve"
```

```elisp
(setq efrit-use-rovodev 'server)
M-x efrit-chat RET
;; Should get connection error with actionable message
```

#### 4. Stream Consumption Blocking

```elisp
(setq efrit-use-rovodev 'server)
M-x efrit-chat RET

;; Send: "Count to 100 slowly and show each number"
;; Immediately send: "What is 2+2?"

;; Should:
;; 1. Queue the second message
;; 2. Show "Rovodev: Queuing message (stream active)"
;; 3. Send second message after first completes
;; 4. NOT show "chat already in progress" error
```

#### 5. Timeout Handling

```elisp
(setq efrit-rovodev-oneshot-timeout 5)  ; Very short timeout
(setq efrit-use-rovodev 'oneshot)
M-x efrit-do RET "Do a very complex task that takes 30 seconds" RET

;; Should timeout with clear error message
;; Then restore timeout:
(setq efrit-rovodev-oneshot-timeout 90)
```

#### 6. Invalid Command (Exit Code 0)

```elisp
(setq efrit-use-rovodev 'oneshot)
M-x efrit-do RET "xyzabc123 complete nonsense gibberish" RET

;; Should:
;; 1. Return exit code 0 (expected!)
;; 2. Parse stdout to detect it's nonsense
;; 3. Display polite "can't do that" message
;; 4. NOT treat as success just because exit code is 0
```

## Performance Benchmarks

Track these metrics during testing:

| Operation | Expected Time | Threshold |
|-----------|--------------|-----------|
| Simple oneshot | ~20s | <30s |
| Complex oneshot | ~45s | <90s |
| Server startup | 3-5s | <10s |
| Session creation | <500ms | <1s |
| Session restoration | <500ms | <1s |
| First message (server) | 5-10s | <15s |
| Subsequent messages | 2-5s | <10s |

## Success Criteria Checklist

### Core Functionality
- [ ] Configuration options exist and work
- [ ] Backward compatibility maintained (nil = direct API)
- [ ] All three modes work: oneshot, server, hybrid

### One-Shot Mode
- [ ] Simple commands complete in ~20s
- [ ] Complex commands complete in ~45s
- [ ] Exit codes ignored (always 0)
- [ ] Stdout parsed for success/error
- [ ] Response markers detected
- [ ] Errors detected via string matching
- [ ] No timeouts with 90s setting

### Server Mode
- [ ] Server starts with --disable-session-token
- [ ] Healthcheck returns status + MCP servers
- [ ] Session creation <500ms
- [ ] Session restoration <500ms
- [ ] SSE events parsed (all 7 types)
- [ ] part_delta accumulation works
- [ ] Stream consumption blocking works
- [ ] No "chat in progress" errors
- [ ] Context persists across messages

### Error Handling
- [ ] HTTP 404 → "Session not found"
- [ ] HTTP 401 → Mentions flag
- [ ] HTTP 422 → Validation details
- [ ] Connection errors actionable
- [ ] Timeout errors clear

### Hybrid Mode
- [ ] Auto-selects oneshot for efrit-do
- [ ] Auto-selects server for efrit-chat
- [ ] Auto-selects server for efrit-agent

## Debugging Tips

### View Rovodev Server Logs

```bash
# Run in foreground to see logs
acli rovodev serve 8123 --disable-session-token

# Or tail log file if running in background
tail -f /tmp/rovodev-server.log
```

### Capture SSE Stream

```bash
# Set a message first
curl -X POST http://localhost:8123/v3/set_chat_message \
  -H "Content-Type: application/json" \
  -d '{"message": "test", "enable_deep_plan": false}'

# Capture full SSE stream
curl -N http://localhost:8123/v3/stream_chat > sse_output.txt

# Analyze events
grep "^event:" sse_output.txt
```

### Check Exit Codes

```bash
# Run command and check exit code
acli rovodev run "test command"
echo $?  # Will be 0 even for errors!

# With nonsense
acli rovodev run "xyzabc123 gibberish"
echo $?  # Still 0!
```

### Test MCP Server Connection

```bash
# Check if MCP server is running
ps aux | grep "node.*mcp"

# Check healthcheck includes efrit MCP
curl -s http://localhost:8123/healthcheck | jq '.mcp_servers'
```

## Continuous Testing During Development

After each module implementation:

1. **Compile:** `make compile`
2. **Test module:** Load in Emacs and test functions
3. **Integration test:** Test with efrit-do or efrit-chat
4. **Commit:** `git add -A && git commit -m "message" && git push`
5. **Track:** Update beads issue status

## Common Issues & Solutions

| Issue | Solution |
|-------|----------|
| "command not found: acli" | Install: https://docs.rovodev.ai/install |
| "Authentication required" | Add --disable-session-token flag |
| "Chat already in progress" | Wait for stream to complete (close event) |
| "Session not found" | Create new session or check session ID |
| "Port already in use" | Kill existing server: `pkill -f "acli rovodev"` |
| Timeout on simple command | Increase timeout or check network |
| MCP servers not running | Wait 5s after server start |
| Exit code errors handled wrong | Remember: always 0, parse stdout |

## Final Integration Test

Once everything is implemented:

```bash
# 1. Run prerequisites test
./test/test-rovodev-prerequisites.sh

# 2. Start server
acli rovodev serve 8123 --disable-session-token &

# 3. Run automated tests
emacs -batch -L lisp/core -L lisp/interfaces -L test \
  -l ert -l test/test-rovodev-integration.el \
  -f ert-run-tests-batch-and-exit

# 4. Manual testing in Emacs
emacs -nw
```

```elisp
;; Test all three modes
(setq efrit-use-rovodev 'oneshot)
M-x efrit-do RET "Create a test file" RET

(setq efrit-use-rovodev 'server)
M-x efrit-chat RET
;; Send multiple messages

(setq efrit-use-rovodev 'hybrid)
M-x efrit-do RET "List files" RET
M-x efrit-chat RET
;; Both should work

;; Disable and verify backward compatibility
(setq efrit-use-rovodev nil)
M-x efrit-do RET "Test direct API" RET
;; Should use direct Anthropic API
```

If all tests pass, the integration is complete and working correctly!
