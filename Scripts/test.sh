#!/bin/bash
# Builds and runs the Mikey test suite.
#
# This machine has Command Line Tools only (no Xcode), so `swift test` is a
# dead end: SwiftPM builds an `.xctest` bundle but there is no XCTest host to
# execute it — the command prints "Build complete!" having run zero tests.
# Instead the suite lives in the `MikeyTests` executable target (see
# Package.swift / Tests/MikeyTests/Runner.swift), and this script is the one
# command to run it. Exits nonzero if any test fails.
#
# Extra args pass straight through to the Swift Testing runner, e.g.:
#   Scripts/test.sh --filter M4AWriterTests
#   Scripts/test.sh --list-tests
set -euo pipefail
cd "$(dirname "$0")/.."

bin="$(swift build --show-bin-path)"
swift build --product MikeyTests
"$bin/MikeyTests" "$@"
