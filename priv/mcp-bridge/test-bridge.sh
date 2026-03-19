#!/usr/bin/env bash
#
# Test script for ClawdEx MCP Bridge
#
# Sends a sequence of MCP JSON-RPC messages to the bridge via stdin
# and prints the responses from stdout.
#
# Usage: bash test-bridge.sh
#

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== ClawdEx MCP Bridge Test ==="
echo ""

# Build the input: multiple JSON-RPC messages, one per line
INPUT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test-client","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"Hello from MCP!"}}}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"add","arguments":{"a":17,"b":25}}}
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"fail","arguments":{}}}
{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"nonexistent","arguments":{}}}
{"jsonrpc":"2.0","id":7,"method":"unknown/method","params":{}}'

# Run bridge with test plugin, capture stdout and stderr separately
STDOUT_FILE=$(mktemp)
STDERR_FILE=$(mktemp)

echo "$INPUT" | node bridge.js --plugin ./test-plugin.js > "$STDOUT_FILE" 2> "$STDERR_FILE"

echo "--- stderr (diagnostics) ---"
cat "$STDERR_FILE"
echo ""

echo "--- stdout (MCP responses) ---"
cat "$STDOUT_FILE"
echo ""

# Validate responses
echo "--- Validation ---"
PASS=0
FAIL=0

check() {
  local desc="$1"
  local pattern="$2"
  if grep -q "$pattern" "$STDOUT_FILE"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (pattern not found: $pattern)"
    FAIL=$((FAIL + 1))
  fi
}

check "initialize response"       'protocolVersion.*2024-11-05'
check "tools/list has echo"       '"name":"echo"'
check "tools/list has add"        '"name":"add"'
check "tools/list has fail"       '"name":"fail"'
check "echo tool result"          'Hello from MCP!'
check "add tool result (42)"      '42'
check "fail tool isError"         '"isError":true'
check "nonexistent tool error"    'Tool not found: nonexistent'
check "unknown method error"      'Method not found: unknown/method'

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"

# Cleanup
rm -f "$STDOUT_FILE" "$STDERR_FILE"

if [ "$FAIL" -gt 0 ]; then
  echo "SOME TESTS FAILED"
  exit 1
fi

echo "All tests passed!"
