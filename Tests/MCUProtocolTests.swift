// ==============================================================================
// Copyright (c) 2026 S&D A11y Studio. All Rights Reserved.
//
// MCU Protocol & Surface Control Unit Tests (P0 Regressions)
// ==============================================================================

import Foundation

public final class MCUProtocolTests {
    public static func runAll() {
        print("\n\u{001B}[1;36m================================================================")
        print(" [TEST SUITE 1] MCU Protocol & Surface Control (P0 Regressions)")
        print("================================================================\u{001B}[0m")

        testPageNavigationAcrossChannels()
        testWheelControlsOnlyMonitorVolume()
        testWheelStrobeNote83Absorbed()
        testStreamingMidiParserMultiMessagePacket()
        testBankOneTrackNavigation()
        testFineButtonAiCycle()
        testFlipButtonReturnAndHome()
        testFaderTouchSensorsAbsorbed()
        testCueSendsModeLevelMeters()
    }

    /// P0 TEST: Hardware PAGE Buttons (< PAGE = Note 48, PAGE > = Note 49)
    /// Must bank channels by 8 tracks across all 32 channels without modifying monitor volume.
    public static func testPageNavigationAcrossChannels() {
        runTest("P0: PAGE buttons (Notes 48/49) bank by 8 tracks across all 32 channels") {
            let (mcu, uad, _) = TestAudioFixture.makeMCUEngine(channelCount: 32)

            let initialMonitorDb = uad.monitorLevelDb
            assertEqual(mcu.bankOffset, 0, "Initial bankOffset must be 0 (Channels 1–8)")

            // 1. Press PAGE > (Note 49 down) -> should bank to Channels 9–16
            mcu.handleMidiBytes([0x90, 49, 0x7F])
            mcu.handleMidiBytes([0x90, 49, 0x00])
            assertEqual(mcu.bankOffset, 8, "PAGE > (1st press) must advance bankOffset to 8 (Channels 9–16)")
            assertEqual(uad.monitorLevelDb, initialMonitorDb, "PAGE > must NEVER change monitor volume")

            // 2. Press PAGE > (Note 49 down) -> should bank to Channels 17–24
            mcu.handleMidiBytes([0x90, 49, 0x7F])
            mcu.handleMidiBytes([0x90, 49, 0x00])
            assertEqual(mcu.bankOffset, 16, "PAGE > (2nd press) must advance bankOffset to 16 (Channels 17–24)")

            // 3. Press PAGE > (Note 49 down) -> should bank to Channels 25–32
            mcu.handleMidiBytes([0x90, 49, 0x7F])
            mcu.handleMidiBytes([0x90, 49, 0x00])
            assertEqual(mcu.bankOffset, 24, "PAGE > (3rd press) must advance bankOffset to 24 (Channels 25–32)")

            // 4. Boundary check: Pressing PAGE > past channel 32 remains clamped
            mcu.handleMidiBytes([0x90, 49, 0x7F])
            mcu.handleMidiBytes([0x90, 49, 0x00])
            assertEqual(mcu.bankOffset, 24, "PAGE > past end must remain clamped at max bank (24)")

            // 5. Press < PAGE (Note 48 down) -> should bank backward: 24 -> 16 -> 8 -> 0
            mcu.handleMidiBytes([0x90, 48, 0x7F])
            mcu.handleMidiBytes([0x90, 48, 0x00])
            assertEqual(mcu.bankOffset, 16, "< PAGE (1st press) must decrement bankOffset to 16")

            mcu.handleMidiBytes([0x90, 48, 0x7F])
            mcu.handleMidiBytes([0x90, 48, 0x00])
            assertEqual(mcu.bankOffset, 8, "< PAGE (2nd press) must decrement bankOffset to 8")

            mcu.handleMidiBytes([0x90, 48, 0x7F])
            mcu.handleMidiBytes([0x90, 48, 0x00])
            assertEqual(mcu.bankOffset, 0, "< PAGE (3rd press) must return bankOffset to 0 (Channels 1–8)")

            // 6. Boundary check: Pressing < PAGE at 0 remains clamped at 0
            mcu.handleMidiBytes([0x90, 48, 0x7F])
            mcu.handleMidiBytes([0x90, 48, 0x00])
            assertEqual(mcu.bankOffset, 0, "< PAGE at channel 1 must remain clamped at 0")
            assertEqual(uad.monitorLevelDb, initialMonitorDb, "Monitor volume must remain unaffected after full round-trip paging")
        }
    }

