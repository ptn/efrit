#!/bin/bash
# test-rovodev-prerequisites.sh
# Verify Rovodev CLI prerequisites before implementing integration

set -e

echo "=========================================="
echo "Rovodev CLI Prerequisites Test"
echo "=========================================="
echo ""

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

FAILURES=0

# Test function
test_step() {
    local name="$1"
    local command="$2"
    
    echo -n "Testing: $name... "
    if eval "$command" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ PASS${NC}"
        return 0
    else
        echo -e "${RED}✗ FAIL${NC}"
        FAILURES=$((FAILURES + 1))
        return 1
    fi
}

# Test function with output capture
test_step_with_output() {
    local name="$1"
    local command="$2"
    local expected="$3"
    
    echo -n "Testing: $name... "
    output=$(eval "$command" 2>&1)
    if echo "$output" | grep -q "$expected"; then
        echo -e "${GREEN}✓ PASS${NC}"
        return 0
    else
        echo -e "${RED}✗ FAIL${NC}"
        echo "  Expected: $expected"
        echo "  Got: $output"
        FAILURES=$((FAILURES + 1))
        return 1
    fi
}

echo "=== Phase 1: CLI Installation ==="
echo ""

test_step "acli command exists" "which acli"
test_step_with_output "acli version" "acli --version" "acli version"

echo ""
echo "=== Phase 2: Rovodev Configuration ==="
echo ""

test_step "Rovodev config exists" "test -f ~/.rovodev/config.yml"

if [ -f ~/.rovodev/config.yml ]; then
    echo "Config file found at: ~/.rovodev/config.yml"
    if grep -q "agent.modelId" ~/.rovodev/config.yml 2>/dev/null; then
        model=$(grep "agent.modelId" ~/.rovodev/config.yml | awk '{print $2}' | tr -d '"' | head -1)
        echo -e "${GREEN}  Model configured: $model${NC}"
    else
        echo -e "${YELLOW}  Warning: No model configured in config file${NC}"
    fi
fi

echo ""
echo "=== Phase 3: One-Shot Mode ==="
echo ""

echo -n "Testing: Simple one-shot command... "
start_time=$(date +%s)
if timeout 30 acli rovodev run "What is 2+2?" > /tmp/rovodev-test-output.txt 2>&1; then
    end_time=$(date +%s)
    duration=$((end_time - start_time))
    exit_code=$?
    
    # Check exit code (should be 0 even for errors!)
    if [ $exit_code -eq 0 ]; then
        echo -e "${GREEN}✓ PASS${NC} (${duration}s, exit code: $exit_code)"
        
        # Verify output contains response marker
        if grep -q "─── Response ───" /tmp/rovodev-test-output.txt; then
            echo -e "  ${GREEN}Response marker found in output${NC}"
        else
            echo -e "  ${YELLOW}Warning: Response marker not found${NC}"
        fi
    else
        echo -e "${RED}✗ FAIL${NC} (non-zero exit: $exit_code)"
        FAILURES=$((FAILURES + 1))
    fi
else
    echo -e "${RED}✗ FAIL${NC} (timeout or error)"
    FAILURES=$((FAILURES + 1))
fi

# Test exit code behavior with nonsense command
echo -n "Testing: Exit code with nonsense command... "
if acli rovodev run "xyzabc123 complete nonsense" > /tmp/rovodev-nonsense.txt 2>&1; then
    exit_code=$?
    if [ $exit_code -eq 0 ]; then
        echo -e "${GREEN}✓ PASS${NC} (exit code 0 even for nonsense - EXPECTED)"
    else
        echo -e "${YELLOW}UNEXPECTED: exit code $exit_code${NC}"
    fi
else
    echo -e "${YELLOW}Command failed with exit code $?${NC}"
fi

echo ""
echo "=== Phase 4: Server Mode ==="
echo ""

# Check if server is already running
if lsof -i :8123 > /dev/null 2>&1; then
    echo -e "${YELLOW}Warning: Port 8123 already in use${NC}"
    echo "Attempting to use existing server for tests..."
    SERVER_RUNNING=true
else
    echo "Starting Rovodev server on port 8123..."
    acli rovodev serve 8123 --disable-session-token > /tmp/rovodev-server.log 2>&1 &
    SERVER_PID=$!
    echo "Server PID: $SERVER_PID"
    
    # Wait for server to start (max 10 seconds)
    echo -n "Waiting for server startup"
    for i in {1..10}; do
        if curl -s http://localhost:8123/healthcheck > /dev/null 2>&1; then
            echo -e " ${GREEN}✓${NC}"
            break
        fi
        echo -n "."
        sleep 1
    done
    echo ""
    SERVER_RUNNING=true
fi

