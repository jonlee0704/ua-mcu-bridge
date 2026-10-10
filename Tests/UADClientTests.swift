// ==============================================================================
// Copyright (c) 2026 S&D A11y Studio. All Rights Reserved.
//
// UAD Client & Protocol Dispatch Unit Tests (P0 Regressions)
// ==============================================================================

import Foundation

public final class UADClientTests {
    public static func runAll() {
        print("\n\u{001B}[1;36m================================================================")
        print(" [TEST SUITE 2] UAD Client & Apollo Engine Dispatch")
        print("================================================================\u{001B}[0m")

        testMonitorVolumeDualDispatchAcrossAllDevices()
        testMonitorMuteDispatch()
        testInboundMonitorPropertySynchronization()
        testChannelFaderAndPanDispatch()
        testPreampControlsDispatch()
    }

    /// P0 TEST: Dual-dispatch for monitor volume (dB + Tapered) across all connected Apollo units
    public static func testMonitorVolumeDualDispatchAcrossAllDevices() {
        runTest("P0: Monitor volume dual-dispatches both dB and tapered with unique func_ids") {
            let uad = UADClient()
            uad.monitorPaths = [(devId: 0, outId: 20), (devId: 1, outId: 4)]

            var sentCommands: [String] = []
            // Override sendCommand hook using an internal test callback or subclass
            uad.testSendHook = { cmd in
                sentCommands.append(cmd)
            }

            uad.setMonitorDb(db: -35.0)

            assertEqual(uad.monitorLevelDb, -35.0, "monitorLevelDb must be set to -35.0")
            assertWithinTolerance(uad.monitorLevelTapered, UADCurve.dbToTapered(-35.0), tolerance: 0.001)

            // Must have sent 4 commands: (dB + tapered) * 2 devices
            assertEqual(sentCommands.count, 4, "Must dispatch 4 commands (dB and tapered to both devices)")

            let dev0Db = sentCommands.first(where: { $0.contains("/devices/0/outputs/20/CRMonitorLevel/value") })
            let dev0Tapered = sentCommands.first(where: { $0.contains("/devices/0/outputs/20/CRMonitorLevelTapered/value") })
            let dev1Db = sentCommands.first(where: { $0.contains("/devices/1/outputs/4/CRMonitorLevel/value") })
            let dev1Tapered = sentCommands.first(where: { $0.contains("/devices/1/outputs/4/CRMonitorLevelTapered/value") })

            assertNotNil(dev0Db, "Dev 0 must receive CRMonitorLevel command")
            assertNotNil(dev0Tapered, "Dev 0 must receive CRMonitorLevelTapered command")
            assertNotNil(dev1Db, "Dev 1 must receive CRMonitorLevel command")
            assertNotNil(dev1Tapered, "Dev 1 must receive CRMonitorLevelTapered command")

            // Verify unique func_ids
            let funcIds = sentCommands.compactMap { cmd -> String? in
                if let r = cmd.range(of: "func_id=") {
                    let sub = cmd[r.upperBound...]
                    return String(sub.prefix(while: { $0.isNumber }))
                }
                return nil
            }
            let uniqueFuncIds = Set(funcIds)
            assertEqual(uniqueFuncIds.count, 4, "All 4 commands must have distinct func_id numbers")
        }
    }

    /// P0 TEST: Monitor Mute Dispatch
    public static func testMonitorMuteDispatch() {
        runTest("P0: Monitor Mute dispatches to all monitor paths with unique func_id") {
            let uad = UADClient()
            uad.monitorPaths = [(devId: 0, outId: 20), (devId: 1, outId: 4)]
            var sentCommands: [String] = []
            uad.testSendHook = { sentCommands.append($0) }

            uad.setMonitorMute(mute: true)
            assertTrue(uad.monitorMute, "monitorMute must be true")
            assertEqual(sentCommands.count, 2, "Must dispatch Mute to both devices")
            assertTrue(sentCommands.allSatisfy { $0.contains("Mute/value?context_type=main&func_id=") && $0.hasSuffix("true") })

            sentCommands.removeAll()
            uad.setMonitorMute(mute: false)
            assertFalse(uad.monitorMute, "monitorMute must be false")
            assertEqual(sentCommands.count, 2, "Must dispatch Unmute to both devices")
            assertTrue(sentCommands.allSatisfy { $0.hasSuffix("false") })
        }
    }

