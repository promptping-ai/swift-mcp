#!/bin/bash
# Verify documentation builds without warnings

set -e
cd "$(dirname "$0")/.."

ALLOW_WARNINGS=false
if [[ "$1" == "--allow-warnings" ]]; then
    ALLOW_WARNINGS=true
fi

echo "Building documentation..."

if [[ "$ALLOW_WARNINGS" == true ]]; then
    # Run and capture output, showing warnings but not failing
    OUTPUT=$(swift package generate-documentation --target MCP 2>&1) || true
    echo "$OUTPUT"

    WARNING_COUNT=$(echo "$OUTPUT" | grep -c "warning:" || true)
    if [[ "$WARNING_COUNT" -gt 0 ]]; then
        echo ""
        echo "Found $WARNING_COUNT warning(s)."
    else
        echo ""
        echo "No warnings found."
    fi
else
    swift package generate-documentation --target MCP --warnings-as-errors
fi

echo "Documentation build complete."
