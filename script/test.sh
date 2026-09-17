#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p work/build work/swift-module-cache
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -module-cache-path work/swift-module-cache -O -parse-as-library Sources/Shared/*.swift tests/CoreTests.swift -o work/build/core-tests
xcrun clang -O2 Sources/CLI/exec_group.c -o work/build/rmconvert-exec
export RMCONVERT_EXEC_HELPER="$PWD/work/build/rmconvert-exec"
fixture_dir="$(mktemp -d "${RMCONVERT_TEST_ROOT:-/private/tmp}/rmconvert-tests.XXXXXX")"
work/build/core-tests "$fixture_dir"