    /// P0 TEST: Rotary Wheel Controls ONLY Apollo Monitor Volume
    /// Notes 46/47 and CC 60 adjust master monitor volume and NEVER move channel faders or banks.
    public static func testWheelControlsOnlyMonitorVolume() {
        runTest("P0: Rotary Wheel (Notes 46/47 & CC 60) controls exclusively monitor volume") {
            let (mcu, uad, mockMidi) = TestAudioFixture.makeMCUEngine(channelCount: 32)
            uad.monitorLevelDb = -40.0

            let initialBank = mcu.bankOffset
            mockMidi.clear()

            // 1. Turn Wheel Right (Note 47) -> Monitor volume +1.0 dB (-40 -> -39 dB)
            mcu.handleMidiBytes([0x90, 47, 0x7F])
            mcu.handleMidiBytes([0x90, 47, 0x00])
            assertWithinTolerance(uad.monitorLevelDb, -39.0, tolerance: 0.05, "Note 47 must increase monitor volume by 1.0 dB")
            assertEqual(mcu.bankOffset, initialBank, "Note 47 must NEVER move channel bank")

            // 2. Turn Wheel Left (Note 46) -> Monitor volume -1.0 dB (-39 -> -40 dB)
            mcu.handleMidiBytes([0x90, 46, 0x7F])
            mcu.handleMidiBytes([0x90, 46, 0x00])
            assertWithinTolerance(uad.monitorLevelDb, -40.0, tolerance: 0.05, "Note 46 must decrease monitor volume by 1.0 dB")
            assertEqual(mcu.bankOffset, initialBank, "Note 46 must NEVER move channel bank")

            // 3. Jog Wheel (CC 60): Relative two's complement
            // Value 1 = +1 tick (+1.0 dB -> -39.0 dB)
            mcu.handleMidiBytes([0xB0, 60, 0x01])
            assertWithinTolerance(uad.monitorLevelDb, -39.0, tolerance: 0.05, "CC 60 (val=1) must increase monitor volume by 1.0 dB")

            // Value 0x42 = -2 ticks (-2.0 dB -> -41.0 dB)
            mcu.handleMidiBytes([0xB0, 60, 0x42])
            assertWithinTolerance(uad.monitorLevelDb, -41.0, tolerance: 0.05, "CC 60 (val=0x42) must decrease monitor volume by 2.0 dB")
            assertEqual(mcu.bankOffset, initialBank, "CC 60 must NEVER move channel bank")

            // 4. Click Rotary Wheel (Note 100 / Note 84) -> Toggle Monitor Mute
            assertFalse(uad.monitorMute, "Initial monitor mute must be false")
            mcu.handleMidiBytes([0x90, 100, 0x7F])
            mcu.handleMidiBytes([0x90, 100, 0x00])
            assertTrue(uad.monitorMute, "Note 100 click must mute monitor")

            mcu.handleMidiBytes([0x90, 84, 0x7F])
            mcu.handleMidiBytes([0x90, 84, 0x00])
            assertFalse(uad.monitorMute, "Note 84 click must unmute monitor")
        }
    }