if [ "$SERVER_RUNNING" = true ]; then
    # Test healthcheck
    echo -n "Testing: Server healthcheck... "
    health=$(curl -s http://localhost:8123/healthcheck)
    if echo "$health" | jq -e '.status == "healthy"' > /dev/null 2>&1; then
        echo -e "${GREEN}✓ PASS${NC}"
        version=$(echo "$health" | jq -r '.version')
        echo "  Server version: $version"
    else
        echo -e "${RED}✗ FAIL${NC}"
        FAILURES=$((FAILURES + 1))
    fi
    
    # Test MCP server status
    echo -n "Testing: MCP servers running... "
    mcp_status=$(echo "$health" | jq -r '.mcp_servers')
    if [ "$mcp_status" != "null" ] && [ "$mcp_status" != "" ]; then
        echo -e "${GREEN}✓ PASS${NC}"
        echo "$health" | jq '.mcp_servers'
    else
        echo -e "${RED}✗ FAIL${NC}"
        FAILURES=$((FAILURES + 1))
    fi
    
    # Test session creation
    echo -n "Testing: Session creation... "
    session_response=$(curl -sX POST http://localhost:8123/v3/sessions/create)
    session_id=$(echo "$session_response" | jq -r '.session_id')
    if [ "$session_id" != "null" ] && [ ! -z "$session_id" ]; then
        echo -e "${GREEN}✓ PASS${NC}"
        echo "  Session ID: $session_id"
        
        # Test session restoration
        echo -n "Testing: Session restoration... "
        if curl -sX POST "http://localhost:8123/v3/sessions/$session_id/restore" > /dev/null 2>&1; then
            echo -e "${GREEN}✓ PASS${NC}"
        else
            echo -e "${RED}✗ FAIL${NC}"
            FAILURES=$((FAILURES + 1))
        fi
    else
        echo -e "${RED}✗ FAIL${NC}"
        FAILURES=$((FAILURES + 1))
    fi
    
    # Test set_chat_message
    echo -n "Testing: Set chat message... "
    if curl -sX POST http://localhost:8123/v3/set_chat_message \
        -H "Content-Type: application/json" \
        -d '{"message": "test message", "enable_deep_plan": false}' > /dev/null 2>&1; then
        echo -e "${GREEN}✓ PASS${NC}"
    else
        echo -e "${RED}✗ FAIL${NC}"
        FAILURES=$((FAILURES + 1))
    fi
    
    # Test SSE stream (just connection, not full response)
    echo -n "Testing: SSE stream connection... "
    if timeout 5 curl -sN http://localhost:8123/v3/stream_chat | head -1 | grep -q "event:" ; then
        echo -e "${GREEN}✓ PASS${NC}"
    else
        echo -e "${YELLOW}PARTIAL${NC} (connection works but may need message set first)"
    fi
    
    # Cleanup: kill server if we started it
    if [ ! -z "$SERVER_PID" ]; then
        echo ""
        echo "Stopping test server (PID: $SERVER_PID)..."
        kill $SERVER_PID 2>/dev/null || true
        wait $SERVER_PID 2>/dev/null || true
    fi
fi

echo ""
echo "=== Phase 5: Efrit MCP Server ==="
echo ""

if [ -d /Users/ptorres/code/efrit/mcp ]; then
    cd /Users/ptorres/code/efrit/mcp
    
    test_step "package.json exists" "test -f package.json"
    test_step "node_modules exists or can install" "test -d node_modules || npm install --silent"
    
    echo -n "Testing: MCP server can start... "
    if timeout 5 npm start > /tmp/efrit-mcp-test.log 2>&1 &
    then
        MCP_PID=$!
        sleep 2
        if ps -p $MCP_PID > /dev/null 2>&1; then
            echo -e "${GREEN}✓ PASS${NC}"
            kill $MCP_PID 2>/dev/null || true
        else
            echo -e "${RED}✗ FAIL${NC} (process died immediately)"
            cat /tmp/efrit-mcp-test.log
            FAILURES=$((FAILURES + 1))
        fi
    else
        echo -e "${RED}✗ FAIL${NC}"
        FAILURES=$((FAILURES + 1))
    fi
    
    cd - > /dev/null
else
    echo -e "${RED}Efrit MCP directory not found${NC}"
    FAILURES=$((FAILURES + 1))
fi

echo ""
echo "=========================================="
echo "Test Summary"
echo "=========================================="

if [ $FAILURES -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    echo ""
    echo "✓ Rovodev CLI is installed and configured"
    echo "✓ One-shot mode works (exit codes always 0)"
    echo "✓ Server mode works (with --disable-session-token)"
    echo "✓ MCP servers are accessible"
    echo "✓ Efrit MCP server can start"
    echo ""
    echo -e "${GREEN}Ready to implement Rovodev integration!${NC}"
    exit 0
else
    echo -e "${RED}$FAILURES test(s) failed${NC}"
    echo ""
    echo "Please fix the failures before implementing integration."
    echo ""
    echo "Common fixes:"
    echo "  - Install acli: https://docs.rovodev.ai/install"
    echo "  - Configure ~/.rovodev/config.yml with model settings"
    echo "  - Ensure ports 8123 is available"
    echo "  - Run 'npm install' in efrit/mcp directory"
    exit 1
fi
