// ==============================================================================
// Copyright (c) 2026 S&D A11y Studio. All Rights Reserved.
//
// Test Mocks & Fixtures for UA-MCU Bridge Test Suite
// ==============================================================================

import Foundation

public final class MockMIDIOutput {
    public private(set) var sentPackets: [[UInt8]] = []

    public init() {}

    public func send(_ bytes: [UInt8]) {
        sentPackets.append(bytes)
    }

    public func clear() {
        sentPackets.removeAll()
    }

    public func lastSysexText(row: Int) -> String? {
        let targetOffset: UInt8 = (row == 1) ? 56 : 0
        for pkt in sentPackets.reversed() {
            if pkt.count >= 7 && pkt[0] == 0xF0 && pkt[1] == 0x00 && pkt[2] == 0x00 && pkt[3] == 0x66 && pkt[5] == 0x12 && pkt[6] == targetOffset {
                let asciiBytes = pkt[7..<(pkt.count - 1)]
                return String(bytes: asciiBytes, encoding: .ascii)
            }
        }
        return nil
    }

    public func noteTallyState(note: Int) -> Bool? {
        for pkt in sentPackets.reversed() {
            if pkt.count == 3 && (pkt[0] == 0x90 || pkt[0] == 0x80) && Int(pkt[1]) == note {
                return (pkt[0] == 0x90) && (pkt[2] > 0)
            }
        }
        return nil
    }

    public func lastFaderPosition(slot: Int) -> Double? {
        let targetStatus = UInt8(0xE0 | (slot & 0x0F))
        for pkt in sentPackets.reversed() {
            if pkt.count == 3 && pkt[0] == targetStatus {
                let lsb = Int(pkt[1])
                let msb = Int(pkt[2])
                let intVal = (msb << 7) | lsb
                return Double(intVal) / 16383.0
            }
        }
        return nil
    }

    public func lastMeterLevel(slot: Int) -> UInt8? {
        for pkt in sentPackets.reversed() {
            if pkt.count == 2 && pkt[0] == 0xD0 && (Int(pkt[1]) >> 4) == slot {
                return pkt[1] & 0x0F
            }
        }
        return nil
    }
}

public final class TestAudioFixture {
    public static func makeMCUEngine(channelCount: Int = 32) -> (mcu: MCUEngine, uad: UADClient, mockMidi: MockMIDIOutput) {
        let uad = UADClient()
        let chs = makeChannels(count: channelCount)
        uad.channels = chs
        for (_, ch) in chs {
            if !ch.devPath.isEmpty {
                uad.pathToChannel[ch.devPath] = ch
            }
        }
        let mockMidi = MockMIDIOutput()
        let mcu = MCUEngine(uadClient: uad, sendMIDIFn: { mockMidi.send($0) })
        mcu.voice.isEnabled = false
        return (mcu, uad, mockMidi)
    }

    public static func makeChannels(count: Int = 32) -> [Int: UADChannel] {
        var chs: [Int: UADChannel] = [:]
        for i in 0..<count {
            let ch = UADChannel(id: i, name: "Ch \(i + 1)", chType: (i >= 30) ? "aux" : "input")
            ch.devPath = "/devices/0/inputs/\(i)"
            ch.fader = 0.75
            ch.faderDb = 0.0
            ch.pan = 0.0
            ch.mute = false
            ch.solo = false

            if i < 4 {
                ch.preamp.hasPreamp = true
                ch.preamp.gain = 25.0
                ch.preamp.gainTapered = 0.3
                ch.preamp.phantom48V = false
                ch.preamp.pad = false
                ch.preamp.lowCut = false
                ch.preamp.phase = false
            }

            chs[i] = ch
        }
        return chs
    }
}