    /// P0 TEST: SSL UF8 Wheel Strobe (Note 83) Absorbed
    /// Turning the rotary encoder on SSL UF8 pulses Note 83. It must NEVER trigger AI mode or bank shifts.
    public static func testWheelStrobeNote83Absorbed() {
        runTest("P0: Note 83 (UF8 wheel active strobe) is absorbed and never launches AI mode") {
            let (mcu, uad, _) = TestAudioFixture.makeMCUEngine(channelCount: 32)

            assertEqual(mcu.auditor.state, .idle, "Initial AI Auditor state must be idle")
            let initialDb = uad.monitorLevelDb
            let initialBank = mcu.bankOffset

            // Simulate repeated Note 83 pulses emitted by UF8 rotary wheel
            for _ in 1...10 {
                mcu.handleMidiBytes([0x90, 83, 0x7F])
                mcu.handleMidiBytes([0x90, 83, 0x00])
            }

            assertEqual(mcu.auditor.state, .idle, "Note 83 must NEVER trigger AI Auditor listening")
            assertFalse(mcu.auditor.isActive, "AI Auditor must remain inactive")
            assertEqual(mcu.bankOffset, initialBank, "Note 83 must NEVER move track banks")
            assertEqual(uad.monitorLevelDb, initialDb, "Note 83 must NEVER modify monitor volume")
        }
    }

    /// P0 TEST: Streaming Multi-Message MIDI Packet Parser
    /// CoreMIDI batches multiple events into a single packet; all events must be decoded in order without drops.
    public static func testStreamingMidiParserMultiMessagePacket() {
        runTest("P0: Streaming MIDI parser decodes batched packets without dropping events") {
            let (mcu, uad, _) = TestAudioFixture.makeMCUEngine(channelCount: 32)
            uad.monitorLevelDb = -45.0

            // Construct packet containing:
            // 1. Note 83 down (Wheel strobe)
            // 2. Note 47 down (Rotate CW)
            // 3. Note 47 up
            // 4. Note 83 up (Wheel strobe release)
            let batchedBytes: [UInt8] = [
                0x90, 83, 0x7F,
                0x90, 47, 0x7F,
                0x90, 47, 0x00,
                0x90, 83, 0x00
            ]

            mcu.handleMidiBytes(batchedBytes)

            // Both Note 83 must be absorbed AND Note 47 must have incremented monitor volume
            assertEqual(mcu.auditor.state, .idle, "Note 83 in batched packet must be absorbed")
            assertWithinTolerance(uad.monitorLevelDb, -44.0, tolerance: 0.05, "Note 47 inside batched packet must be executed (+1.0 dB)")
        }
    }

    /// P0 TEST: Bank 1-Track Navigation (Notes 98/99)
    public static func testBankOneTrackNavigation() {
        runTest("P0: Hardware BANK buttons (Notes 98/99) nudge by 1 track") {
            let (mcu, _, _) = TestAudioFixture.makeMCUEngine(channelCount: 32)

            assertEqual(mcu.bankOffset, 0, "Initial bankOffset must be 0")

            // Note 99 (Bank Right / Track Right)
            mcu.handleMidiBytes([0x90, 99, 0x7F])
            mcu.handleMidiBytes([0x90, 99, 0x00])
            assertEqual(mcu.bankOffset, 1, "Note 99 must nudge bankOffset to 1")

            mcu.handleMidiBytes([0x90, 99, 0x7F])
            mcu.handleMidiBytes([0x90, 99, 0x00])
            assertEqual(mcu.bankOffset, 2, "Note 99 must nudge bankOffset to 2")

            // Note 98 (Bank Left / Track Left)
            mcu.handleMidiBytes([0x90, 98, 0x7F])
            mcu.handleMidiBytes([0x90, 98, 0x00])
            assertEqual(mcu.bankOffset, 1, "Note 98 must nudge bankOffset to 1")

            mcu.handleMidiBytes([0x90, 98, 0x7F])
            mcu.handleMidiBytes([0x90, 98, 0x00])
            assertEqual(mcu.bankOffset, 0, "Note 98 must return bankOffset to 0")
        }
    }