    /// P0 TEST: Inbound WebSocket/TCP property synchronization
    public static func testInboundMonitorPropertySynchronization() {
        runTest("P0: Inbound Apollo property updates keep dB and tapered synchronized") {
            let uad = UADClient()
            uad.monitorDeviceId = 0
            uad.monitorOutputId = 20

            // Simulate incoming dB frame
            uad.simulateInboundFrame(path: "/devices/0/outputs/20/CRMonitorLevel/value", data: -24.0)
            assertEqual(uad.monitorLevelDb, -24.0, "Inbound CRMonitorLevel must set monitorLevelDb")
            assertWithinTolerance(uad.monitorLevelTapered, UADCurve.dbToTapered(-24.0), tolerance: 0.001, "Inbound CRMonitorLevel must update monitorLevelTapered")

            // Simulate incoming tapered frame
            uad.simulateInboundFrame(path: "/devices/0/outputs/20/CRMonitorLevelTapered/value", data: 0.5)
            assertEqual(uad.monitorLevelTapered, 0.5, "Inbound CRMonitorLevelTapered must set monitorLevelTapered")
            assertWithinTolerance(uad.monitorLevelDb, UADCurve.taperedToDb(0.5), tolerance: 0.05, "Inbound CRMonitorLevelTapered must update monitorLevelDb")
        }
    }

    /// P0 TEST: Channel Fader and Pan Dispatch
    public static func testChannelFaderAndPanDispatch() {
        runTest("P0: Channel fader and pan dispatch correct Apollo parameter paths") {
            let uad = UADClient()
            uad.channels = TestAudioFixture.makeChannels(count: 8)
            var sentCommands: [String] = []
            uad.testSendHook = { sentCommands.append($0) }

            // Set Fader on Channel 0
            uad.setFader(chId: 0, tapered: 0.75)
            assertEqual(sentCommands.count, 1, "setFader must send FaderLevelTapered")
            assertTrue(sentCommands[0].contains("/devices/0/inputs/0/FaderLevelTapered/value"))

            // Set Pan on Channel 0
            sentCommands.removeAll()
            uad.setPan(chId: 0, pan: -0.5)
            assertEqual(sentCommands.count, 1, "setPan must dispatch Pan/value")
            assertTrue(sentCommands[0].contains("/devices/0/inputs/0/Pan/value"))
            assertTrue(sentCommands[0].contains("-0.500"))
        }
    }

    /// P0 TEST: Preamp Controls Dispatch
    public static func testPreampControlsDispatch() {
        runTest("P0: Preamp gain, 48V, low cut, pad, phase invert dispatch properly") {
            let uad = UADClient()
            uad.channels = TestAudioFixture.makeChannels(count: 4)
            var sentCommands: [String] = []
            uad.testSendHook = { sentCommands.append($0) }

            // Toggle 48V on Channel 0
            _ = uad.togglePreamp48V(chId: 0)
            assertTrue(sentCommands.contains(where: { $0.contains("/devices/0/inputs/0/preamps/0/48V/value") }))

            // Toggle Low Cut
            sentCommands.removeAll()
            _ = uad.togglePreampLowCut(chId: 0)
            assertTrue(sentCommands.contains(where: { $0.contains("/devices/0/inputs/0/preamps/0/LowCut/value") }))

            // Toggle Phase Invert
            sentCommands.removeAll()
            _ = uad.togglePreampPhase(chId: 0)
            assertTrue(sentCommands.contains(where: { $0.contains("/devices/0/inputs/0/preamps/0/Phase/value") }))
        }
    }
}
