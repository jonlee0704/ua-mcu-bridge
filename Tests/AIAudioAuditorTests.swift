// ==============================================================================
// Copyright (c) 2026 S&D A11y Studio. All Rights Reserved.
//
// AI Audio Auditor & Rule Engine Diagnostics Unit Tests
// ==============================================================================

import Foundation

public final class AIAudioAuditorTests {
    public static func runAll() {
        print("\n\u{001B}[1;36m================================================================")
        print(" [TEST SUITE 4] AI Studio Co-Producer & Acoustic Rule Engine")
        print("================================================================\u{001B}[0m")

        testTelemetryCaptureAndClipDetection()
        testClippingAndHeadroomRule()
        testMutedChannelWithSignalRule()
        testLowEndRumbleVocalRule()
        testReportGeneration()
    }

    /// Test telemetry peak capture and clipping state
    public static func testTelemetryCaptureAndClipDetection() {
        runTest("Telemetry peak capture and converter clip logging") {
            let uad = UADClient()
            uad.channels = TestAudioFixture.makeChannels(count: 8)
            let auditor = AIAudioAuditor(uadClient: uad)

            auditor.startListening()
            assertEqual(auditor.state, .listening)

            // Feed telemetry
            auditor.recordTelemetry(chId: 0, peakDb: -6.0, isClip: false)
            auditor.recordTelemetry(chId: 1, peakDb: 0.1, isClip: true) // Clipping

            auditor.stopListening()
            assertTrue(auditor.state != .listening)
        }
    }

    /// Test Rule 1: CLIPPING / HOT SIGNAL with 14 dB headroom target
    public static func testClippingAndHeadroomRule() {
        runTest("Rule 1: Clipping / Hot Preamp targets 14 dB converter headroom") {
            let uad = UADClient()
            let chs = TestAudioFixture.makeChannels(count: 4)
            chs[0]?.preamp.hasPreamp = true
            chs[0]?.preamp.gain = 45.0
            uad.channels = chs

            let auditor = AIAudioAuditor(uadClient: uad)
            auditor.startListening()

            // Record clipping telemetry on channel 0
            auditor.recordTelemetry(chId: 0, peakDb: 0.2, isClip: true)

            auditor.stopListening()

            let clipSuggestion = auditor.suggestions.first(where: { $0.channelId == 0 && $0.id.starts(with: "clip_") })
            assertNotNil(clipSuggestion, "Must detect converter clipping on channel 0")
            assertTrue(clipSuggestion?.issueTitle.contains("Clip") ?? false, "Issue title must mention clipping")
        }
    }

    /// Test Rule 2: Muted channel with active audio signal
    public static func testMutedChannelWithSignalRule() {
        runTest("Rule 2: Muted track receiving signal triggers unmute recommendation") {
            let uad = UADClient()
            let chs = TestAudioFixture.makeChannels(count: 4)
            chs[1]?.mute = true // Channel 1 is muted
            uad.channels = chs

            let auditor = AIAudioAuditor(uadClient: uad)
            auditor.startListening()

            // Channel 1 receives audio at -10 dB
            auditor.recordTelemetry(chId: 1, peakDb: -10.0, isClip: false)

            auditor.stopListening()

            let muteSuggestion = auditor.suggestions.first(where: { $0.channelId == 1 && $0.id.starts(with: "muted_signal_") })
            assertNotNil(muteSuggestion, "Must detect signal on muted channel 1")
        }
    }

    /// Test Rule 3: Low-end rumble on vocal track without high-pass filter
    public static func testLowEndRumbleVocalRule() {
        runTest("Rule 3: Vocal track without low-cut filter triggers 75 Hz high-pass recommendation") {
            let uad = UADClient()
            let chs = TestAudioFixture.makeChannels(count: 4)
            chs[0]?.name = "Lead Vox"
            chs[0]?.preamp.hasPreamp = true
            chs[0]?.preamp.lowCut = false // Low-cut is off
            uad.channels = chs

            let auditor = AIAudioAuditor(uadClient: uad)
            auditor.startListening()

            // Vocal receives hot signal
            auditor.recordTelemetry(chId: 0, peakDb: -15.0, isClip: false)

            auditor.stopListening()

            let lowCutSuggestion = auditor.suggestions.first(where: { $0.channelId == 0 && $0.id.starts(with: "lowcut_") })
            assertNotNil(lowCutSuggestion, "Must recommend 75 Hz low-cut filter on vocal track")
        }
    }

    /// Test AI Report saving and listing
    public static func testReportGeneration() {
        runTest("Diagnostic text report generation and listing") {
            let uad = UADClient()
            uad.channels = TestAudioFixture.makeChannels(count: 4)
            let auditor = AIAudioAuditor(uadClient: uad)

            auditor.startListening()
            auditor.recordTelemetry(chId: 0, peakDb: -12.0, isClip: false)
            auditor.stopListening()

            let reports = AIReportManager.shared.listReports()
            assertTrue(!reports.isEmpty, "AIReportManager must have generated at least one diagnostic report")
        }
    }
}
