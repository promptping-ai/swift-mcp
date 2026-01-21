#!/bin/bash

# Run CI checks locally
# Linux builds require SwiftCompilerPlugin which isn't available in Docker images,
# so Linux testing is done via GitHub CI only.

cd "$(dirname "$0")/.."

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Track results
declare -a CHECK_NAMES
declare -a CHECK_RESULTS

show_help() {
    echo "Usage: $(basename "$0") [OPTIONS]"
    echo ""
    echo "Run CI checks locally (macOS only)."
    echo ""
    echo "Options:"
    echo "  --help              Show this help message"
    echo "  --skip-conformance  Skip conformance tests"
    echo "  --skip-docs         Skip documentation verification"
    echo "  --skip-lint         Skip pre-commit/linting checks"
    echo ""
    echo "Note: Linux testing requires GitHub CI due to SwiftCompilerPlugin limitations."
}

run_check() {
    local name="$1"
    shift
    local command="$@"

    echo ""
    echo -e "${BOLD}========================================${NC}"
    echo -e "${BOLD}$name${NC}"
    echo -e "${BOLD}========================================${NC}"

    CHECK_NAMES+=("$name")

    if eval "$command"; then
        CHECK_RESULTS+=("pass")
        return 0
    else
        CHECK_RESULTS+=("fail")
        echo ""
        echo -e "${RED}✗ $name failed${NC}"
        return 1
    fi
}

print_summary() {
    local has_failures=false

    echo ""
    echo -e "${BOLD}========================================${NC}"
    echo -e "${BOLD}Summary${NC}"
    echo -e "${BOLD}========================================${NC}"

    for i in "${!CHECK_NAMES[@]}"; do
        local name="${CHECK_NAMES[$i]}"
        local result="${CHECK_RESULTS[$i]}"

        if [[ "$result" == "pass" ]]; then
            echo -e "  ${GREEN}✓${NC} $name"
        else
            echo -e "  ${RED}✗${NC} $name"
            has_failures=true
        fi
    done

    echo ""

    if [[ "$has_failures" == true ]]; then
        echo -e "${RED}${BOLD}Some checks failed.${NC} Fix the issues above before pushing."
        return 1
    else
        echo -e "${GREEN}${BOLD}All checks passed.${NC}"
        return 0
    fi
}

# Parse arguments
SKIP_CONFORMANCE=false
SKIP_DOCS=false
SKIP_LINT=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --help) show_help; exit 0 ;;
        --skip-conformance) SKIP_CONFORMANCE=true; shift ;;
        --skip-docs) SKIP_DOCS=true; shift ;;
        --skip-lint) SKIP_LINT=true; shift ;;
        *) echo "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# Run checks (continue even if some fail)
HAS_FAILURES=false

# Pre-commit / Linting
if [[ "$SKIP_LINT" == false ]]; then
    if command -v pre-commit &> /dev/null; then
        run_check "Lint (pre-commit)" "pre-commit run --all-files" || HAS_FAILURES=true
    else
        echo ""
        echo -e "${YELLOW}Warning: pre-commit not installed, skipping lint checks${NC}"
        echo "Install with: brew install pre-commit"
    fi
fi

# Build
run_check "Build" "swift build" || HAS_FAILURES=true

# Tests
run_check "Tests" "swift test" || HAS_FAILURES=true

# Documentation
if [[ "$SKIP_DOCS" == false ]]; then
    run_check "Documentation" "scripts/verify-docs.sh" || HAS_FAILURES=true
fi

# Conformance tests
if [[ "$SKIP_CONFORMANCE" == false ]]; then
    run_check "Conformance Tests" "scripts/ci/conformance.sh" || HAS_FAILURES=true
fi

# Print summary and exit with appropriate code
print_summary
exit $?
