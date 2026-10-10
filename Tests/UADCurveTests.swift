// ==============================================================================
// Copyright (c) 2026 S&D A11y Studio. All Rights Reserved.
//
// UAD Audio Curve & Text Formatting Unit Tests
// ==============================================================================

import Foundation

public final class UADCurveTests {
    public static func runAll() {
        print("\n\u{001B}[1;36m================================================================")
        print(" [TEST SUITE 3] UAD Curve, Calibration & String Formatting")
        print("================================================================\u{001B}[0m")

        testMonitorCurveRoundTrip()
        testFaderCalibrationCurve()
        testSendTitle7CharFormatting()
        testChannelName7CharFormatting()
        testDbAndMeterStringFormatting()
        testSpeechLexiconFormatting()
    }

    /// Test monitor taper to dB and vice versa
    public static func testMonitorCurveRoundTrip() {
        runTest("Monitor taper curve monotonic and accurate round-trip") {
            // Edge cases
            assertEqual(UADCurve.dbToTapered(12.0), 1.0, "+12 dB must map to 1.0 tapered")
            assertEqual(UADCurve.dbToTapered(-144.0), 0.0, "-144 dB must map to 0.0 tapered")
            assertWithinTolerance(UADCurve.taperedToDb(1.0), 12.0, tolerance: 0.05)
            assertWithinTolerance(UADCurve.taperedToDb(0.0), -144.0, tolerance: 0.05)

            // Test round-trip across full range
            let testDbs: [Double] = [12.0, 6.0, 0.0, -3.0, -6.0, -12.0, -18.0, -24.0, -36.0, -48.0, -60.0, -86.0]
            for db in testDbs {
                let tap = UADCurve.dbToTapered(db)
                let restoredDb = UADCurve.taperedToDb(tap)
                assertWithinTolerance(restoredDb, db, tolerance: 0.5, "Round-trip dB -> Tapered -> dB for \(db) dB")
            }
        }
    }

    /// Test fader calibration table
    public static func testFaderCalibrationCurve() {
        runTest("Fader 14-bit motor calibration curve correctness") {
            assertWithinTolerance(UADCurve.taperedToDb(1.0), 12.0, tolerance: 0.1, "Top fader position must be +12.0 dB")
            assertWithinTolerance(UADCurve.taperedToDb(0.7818), 0.0, tolerance: 0.1, "Unity gain (~0.782) must be ~0.0 dB")
            assertEqual(UADCurve.taperedToDb(0.0), -144.0, "Bottom fader position must be -oo (-144.0 dB)")
        }
    }

    /// Test 7-character CUE/SEND main title formatting
    public static func testSendTitle7CharFormatting() {
        runTest("CUE/SENDS Row 1 7-character title centering and intelligent abbreviation") {
            // Exactly 7 chars output
            assertEqual(UADCurve.formatSendTitle7Char("AUX 1").count, 7)
            assertEqual(UADCurve.formatSendTitle7Char("HP 1").count, 7)
            assertEqual(UADCurve.formatSendTitle7Char("QSB").count, 7)
            assertEqual(UADCurve.formatSendTitle7Char("Monitor").count, 7)

            // Known abbreviation rules
            assertEqual(UADCurve.formatSendTitle7Char("Positive Grid"), "PosGrid")
            assertEqual(UADCurve.formatSendTitle7Char("Reverb"), "Reverb ")
            assertEqual(UADCurve.formatSendTitle7Char("Monitor"), "Monitor")
        }
    }

    /// Test channel name 7-character formatting
    public static func testChannelName7CharFormatting() {
        runTest("Channel name formatting to 7 characters") {
            // Under 7 characters preserved
            assertEqual(UADCurve.formatChannelName7Char("Kick"), "Kick")
            assertEqual(UADCurve.formatChannelName7Char("Snare"), "Snare")

            // Abbreviated and capped to 7
            assertEqual(UADCurve.formatChannelName7Char("Apollo 1"), "Apo 1")
            assertEqual(UADCurve.formatChannelName7Char("System Out-ST"), "SysteST")
        }
    }

    /// Test dB and meter string formatting for LCD Row 2
    public static func testDbAndMeterStringFormatting() {
        runTest("dB and meter string formatting (7 chars for LCD Row 2)") {
            assertEqual(UADCurve.formatDb7Char(0.0), "  0.0dB")
            assertEqual(UADCurve.formatDb7Char(-6.0), " -6.0dB")
            assertEqual(UADCurve.formatDb7Char(-12.5), "-12.5dB")
            assertEqual(UADCurve.formatDb7Char(-144.0), " -oo dB")

            assertEqual(UADCurve.formatMeterPeak7Char(0.0), " CLIP! ")
            assertEqual(UADCurve.formatMeterPeak7Char(-77.0), " -oo PK")
        }
    }

    /// Test speech lexicon formatters
    public static func testSpeechLexiconFormatting() {
        runTest("Speech lexicon pronunciation formatting") {
            assertEqual(UADCurve.formatDbSpeech(0.0), "zero d B")
            assertEqual(UADCurve.formatDbSpeech(-6.0), "-6.0 d B")
            assertEqual(UADCurve.formatDbSpeech(-144.0), "minus infinity d B")
            assertEqual(UADCurve.formatPanSpeech(0.0), "center")
            assertEqual(UADCurve.formatPanSpeech(-1.0), "left 100 percent")
            assertEqual(UADCurve.formatPanSpeech(1.0), "right 100 percent")
        }
    }
}
