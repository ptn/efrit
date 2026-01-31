# Rovodev Integration Tests

This directory contains tests for the Rovodev CLI integration with Efrit.

## Quick Start

### 1. Prerequisites Test (Run First!)

Before implementing anything, verify Rovodev is set up correctly:

```bash
cd /Users/ptorres/code/efrit
./test/test-rovodev-prerequisites.sh
```

**What it tests:**
- ✓ Rovodev CLI installed
- ✓ Configuration file exists
- ✓ One-shot mode works (20-45 second timing)
- ✓ Exit codes are always 0 (expected behavior)
- ✓ Server mode works with --disable-session-token
- ✓ MCP servers status available
- ✓ Efrit's MCP server can start

**Expected result:** All green checkmarks

**If it fails:** Follow the error messages to fix prerequisites

### 2. Integration Tests (After Implementation)

Once you've implemented the Rovodev integration modules:

```bash
cd /Users/ptorres/code/efrit

# Run all tests
emacs -batch -L lisp/core -L lisp/interfaces -L test \
  -l ert -l test/test-rovodev-integration.el \
  -f ert-run-tests-batch-and-exit
```

**What it tests:**
- Configuration options
- Exit code handling (parse stdout, ignore exit codes)
- SSE event parsing (all 7 types)
- Stream consumption blocking
- Error response parsing (HTTP 404, 422, 401)
- Session management
- One-shot execution
- Server mode communication

## Files

### Test Scripts

| File | Purpose | When to Run |
|------|---------|-------------|
| `test-rovodev-prerequisites.sh` | Verify Rovodev CLI setup | **BEFORE** implementation |
| `test-rovodev-integration.el` | Test Efrit integration code | **AFTER** implementation |
| `ROVODEV_TESTING_GUIDE.md` | Comprehensive testing guide | Reference during development |

### Reference Documents

| File | Purpose |
|------|---------|
| `../ROVODEV_CLI_TEST_RESULTS.md` | Raw test output from Rovodev 0.13.40 |
| `../.cursor/plans/cli_adapter_implementation_39590bdb.plan.md` | Implementation plan with test findings |

## Test Categories

### Unit Tests (Fast)
Test individual functions without external dependencies:
- Configuration parsing
- Exit code detection
- SSE event parsing
- Stream blocking logic
- Error response parsing

### Integration Tests (Slow, requires Rovodev)
Test actual integration with running Rovodev:
- One-shot command execution
- Server healthcheck
- Session creation/restoration
- Message streaming
- Multi-turn conversations

## Running Specific Tests

### Only prerequisites:
```bash
./test/test-rovodev-prerequisites.sh
```

### Only unit tests (no server required):
```bash
emacs -batch -L lisp/core -L lisp/interfaces -L test \
  -l ert -l test/test-rovodev-integration.el \
  --eval '(ert-run-tests-batch-and-exit (ert-select-tests (quote (not (tag :integration)))))'
```

### Only integration tests (requires server):
```bash
# Start server first
acli rovodev serve 8123 --disable-session-token &

# Run tests
emacs -batch -L lisp/core -L lisp/interfaces -L test \
  -l ert -l test/test-rovodev-integration.el \
  --eval '(ert-run-tests-batch-and-exit (ert-select-tests (quote (tag :integration))))'
```

### Interactive testing:
```elisp
;; In Emacs:
(load-file "test/test-rovodev-integration.el")

;; Test one-shot manually
M-x test-rovodev-manual-oneshot

;; Test server manually
M-x test-rovodev-manual-server
```

## Success Criteria

All tests should pass when:

1. **Prerequisites pass** → Rovodev is set up correctly
2. **Unit tests pass** → Code implementation is correct
3. **Integration tests pass** → End-to-end flow works
4. **Manual tests work** → Real-world usage scenarios work

## Common Issues

| Issue | Solution |
|-------|----------|
| Prerequisites fail | Install/configure Rovodev CLI |
| Unit tests fail | Fix implementation bugs |
| Integration tests timeout | Check Rovodev server is running |
| "Chat in progress" error | Stream consumption blocking not working |
| Exit code errors | Remember: always 0, parse stdout |

## Development Workflow

1. Run prerequisites test
2. Implement a module (e.g., `efrit-rovodev-oneshot.el`)
3. Run `make compile`
4. Run unit tests for that module
5. Run integration test for that module
6. Fix any failures
7. Commit and push
8. Move to next module

## Performance Benchmarks

Track these during testing:

- Simple oneshot: ~20s (threshold: <30s)
- Complex oneshot: ~45s (threshold: <90s)
- Server startup: 3-5s (threshold: <10s)
- Session creation: <500ms (threshold: <1s)
- First message: 5-10s (threshold: <15s)

See `ROVODEV_TESTING_GUIDE.md` for detailed performance expectations.

## Questions?

See the comprehensive guide: `ROVODEV_TESTING_GUIDE.md`