    /// P0 TEST: Dedicated FINE Button (Note 70) 3-Step AI Cycle
    public static func testFineButtonAiCycle() {
        runTest("P0: Dedicated FINE key (Note 70) operates 3-step AI cycle with tally LED") {
            let (mcu, uad, mockMidi) = TestAudioFixture.makeMCUEngine(channelCount: 32)

            assertEqual(mcu.auditor.state, .idle)
            mockMidi.clear()

            // Step 1: 1st Press of Note 70 -> Starts AI listening
            mcu.handleMidiBytes([0x90, 70, 0x7F])
            mcu.handleMidiBytes([0x90, 70, 0x00])
            assertEqual(mcu.auditor.state, .listening, "1st press of Note 70 must start AI listening")
            assertTrue(mcu.auditor.isActive, "AI Auditor must be active")
            assertEqual(mockMidi.noteTallyState(note: 70), true, "FINE key LED tally (Note 70) must turn ON")

            // Hearing Safety check: Note 100 still cuts monitor volume during AI session
            assertFalse(uad.monitorMute)
            mcu.handleMidiBytes([0x90, 100, 0x7F])
            mcu.handleMidiBytes([0x90, 100, 0x00])
            assertTrue(uad.monitorMute, "Monitor Mute must remain active for hearing safety during AI listening")

            // Step 2: 2nd Press of Note 70 -> Stops listening and analyzes
            mcu.handleMidiBytes([0x90, 70, 0x7F])
            mcu.handleMidiBytes([0x90, 70, 0x00])
            assertTrue(mcu.auditor.state != .listening, "2nd press of Note 70 must stop listening")

            // Step 3: 3rd Press of Note 70 -> Exits session cleanly
            mcu.handleMidiBytes([0x90, 70, 0x7F])
            mcu.handleMidiBytes([0x90, 70, 0x00])
            assertEqual(mcu.auditor.state, .idle, "3rd press of Note 70 must return AI Auditor to idle")
            assertFalse(mcu.auditor.isActive, "AI Auditor must be deactivated")
            assertEqual(mockMidi.noteTallyState(note: 70), false, "FINE key LED tally (Note 70) must turn OFF")
        }
    }

    /// P0 TEST: FLIP Button (Note 50) Sub-Mode Return and Double-Press Home
    public static func testFlipButtonReturnAndHome() {
        runTest("P0: FLIP button (Note 50) single-press returns to Main Mix, double-press snaps to Ch 1–8") {
            let (mcu, _, _) = TestAudioFixture.makeMCUEngine(channelCount: 32)

            // Advance bank to channels 17–24
            mcu.handleMidiBytes([0x90, 49, 0x7F]) // offset 8
            mcu.handleMidiBytes([0x90, 49, 0x7F]) // offset 16
            assertEqual(mcu.bankOffset, 16)

            // Enter SENDS mode (Note 41)
            mcu.handleMidiBytes([0x90, 41, 0x7F])
            assertTrue(mcu.sendsFocusMode, "Note 41 must activate SENDS mode")

            // Single press FLIP (Note 50) -> exits SENDS mode, preserves bankOffset 16
            mcu.handleMidiBytes([0x90, 50, 0x7F])
            mcu.handleMidiBytes([0x90, 50, 0x00])
            assertFalse(mcu.sendsFocusMode, "Single press FLIP must exit SENDS mode")
            assertEqual(mcu.bankOffset, 16, "Single press FLIP must keep active bank at offset 16")

            // Double press FLIP within 400ms -> snaps bank to 0 (Home: Channels 1–8)
            mcu.handleMidiBytes([0x90, 50, 0x7F])
            mcu.handleMidiBytes([0x90, 50, 0x00])
            mcu.handleMidiBytes([0x90, 50, 0x7F])
            mcu.handleMidiBytes([0x90, 50, 0x00])
            assertEqual(mcu.bankOffset, 0, "Double press FLIP must snap bankOffset straight to 0 (Home Ch 1–8)")
        }
    }

