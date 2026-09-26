#!/bin/bash
# Drives the real Organise pages window with generated PDFs and writes a snapshot.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p work/build work/swift-module-cache
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -module-cache-path work/swift-module-cache -O -parse-as-library Sources/Shared/*.swift Sources/App/Organiser.swift tests/OrganiserWindowTests.swift -o work/build/organiser-window-tests
xcrun clang -O2 Sources/CLI/exec_group.c -o work/build/rmconvert-exec
export RMCONVERT_EXEC_HELPER="$PWD/work/build/rmconvert-exec"
fixture_dir="$(mktemp -d "${RMCONVERT_TEST_ROOT:-/private/tmp}/rmconvert-organiser.XXXXXX")"
work/build/organiser-window-tests "$fixture_dir" "${1:-$fixture_dir/organiser.png}"
