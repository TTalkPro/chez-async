#!/bin/bash
# run-tests.sh - Run all tests

cd "$(dirname "$0")"

echo "================================"
echo "Running Timer Tests"
echo "================================"
scheme --libdirs .:.. --program tests/test-timer.ss

echo ""
echo "================================"
echo "Running Async Tests"
echo "================================"
scheme --libdirs .:.. --program tests/test-async.ss
