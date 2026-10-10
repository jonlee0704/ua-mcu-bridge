// ==============================================================================
// Copyright (c) 2026 S&D A11y Studio. All Rights Reserved.
//
// UA-MCU Bridge Master Test Runner (P0 Regression Prevention Suite)
// ==============================================================================

import Foundation

@main
public struct TestRunner {
    public static func main() {
        let startTime = Date()

        print("\u{001B}[1;35m")
        print("================================================================================")
        print("          UA-MCU BRIDGE AUTOMATED REGRESSION & UNIT TEST SUITE (P0)")
        print("================================================================================")
        print("\u{001B}[0m")

        TestContext.shared.reset()

        // Execute all test suites in order
        MCUProtocolTests.runAll()
        UADClientTests.runAll()
        UADCurveTests.runAll()
        AIAudioAuditorTests.runAll()

        let elapsed = Date().timeIntervalSince(startTime)
        let total = TestContext.shared.totalTests
        let passed = TestContext.shared.passedTests
        let failed = TestContext.shared.failedTests

        print("\n\u{001B}[1;35m================================================================================")
        print(" TEST EXECUTION SUMMARY")
        print("================================================================================\u{001B}[0m")
        print(String(format: "  Duration: %.3f seconds", elapsed))
        print("  Total Assertions: \(total)")
        print("  Passed:           \u{001B}[32m\(passed)\u{001B}[0m")
        if failed > 0 {
            print("  Failed:           \u{001B}[31m\(failed)\u{001B}[0m")
            print("\n\u{001B}[1;31mFAILURES:\u{001B}[0m")
            for fail in TestContext.shared.failures {
                print("  \u{001B}[31m\u{2717} \(fail)\u{001B}[0m")
            }
            print("\n\u{001B}[1;31m>>> REGRESSION DETECTED! TEST SUITE FAILED <<<\u{001B}[0m\n")
            exit(1)
        } else {
            print("  Failed:           0")
            print("\n\u{001B}[1;32m>>> ALL P0 REGRESSION TESTS PASSED CLEANLY (ZERO REGRESSIONS) <<<\u{001B}[0m\n")
            exit(0)
        }
    }
}
