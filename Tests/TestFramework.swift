// ==============================================================================
// Copyright (c) 2026 S&D A11y Studio. All Rights Reserved.
//
// Standalone Native Swift Test Framework for UA-MCU Bridge
// Provides deterministic test assertions, suite runners, and ANSI reporting.
// ==============================================================================

import Foundation

public func bridgeLog(_ message: String) {
    if ProcessInfo.processInfo.environment["VERBOSE_TESTS"] == "1" {
        print("    [LOG] \(message)")
    }
}

public final class TestContext {
    public static let shared = TestContext()

    public private(set) var totalTests: Int = 0
    public private(set) var passedTests: Int = 0
    public private(set) var failedTests: Int = 0
    public private(set) var failures: [String] = []

    public func recordPass() {
        totalTests += 1
        passedTests += 1
    }

    public func recordFail(message: String, file: String, line: Int) {
        totalTests += 1
        failedTests += 1
        let filename = (file as NSString).lastPathComponent
        failures.append("[\(filename):\(line)] \(message)")
    }

    public func reset() {
        totalTests = 0
        passedTests = 0
        failedTests = 0
        failures.removeAll()
    }
}

public func assertCondition(_ condition: Bool, _ message: String = "Assertion failed", file: String = #file, line: Int = #line) {
    if condition {
        TestContext.shared.recordPass()
    } else {
        TestContext.shared.recordFail(message: message, file: file, line: line)
        print("  \u{001B}[31mFAILED\u{001B}[0m: \(message) at \((file as NSString).lastPathComponent):\(line)")
    }
}

public func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", file: String = #file, line: Int = #line) {
    if actual == expected {
        TestContext.shared.recordPass()
    } else {
        let msg = message.isEmpty ? "Expected [\(expected)], but got [\(actual)]" : "\(message) (Expected: [\(expected)], got: [\(actual)])"
        TestContext.shared.recordFail(message: msg, file: file, line: line)
        print("  \u{001B}[31mFAILED\u{001B}[0m: \(msg) at \((file as NSString).lastPathComponent):\(line)")
    }
}

public func assertWithinTolerance(_ actual: Double, _ expected: Double, tolerance: Double = 0.05, _ message: String = "", file: String = #file, line: Int = #line) {
    if abs(actual - expected) <= tolerance {
        TestContext.shared.recordPass()
    } else {
        let msg = message.isEmpty ? "Expected [\(expected) \u{00B1} \(tolerance)], but got [\(actual)]" : "\(message) (Expected: [\(expected) \u{00B1} \(tolerance)], got: [\(actual)])"
        TestContext.shared.recordFail(message: msg, file: file, line: line)
        print("  \u{001B}[31mFAILED\u{001B}[0m: \(msg) at \((file as NSString).lastPathComponent):\(line)")
    }
}

public func assertTrue(_ condition: Bool, _ message: String = "Expected true, got false", file: String = #file, line: Int = #line) {
    assertCondition(condition, message, file: file, line: line)
}

public func assertFalse(_ condition: Bool, _ message: String = "Expected false, got true", file: String = #file, line: Int = #line) {
    assertCondition(!condition, message, file: file, line: line)
}

public func assertNotNil<T>(_ value: T?, _ message: String = "Expected non-nil value", file: String = #file, line: Int = #line) {
    assertCondition(value != nil, message, file: file, line: line)
}

public func assertNil<T>(_ value: T?, _ message: String = "Expected nil value", file: String = #file, line: Int = #line) {
    assertCondition(value == nil, message, file: file, line: line)
}

public func runTest(_ name: String, block: () throws -> Void) {
    print("\u{001B}[34m==> Running: \(name)\u{001B}[0m")
    let beforeFails = TestContext.shared.failedTests
    do {
        try block()
        if TestContext.shared.failedTests == beforeFails {
            print("  \u{001B}[32m\u{2713} PASS: \(name)\u{001B}[0m")
        }
    } catch {
        TestContext.shared.recordFail(message: "Unhandled exception: \(error)", file: #file, line: #line)
        print("  \u{001B}[31m\u{2717} CRASHED: \(name) (\(error))\u{001B}[0m")
    }
}