    /// P0 TEST: Capacitive Fader Touch Sensors (Notes 104..111)
    public static func testFaderTouchSensorsAbsorbed() {
        runTest("P0: Capacitive fader touch sensors (Notes 104..111) are absorbed without side effects") {
            let (mcu, uad, _) = TestAudioFixture.makeMCUEngine(channelCount: 32)

            let initialBank = mcu.bankOffset
            let initialMonitorDb = uad.monitorLevelDb

            // Touch faders 0..7 down and up
            for note in 104...111 {
                mcu.handleMidiBytes([0x90, UInt8(note), 0x7F])
                assertTrue(mcu.faderTouched[note - 104], "Fader touch \(note - 104) must register as touched")
                mcu.handleMidiBytes([0x90, UInt8(note), 0x00])
                assertFalse(mcu.faderTouched[note - 104], "Fader touch \(note - 104) must register as released")
            }

            assertEqual(mcu.bankOffset, initialBank, "Fader touch sensors must NEVER alter bankOffset")
            assertEqual(uad.monitorLevelDb, initialMonitorDb, "Fader touch sensors must NEVER alter monitor volume")
        }
    }

    /// P0 TEST: CUE/SENDS Mode Level Meters Across All Slots 0..7
    public static func testCueSendsModeLevelMeters() {
        runTest("P0: CUE/SENDS mode level meters drive slots 0..5 (Sends), slot 6 (Output), slot 7 (Pan)") {
            let (mcu, uad, mockMidi) = TestAudioFixture.makeMCUEngine(channelCount: 16)

            // Enter CUE/SENDS mode (Note 41 = SEND button)
            mcu.handleMidiBytes([0x90, 41, 0x7F])
            mcu.handleMidiBytes([0x90, 41, 0x00])
            assertTrue(mcu.sendsFocusMode, "Must enter CUE/SENDS focus mode")
            assertEqual(mcu.sendsFocusChannel, 0, "Focused channel must be channel 0")
            assertEqual(uad.activeSendsChannel, 0, "activeSendsChannel must track channel 0")

            guard let ch0 = uad.channels[0] else {
                assertTrue(false, "Channel 0 must exist")
                return
            }

            // Configure Send parameters on Channel 0:
            // Send 0 (AUX 1): 0.0 dB (unity, tapered ~0.7818)
            ch0.sends[0]?.gain = 0.7818
            ch0.sends[0]?.gainDb = 0.0
            ch0.sends[0]?.bypass = false

            // Send 1 (AUX 2): -6.0 dB
            ch0.sends[1]?.gain = 0.65
            ch0.sends[1]?.gainDb = -6.0
            ch0.sends[1]?.bypass = false

            // Send 2 (HP 1): 0.0 dB (unity)
            ch0.sends[2]?.gain = 0.7818
            ch0.sends[2]?.gainDb = 0.0
            ch0.sends[2]?.bypass = false

            // Send 3 (HP 2): -12.0 dB
            ch0.sends[3]?.gain = 0.56
            ch0.sends[3]?.gainDb = -12.0
            ch0.sends[3]?.bypass = false

            // Send 4 (CUE 3): Bypassed
            ch0.sends[4]?.gain = 0.7818
            ch0.sends[4]?.gainDb = 0.0
            ch0.sends[4]?.bypass = true

            // Send 5 (CUE 4): Down (-144 dB)
            ch0.sends[5]?.gain = 0.0
            ch0.sends[5]?.gainDb = -144.0
            ch0.sends[5]?.bypass = false

            // Clear MIDI output packet recorder
            mockMidi.clear()

            // Feed channel audio into Channel 0 (-6.0 dBFS)
            uad.simulateInboundFrame(path: "/devices/0/inputs/0/meters/0", data: [
                "properties": [
                    "MeterLevel": ["value": -6.0],
                    "MeterPeakLevel": ["value": -6.0],
                    "MeterClip": ["value": false]
                ]
            ])

            // Verify active sends show dynamic meter levels:
            // Slot 0 (AUX 1): -6 dB audio + 0 dB send = -6 dBFS -> meter > 0
            let m0 = mockMidi.lastMeterLevel(slot: 0)
            assertNotNil(m0, "Slot 0 (AUX 1 send) must receive meter packets")
            assertTrue(m0 != nil && m0! > 0, "Slot 0 meter level must be active (> 0)")

            // Slot 1 (AUX 2): -6 dB audio - 6 dB send = -12 dBFS -> meter > 0
            let m1 = mockMidi.lastMeterLevel(slot: 1)
            assertNotNil(m1, "Slot 1 (AUX 2 send) must receive meter packets")
            assertTrue(m1 != nil && m1! > 0, "Slot 1 meter level must be active (> 0)")

            // Slot 2 (HP 1): -6 dB audio + 0 dB send = -6 dBFS -> meter > 0
            let m2 = mockMidi.lastMeterLevel(slot: 2)
            assertNotNil(m2, "Slot 2 (HP 1 send) must receive meter packets")
            assertTrue(m2 != nil && m2! > 0, "Slot 2 meter level must be active (> 0)")

            // Slot 3 (HP 2): -6 dB audio - 12 dB send = -18 dBFS -> meter > 0
            let m3 = mockMidi.lastMeterLevel(slot: 3)
            assertNotNil(m3, "Slot 3 (HP 2 send) must receive meter packets")
            assertTrue(m3 != nil && m3! > 0, "Slot 3 meter level must be active (> 0)")

            // Slot 4 (CUE 3 bypassed): must be 0 (silent)
            let m4 = mockMidi.lastMeterLevel(slot: 4)
            assertNotNil(m4, "Slot 4 (CUE 3 bypassed) must receive meter packet")
            assertEqual(m4, 0, "Slot 4 bypassed send must have meter level 0")

            // Slot 5 (CUE 4 down): must be 0 (silent)
            let m5 = mockMidi.lastMeterLevel(slot: 5)
            assertNotNil(m5, "Slot 5 (CUE 4 at 0) must receive meter packet")
            assertEqual(m5, 0, "Slot 5 at -oo dB must have meter level 0")

            // Slot 6 (OUTPUT): tracks channel output -> meter > 0
            let m6 = mockMidi.lastMeterLevel(slot: 6)
            assertNotNil(m6, "Slot 6 (OUTPUT) must receive meter packets")
            assertTrue(m6 != nil && m6! > 0, "Slot 6 meter level must be active (> 0)")

            // Slot 7 (PAN): tracks channel pan/balance -> meter > 0
            let m7 = mockMidi.lastMeterLevel(slot: 7)
            assertNotNil(m7, "Slot 7 (PAN) must receive meter packets")
            assertTrue(m7 != nil && m7! > 0, "Slot 7 meter level must be active (> 0)")

            // Test hardware direct send meter message
            uad.simulateInboundFrame(path: "/devices/0/inputs/0/sends/0/meters/0", data: [
                "properties": [
                    "MeterLevel": ["value": -2.0],
                    "MeterPeakLevel": ["value": -2.0],
                    "MeterClip": ["value": false]
                ]
            ])
            let m0Direct = mockMidi.lastMeterLevel(slot: 0)
            assertTrue(m0Direct != nil && m0Direct! >= (m0 ?? 0), "Hardware send meter packet must update Slot 0 meter")

            // Exit CUE/SENDS mode
            mcu.handleMidiBytes([0x90, 41, 0x7F])
            mcu.handleMidiBytes([0x90, 41, 0x00])
            assertFalse(mcu.sendsFocusMode, "Must exit CUE/SENDS mode")
            assertEqual(uad.activeSendsChannel, nil, "activeSendsChannel must be cleared on exit")
        }
    }
}
