#!/bin/bash
# run-tests.sh - Run all chez-async test files
#
# Uses the test framework tests (auto-detectable pass/fail).
# Skips: test-framework.ss (library, not executable),
#        test-async-simple.ss / test-promise-resolved.ss (manual output, no framework)

cd "$(dirname "$0")"

PASSED=0
FAILED=0
ERRORS=""
TIMEOUT_DEFAULT=15
TIMEOUT_LONG=30

run_test() {
    local name="$1"
    local file="$2"
    local timeout="${3:-$TIMEOUT_DEFAULT}"

    printf "%-40s " "$name"

    output=$(timeout "$timeout" scheme --libdirs .:.. --program "$file" 2>&1)
    exit_code=$?

    if [ $exit_code -eq 124 ]; then
        printf "TIMEOUT\n"
        FAILED=$((FAILED + 1))
        ERRORS="$ERRORS\n  $name: timed out after ${timeout}s"
        return
    fi

    if [ $exit_code -ne 0 ]; then
        printf "ERROR (exit %d)\n" "$exit_code"
        FAILED=$((FAILED + 1))
        # Show first error line
        err_line=$(echo "$output" | grep -m1 -i "exception\|error\|FAIL" || echo "$output" | tail -1)
        ERRORS="$ERRORS\n  $name: $err_line"
        return
    fi

    # Check for test failure in output
    if echo "$output" | grep -q "Failed: 0\|All tests passed"; then
        printf "PASS\n"
        PASSED=$((PASSED + 1))
    elif echo "$output" | grep -q "Failed:"; then
        fail_count=$(echo "$output" | grep "Failed:" | tail -1 | awk '{print $2}')
        printf "FAIL (%s failed)\n" "$fail_count"
        FAILED=$((FAILED + 1))
        ERRORS="$ERRORS\n  $name: $fail_count test(s) failed"
    else
        # No framework output detected, assume pass if exit 0
        printf "PASS\n"
        PASSED=$((PASSED + 1))
    fi
}

echo "========================================"
echo "  chez-async Test Suite"
echo "========================================"
echo ""

run_test "Timer"               tests/test-timer.ss
run_test "Promise"             tests/test-promise.ss
run_test "Async Work"          tests/test-async.ss
run_test "Coroutine"           tests/test-coroutine.ss
run_test "TCP"                 tests/test-tcp.ss
run_test "UDP"                 tests/test-udp.ss
run_test "Pipe"                tests/test-pipe.ss
run_test "DNS"                 tests/test-dns.ss
run_test "Signal"              tests/test-signal.ss
run_test "Poll"                tests/test-poll.ss
run_test "Process"             tests/test-process.ss
run_test "Loop Hooks"          tests/test-loop-hooks.ss
run_test "FS Watch"            tests/test-fs-watch.ss
run_test "Stream (high-level)" tests/test-stream-high.ss
run_test "TTY"                 tests/test-tty.ss
run_test "File System"         tests/test-fs.ss
run_test "Phase 3 Integration" tests/test-phase3-integration.ss "$TIMEOUT_LONG"

TOTAL=$((PASSED + FAILED))

echo ""
echo "========================================"
echo "  Results: $PASSED/$TOTAL passed"
echo "========================================"

if [ -n "$ERRORS" ]; then
    echo ""
    echo "Failures:"
    printf "$ERRORS\n"
fi

echo ""

if [ $FAILED -eq 0 ]; then
    echo "All tests passed!"
    exit 0
else
    echo "$FAILED test suite(s) failed."
    exit 1
fi
