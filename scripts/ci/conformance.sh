#!/bin/bash

SCRIPT_DIR="$(dirname "$0")"
SERVER_RESULT=0
CLIENT_RESULT=0

echo "========================================"
echo "Server Conformance Tests"
echo "========================================"
if "$SCRIPT_DIR/../conformance/server.sh"; then
    echo "Server conformance tests: PASSED"
else
    SERVER_RESULT=1
    echo "Server conformance tests: FAILED"
fi

echo ""
echo "========================================"
echo "Client Conformance Tests"
echo "========================================"
if "$SCRIPT_DIR/../conformance/client.sh"; then
    echo "Client conformance tests: PASSED"
else
    CLIENT_RESULT=1
    echo "Client conformance tests: FAILED"
fi

echo ""
echo "========================================"
echo "Conformance Summary"
echo "========================================"
echo "  Server: $([ $SERVER_RESULT -eq 0 ] && echo 'PASSED' || echo 'FAILED')"
echo "  Client: $([ $CLIENT_RESULT -eq 0 ] && echo 'PASSED' || echo 'FAILED')"

if [ $SERVER_RESULT -ne 0 ] || [ $CLIENT_RESULT -ne 0 ]; then
    exit 1
fi
