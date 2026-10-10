#!/usr/bin/env bash
# ==============================================================================
# UA-MCU Bridge Automated Regression & Unit Test Suite Runner (P0)
# Zero external test runner dependencies. Compiles natively with swiftc ARM64.
# ==============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

BINARY="./UAMCUBridgeTests"

echo "Building UA-MCU Bridge Unit & Regression Tests (P0)..."

swiftc -O -target arm64-apple-macos12.0 \
  VoiceAnnouncer.swift \
  CoreMIDIAdapter.swift \
  UADModels.swift \
  UADCurve.swift \
  UADClient.swift \
  AIReportManager.swift \
  AIAudioAuditor.swift \
  MCUEngine.swift \
  Tests/TestFramework.swift \
  Tests/TestMocks.swift \
  Tests/MCUProtocolTests.swift \
  Tests/UADClientTests.swift \
  Tests/UADCurveTests.swift \
  Tests/AIAudioAuditorTests.swift \
  Tests/TestRunner.swift \
  -o "$BINARY"

echo "Build complete. Executing test suite..."
"$BINARY"
EXIT_CODE=$?

exit $EXIT_CODE
