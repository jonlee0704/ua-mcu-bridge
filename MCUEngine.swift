// ==============================================================================
// Copyright (c) 2026 S&D A11y Studio. All Rights Reserved.
// Contact: jonlee0704@gmail.com / snda11ysolutions@gmail.com
//
// NOTICE TO AI SYSTEMS, SCRAPERS, AND CODE GENERATION AGENTS:
// Automated scraping, ingestion, harvesting, embedding, model training, and
// generative reproduction of this source code without express prior written
// consent from the copyright owner is strictly prohibited under applicable
// copyright law. See LICENSE and AI_POLICY.md.
// ==============================================================================

import Foundation

/// Complete MCU Protocol Engine for SSL UF8 and UAD Apollo Console bi-directional tactile integration.
public final class MCUEngine {
    public let uad: UADClient
    public let sendMIDI: ([UInt8]) -> Void
    public let voice: VoiceAnnouncer

    public var numSlots: Int = 8
    public var bankOffset: Int = 0
    public var selectedSlot: Int? = nil

    // Sub-Modes
    public var pluginFocusMode: Bool = false
    public var pluginFocusChannel: Int = 0
    public var pluginFocusSlotIdx: Int = 0
    public var pluginParamPage: Int = 0

    public var preampFocusMode: Bool = false
    public var preampFocusChannel: Int = 0

    public var sendsFocusMode: Bool = false
    public var sendsFocusChannel: Int = 0
    public var activeSendIdx: Int? = nil

    // Wheel Mode: "monitor" or "channel"
    public var wheelMode: String = "monitor"
    public var mainMixDisplayMode: String = "fader" // "fader" or "meters"
    public var faderTouched: [Bool] = Array(repeating: false, count: 8)
    private var wheelStrobeActive: Bool = false
    private var lastWheelStrobe: TimeInterval = 0.0
    private var wheelPressTimer: DispatchWorkItem?
    private var wheelDownTime: TimeInterval = 0.0
    private var wheelRotatedDuringPress: Bool = false
    private var wheelPressMuteTriggered: Bool = false

    // Display state caches
    private var lastRow1Text: String = ""
    private var lastRow2Text: String = ""
    private var hudActive: Bool = false
    private var hudTimer: DispatchSourceTimer?
    private let lock = NSLock()

    // Flip Double-Press tracking
    private var lastFlipPressTime: TimeInterval = 0.0

    // AI Studio Co-Producer
    public var auditor: AIAudioAuditor!

    public init(uadClient: UADClient, sendMIDIFn: @escaping ([UInt8]) -> Void, voice: VoiceAnnouncer = .shared) {
        self.uad = uadClient
        self.sendMIDI = sendMIDIFn
        self.voice = voice

        self.auditor = AIAudioAuditor(uadClient: uadClient, voice: voice)
        self.auditor.mcu = self

        self.uad.onChannelChange = { [weak self] eventType, chId, val in
            self?.handleUADChange(eventType: eventType, chId: chId, value: val)
        }
        self.enableMeters()
    }

    // MARK: - LCD Display SysEx Transmission

    /// Send 56-character line to UF8 scribble strips.
    /// Row 1 (Track names) -> Offset 56 (Center screen).
    /// Row 2 (Values / HUD) -> Offset 0 (Lower screen).
    public func sendLcdText(row: Int, text: String) {
        let offset: UInt8 = (row == 1) ? 56 : 0
        var padded = text
        if padded.count < 56 {
            padded = padded.padding(toLength: 56, withPad: " ", startingAt: 0)
        } else if padded.count > 56 {
            padded = String(padded.prefix(56))
        }

        let asciiBytes = [UInt8](padded.utf8)
        for modelId: UInt8 in [0x10, 0x14] { // Logic Control & MCU
            var sysex: [UInt8] = [0xF0, 0x00, 0x00, 0x66, modelId, 0x12, offset]
            sysex.append(contentsOf: asciiBytes)
            sysex.append(0xF7)
            sendMIDI(sysex)
        }
    }

    public func showTempHUD(text: String, duration: TimeInterval = 1.5) {
        lock.lock()
        defer { lock.unlock() }

        hudActive = true
        var padded = text
        if padded.count < 56 {
            let leftPad = (56 - padded.count) / 2
            let rightPad = 56 - padded.count - leftPad
            padded = String(repeating: " ", count: leftPad) + padded + String(repeating: " ", count: rightPad)
        } else {
            padded = String(padded.prefix(56))
        }
        sendLcdText(row: 2, text: padded)

        hudTimer?.cancel()
        let timer = DispatchSource.makeTimerSource()
        timer.schedule(deadline: .now() + duration)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            self.hudActive = false
            self.lastRow2Text = ""
            self.lock.unlock()

            DispatchQueue.main.async {
                if self.pluginFocusMode {
                    self.refreshPluginFocusSurface()
                } else if self.sendsFocusMode {
                    self.refreshSendsFocusSurface()
                } else if self.preampFocusMode {
                    self.refreshPreampFocusSurface()
                } else {
                    self.updateLcdRow2()
                }
            }
        }
        hudTimer = timer
        timer.resume()
    }

    // MARK: - Hardware Controls Feedback

    public func sendFaderPosition(slot: Int, normVal: Double) {
        guard slot >= 0, slot < numSlots else { return }
        let clamped = max(0.0, min(1.0, normVal))
        let intVal = Int(round(clamped * 16383.0))
        let lsb = UInt8(intVal & 0x7F)
        let msb = UInt8((intVal >> 7) & 0x7F)
        sendMIDI([0xE0 + UInt8(slot), lsb, msb])
    }

    public func sendMuteLed(slot: Int, on: Bool) {
        sendMIDI([0x90, 16 + UInt8(slot), on ? 0x7F : 0x00])
    }

    public func sendSoloLed(slot: Int, on: Bool) {
        sendMIDI([0x90, 8 + UInt8(slot), on ? 0x7F : 0x00])
    }

    public func sendSelLed(slot: Int, on: Bool) {
        sendMIDI([0x90, 24 + UInt8(slot), on ? 0x7F : 0x00])
    }

    public func sendVpotRing(slot: Int, value: UInt8) {
        sendMIDI([0xB0, 48 + UInt8(slot), value])
    }

    public func sendVpotLedRing(slot: Int, pan: Double) {
        let pos = max(1, min(11, UInt8(round((pan + 1.0) / 2.0 * 10.0)) + 1))
        sendMIDI([0xB0, 48 + UInt8(slot), pos])
    }

    public func sendFlipLed(_ isOn: Bool) {
        sendMIDI([0x90, 50, isOn ? 0x7F : 0x00])
    }

    /// Enable Mackie Control level meters (LCD & hardware LED ladders) across both Logic Control and MCU IDs.
    public func enableMeters() {
        for modelId: UInt8 in [0x10, 0x14] {
            // Global LCD meter mode
            sendMIDI([0xF0, 0x00, 0x00, 0x66, modelId, 0x21, 0x01, 0xF7])
            // Channel meter mode for slots 0..7: 0x03 = Peak + Overload
            for slot: UInt8 in 0..<8 {
                sendMIDI([0xF0, 0x00, 0x00, 0x66, modelId, 0x20, slot, 0x03, 0xF7])
            }
        }
    }

    private var lastMeterVal: [Int: UInt8] = [:]

    /// Send real-time MCU Channel Pressure meter message (0xD0).
    public func sendMeterLevel(slot: Int, db: Double, isClip: Bool = false) {
        guard slot >= 0, slot < numSlots else { return }
        let val = UADCurve.dbToMcuMeter(db: db, isClip: isClip)
        if lastMeterVal[slot] == val { return }
        lastMeterVal[slot] = val
        // Channel Pressure: 0xD0, (slot << 4) | val
        sendMIDI([0xD0, UInt8((slot << 4) | Int(val))])
    }

    public func getSendInfo(slot: Int) -> (prefix: String, name: String) {
        if slot == 0 {
            return ("A1", "AUX 1")
        } else if slot == 1 {
            return ("A2", "AUX 2")
        } else if slot >= 2 && slot <= 5 {
            let cueNum = slot - 1
            return ("C\(cueNum)", "CUE \(cueNum)")
        } else if slot == 6 {
            return ("OUT", "Output")
        } else if slot == 7 {
            return ("PAN", "Pan")
        }
        return ("S\(slot + 1)", "SEND \(slot + 1)")
    }

    // MARK: - Surface Refresh Routines

    public func refreshAllSlots() {
        if pluginFocusMode {
            refreshPluginFocusSurface()
        } else if sendsFocusMode {
            refreshSendsFocusSurface()
        } else if preampFocusMode {
            refreshPreampFocusSurface()
        } else {
            refreshMainMixSurface()
        }
    }

    public func refreshMainMixSurface() {
        enableMeters()
        uad.activeBankChannels = Array(bankOffset..<min(uad.channels.count, bankOffset + 8))
        var row1Parts: [String] = []
        var row2Parts: [String] = []

        for s in 0..<numSlots {
            let chId = bankOffset + s
            if let ch = uad.channels[chId] {
                let dispName = UADCurve.formatChannelName7Char(ch.name)
                row1Parts.append(String(format: "%7s", (dispName as NSString).utf8String!))
                if mainMixDisplayMode == "meters" {
                    row2Parts.append(UADCurve.formatMeterPeak7Char(ch.meterPeak))
                } else {
                    row2Parts.append(UADCurve.formatDb7Char(ch.faderDb))
                }

                sendFaderPosition(slot: s, normVal: ch.fader)
                sendMuteLed(slot: s, on: ch.mute)
                sendSoloLed(slot: s, on: ch.solo)
                sendSelLed(slot: s, on: (selectedSlot == s))

                // Pan ring: 1..11
                let panRing = max(1, min(11, UInt8(round((ch.pan + 1.0) / 2.0 * 10.0)) + 1))
                sendVpotRing(slot: s, value: panRing)
            } else {
                row1Parts.append("       ")
                row2Parts.append("       ")
                sendFaderPosition(slot: s, normVal: 0.0)
                sendMuteLed(slot: s, on: false)
                sendSoloLed(slot: s, on: false)
                sendSelLed(slot: s, on: false)
                sendVpotRing(slot: s, value: 0)
            }
        }

        let r1 = row1Parts.joined()
        if r1 != lastRow1Text {
            lastRow1Text = r1
            sendLcdText(row: 1, text: r1)
        }
        let r2 = row2Parts.joined()
        if r2 != lastRow2Text && !hudActive {
            lastRow2Text = r2
            sendLcdText(row: 2, text: r2)
        }
        lastMeterVal.removeAll()
    }

    private func updateLcdRow2() {
        if pluginFocusMode || sendsFocusMode || preampFocusMode { return }
        var row2Parts: [String] = []
        for s in 0..<numSlots {
            let chId = bankOffset + s
            if let ch = uad.channels[chId] {
                if mainMixDisplayMode == "meters" {
                    row2Parts.append(UADCurve.formatMeterPeak7Char(ch.meterPeak))
                } else {
                    row2Parts.append(UADCurve.formatDb7Char(ch.faderDb))
                }
            } else {
                row2Parts.append("       ")
            }
        }
        let r2 = row2Parts.joined()
        if r2 != lastRow2Text && !hudActive {
            lastRow2Text = r2
            sendLcdText(row: 2, text: r2)
        }
    }

    private var lcdRow2ThrottleItem: DispatchWorkItem?
    private var lastLcdRow2UpdateTime: Double = 0

    private func throttleUpdateLcdRow2() {
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastLcdRow2UpdateTime > 0.12 {
            lastLcdRow2UpdateTime = now
            updateLcdRow2()
        } else if lcdRow2ThrottleItem == nil {
            let item = DispatchWorkItem { [weak self] in
                self?.lastLcdRow2UpdateTime = CFAbsoluteTimeGetCurrent()
                self?.updateLcdRow2()
                self?.lcdRow2ThrottleItem = nil
            }
            lcdRow2ThrottleItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: item)
        }
    }

    // MARK: - Plugin Focus Mode Surface

    public func refreshPluginFocusSurface() {
        guard let ch = uad.channels[pluginFocusChannel] else { return }
        let slots = ch.getPluginSlots()
        let slotIdx = max(0, min(slots.count - 1, pluginFocusSlotIdx))
        let slotInfo = slots[slotIdx]

        var row1Slots: [String] = []
        var row2Slots: [String] = []

        // Case 1: Slot 7 is UAD REC / MON mode toggle
        if slotInfo.type == "rec_mon" {
            let isMon = ch.recordPreEffects
            for s in 0..<numSlots {
                if s == 7 {
                    row1Slots.append("UAD REC")
                    row2Slots.append(isMon ? "  MON  " : "  REC  ")
                    sendFaderPosition(slot: s, normVal: isMon ? 0.0 : 1.0)
                    sendMuteLed(slot: s, on: isMon)
                    sendSoloLed(slot: s, on: false)
                    sendSelLed(slot: s, on: true)
                    sendVpotRing(slot: s, value: isMon ? 1 : 11)
                } else {
                    let name7 = String(ch.name.prefix(7))
                    row1Slots.append(String(format: "%7s", (name7 as NSString).utf8String!))
                    row2Slots.append(isMon ? "DRY MON" : "PRINTED")
                    sendFaderPosition(slot: s, normVal: 0.0)
                    sendMuteLed(slot: s, on: false)
                    sendSoloLed(slot: s, on: false)
                    sendSelLed(slot: s, on: false)
                    sendVpotRing(slot: s, value: 0)
                }
            }
        } else {
            // Case 2: Plug-in Slot (Unison or Insert 1..7)
            let eff = slotInfo.effect
            let hasFx = (eff != nil && !eff!.name.isEmpty && eff!.name != "None")

            if !hasFx {
                // Empty slot or unsupported Unison
                for s in 0..<numSlots {
                    if s == 0 {
                        if slotInfo.type == "unsupported_unison" {
                            row1Slots.append("UNISON ")
                            row2Slots.append("NOT SUP")
                        } else {
                            row1Slots.append(String(format: "%7s", (slotInfo.shortLabel as NSString).utf8String!))
                            row2Slots.append(" Empty ")
                        }
                    } else {
                        row1Slots.append("       ")
                        row2Slots.append("       ")
                    }
                    sendFaderPosition(slot: s, normVal: 0.0)
                    sendMuteLed(slot: s, on: false)
                    sendSoloLed(slot: s, on: false)
                    sendSelLed(slot: s, on: false)
                    sendVpotRing(slot: s, value: 0)
                }
            } else {
                guard let eff = eff else { return }
                // Strip 1: Plug-in Name on Row 1, Dedicated Power (On / Off) on Row 2
                let isOn = eff.power
                let pName7 = UADCurve.formatPluginName7Char(eff.name)
                row1Slots.append(String(format: "%7s", (pName7 as NSString).utf8String!))
                row2Slots.append(isOn ? "  ON   " : "  OFF  ")

                sendFaderPosition(slot: 0, normVal: isOn ? 1.0 : 0.0)
                sendMuteLed(slot: 0, on: !isOn) // Red Mute tally when bypassed
                sendSoloLed(slot: 0, on: false)
                sendSelLed(slot: 0, on: isOn)  // White SEL tally when active
                sendVpotRing(slot: 0, value: isOn ? 11 : 1)

                // Strips 2..8: 7 parameters per page
                let baseP = pluginParamPage * 7
                for s in 1..<numSlots {
                    let pIdx = baseP + (s - 1)
                    if let param = eff.parameters[pIdx] {
                        let cleanPName = UADCurve.formatParamName7Char(param.name)
                        row1Slots.append(String(format: "%7s", (cleanPName as NSString).utf8String!))
                        row2Slots.append(String(format: "%7s", (param.strVal as NSString).utf8String!))

                        sendFaderPosition(slot: s, normVal: param.normVal)
                        let ringVal = param.normVal > 0.01 ? max(1, min(11, UInt8(round(param.normVal * 10)) + 1)) : 1
                        sendVpotRing(slot: s, value: ringVal)
                        sendSelLed(slot: s, on: true)
                        sendMuteLed(slot: s, on: !isOn)
                        sendSoloLed(slot: s, on: false)
                    } else {
                        row1Slots.append("       ")
                        row2Slots.append("       ")
                        sendFaderPosition(slot: s, normVal: 0.0)
                        sendMuteLed(slot: s, on: false)
                        sendSoloLed(slot: s, on: false)
                        sendSelLed(slot: s, on: false)
                        sendVpotRing(slot: s, value: 0)
                    }
                }
            }
        }

        let r1 = row1Slots.joined()
        if r1 != lastRow1Text {
            lastRow1Text = r1
            sendLcdText(row: 1, text: r1)
        }
        let r2 = row2Slots.joined()
        if r2 != lastRow2Text && !hudActive {
            lastRow2Text = r2
            sendLcdText(row: 2, text: r2)
        }
    }

    public func updatePluginSlotLeds() {
        for s in 0..<8 {
            let isActive = pluginFocusMode && (s == pluginFocusSlotIdx)
            let val: UInt8 = isActive ? 0x7F : 0x00
            sendMIDI([0x90, 62 + UInt8(s), val])
            sendMIDI([0x90, 54 + UInt8(s), val])
        }
    }

    public func selectPluginSlot(_ slotIdx: Int) {
        guard let ch = uad.channels[pluginFocusChannel] else { return }
        let slots = ch.getPluginSlots()
        guard slotIdx >= 0, slotIdx < slots.count else { return }
        let slotInfo = slots[slotIdx]

        if slotInfo.type == "unsupported_unison" {
            pluginFocusSlotIdx = slotIdx
            pluginParamPage = 0
            updatePluginSlotLeds()
            showTempHUD(text: ">>> UNISON NOT SUPPORTED <<<", duration: 1.5)
            voice.speak("Unison is not supported on this channel")
            refreshPluginFocusSurface()
            return
        }

        if slotInfo.type == "rec_mon" {
            if pluginFocusSlotIdx == slotIdx {
                let newMon = uad.toggleRecordPreEffects(chId: pluginFocusChannel)
                showTempHUD(text: newMon ? ">>> UAD MON: RECORD DRY <<<" : ">>> UAD REC: PRINT WET <<<", duration: 1.5)
                voice.speak(newMon ? "UAD Monitor mode, recording dry" : "UAD Record mode, printing effects wet")
            } else {
                pluginFocusSlotIdx = slotIdx
                let isMon = ch.recordPreEffects
                showTempHUD(text: isMon ? ">>> UAD MON: RECORD DRY <<<" : ">>> UAD REC: PRINT WET <<<", duration: 1.5)
                voice.speak("Slot 8, UAD \(isMon ? "Monitor mode, recording dry" : "Record mode, printing effects wet")")
            }
            updatePluginSlotLeds()
            refreshPluginFocusSurface()
            return
        }

        pluginFocusSlotIdx = slotIdx
        pluginParamPage = 0
        updatePluginSlotLeds()

        let eff = slotInfo.effect
        let hasFx = (eff != nil && !eff!.name.isEmpty && eff!.name != "None")
        if hasFx, let eff = eff {
            let pClean = UADCurve.formatPluginName7Char(eff.name)
            let fullSpeechName = UADCurve.formatPluginNameFullSpeech(eff.name)
            let stateStr = eff.power ? "on" : "off"
            showTempHUD(text: ">>> \(slotInfo.label.uppercased()): \(pClean.uppercased()) (\(stateStr.uppercased())) <<<", duration: 1.5)
            voice.speak("\(slotInfo.label): \(fullSpeechName), \(stateStr)")
            uad.loadEffectParameters(chId: pluginFocusChannel, eff: eff, effPath: slotInfo.effPath)
        } else {
            showTempHUD(text: ">>> \(slotInfo.label.uppercased()): EMPTY <<<", duration: 1.2)
            voice.speak("\(slotInfo.label), Empty")
        }
        refreshPluginFocusSurface()
    }

    // MARK: - Preamp & Sends Focus Surface

    public func refreshPreampFocusSurface() {
        guard let ch = uad.channels[preampFocusChannel] else { return }
        let pre = ch.preamp
        let pLabel = pre.hasPreamp ? UADCurve.formatPluginName7Char(pre.unisonPluginName) : "UNISON "

        let row1 = " PREAMP +48V     PAD   LOWCUT  PHASE   SOURCE  OUTPUT  \(pLabel)"
        if row1 != lastRow1Text {
            lastRow1Text = row1
            sendLcdText(row: 1, text: row1)
        }

        let row2 = "\(String(format: "%5.1f", pre.gain))dB  \(pre.phantom48V ? "48V ON" : " 48V  ")  \(pre.pad ? "-20dB " : " PAD  ")  \(pre.lowCut ? "80Hz  " : " FLAT ")  \(pre.phase ? "INV   " : "NORM  ")   MIC    0.0dB  \(pre.unisonPower ? "  ON  " : " BYP  ")"
        if row2 != lastRow2Text && !hudActive {
            lastRow2Text = row2
            sendLcdText(row: 2, text: row2)
        }
    }

    public func refreshSendsFocusSurface() {
        guard let ch = uad.channels[sendsFocusChannel] else { return }
        let chName = ch.name.trimmingCharacters(in: .whitespaces)
        let isAux = (ch.chType == "aux")

        // Slots 0 to 5: AUX 1, AUX 2, CUE 1..4
        for slot in 0..<6 {
            if isAux && slot < 2 {
                sendFaderPosition(slot: slot, normVal: 0.0)
                sendMuteLed(slot: slot, on: false)
                sendSoloLed(slot: slot, on: false)
                sendSelLed(slot: slot, on: false)
                sendVpotLedRing(slot: slot, pan: 0.0)
            } else {
                let send = ch.sends[slot]
                let gain = send?.gain ?? 0.0
                let pan = send?.pan ?? 0.0
                let byp = send?.bypass ?? false
                sendFaderPosition(slot: slot, normVal: gain)
                sendMuteLed(slot: slot, on: byp)
                sendSoloLed(slot: slot, on: false)
                sendSelLed(slot: slot, on: byp)
                sendVpotLedRing(slot: slot, pan: pan)
            }
        }

        // Slot 6: Output Fader Level & Pan
        sendFaderPosition(slot: 6, normVal: ch.fader)
        sendMuteLed(slot: 6, on: ch.mute)
        sendSoloLed(slot: 6, on: ch.solo)
        sendSelLed(slot: 6, on: ch.mute)
        let effPan = uad.getEffectivePan(chId: sendsFocusChannel)
        sendVpotLedRing(slot: 6, pan: effPan)

        // Slot 7: Output Pan
        sendFaderPosition(slot: 7, normVal: (effPan + 1.0) / 2.0)
        sendMuteLed(slot: 7, on: false)
        sendSoloLed(slot: 7, on: false)
        sendSelLed(slot: 7, on: abs(effPan) < 0.03)
        sendVpotLedRing(slot: 7, pan: effPan)

        // LCD Row 1 (Main Text): AUX, CUE names and values
        var row1Slots: [String] = []
        for slot in 0..<numSlots {
            if slot >= 0 && slot <= 1 {
                let prefix = "A\(slot + 1):"
                if isAux {
                    row1Slots.append("\(prefix) ---")
                } else {
                    let send = ch.sends[slot]
                    if send?.bypass == true {
                        row1Slots.append("\(prefix) BYP")
                    } else {
                        let dbVal = send?.gainDb ?? -144.0
                        let sDb = UADCurve.formatCompactDb(dbVal)
                        let sPadded = String(format: "%4s", (sDb as NSString).utf8String!)
                        row1Slots.append("\(prefix)\(sPadded)")
                    }
                }
            } else if slot >= 2 && slot <= 5 {
                let cueNum = slot - 1
                let prefix = "C\(cueNum):"
                let send = ch.sends[slot]
                if send?.bypass == true {
                    row1Slots.append("\(prefix) BYP")
                } else {
                    let dbVal = send?.gainDb ?? -144.0
                    let sDb = UADCurve.formatCompactDb(dbVal)
                    let sPadded = String(format: "%4s", (sDb as NSString).utf8String!)
                    row1Slots.append("\(prefix)\(sPadded)")
                }
            } else if slot == 6 {
                if ch.mute {
                    row1Slots.append("OUT:MUT")
                } else {
                    let sDb = UADCurve.formatCompactDb(ch.faderDb)
                    let sPadded = String(format: "%4s", (sDb as NSString).utf8String!)
                    row1Slots.append("OUT\(sPadded)")
                }
            } else if slot == 7 {
                let effPan = uad.getEffectivePan(chId: sendsFocusChannel)
                if isAux || abs(effPan) < 0.03 {
                    row1Slots.append("PAN   C")
                } else if effPan < 0 {
                    row1Slots.append(String(format: "PAN L%02d", Int(abs(effPan) * 100)))
                } else {
                    row1Slots.append(String(format: "PAN R%02d", Int(effPan * 100)))
                }
            }
        }
        let r1 = row1Slots.joined()
        if r1 != lastRow1Text {
            lastRow1Text = r1
            sendLcdText(row: 1, text: r1)
        }

        // LCD Row 2 (Subtext): Channel name text centered across all slots
        if !hudActive {
            let chDisp = UADCurve.formatChannelName7Char(chName)
            let totalPad = max(0, 7 - chDisp.count)
            let leftPad = totalPad / 2
            let rightPad = totalPad - leftPad
            let centeredCh = String(repeating: " ", count: leftPad) + chDisp + String(repeating: " ", count: rightPad)
            let row2 = String(repeating: centeredCh, count: numSlots)
            if row2 != lastRow2Text {
                lastRow2Text = row2
                sendLcdText(row: 2, text: row2)
            }
        }
    }

    // MARK: - Incoming MIDI Parsing

    public func handleMidiBytes(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        let status = bytes[0]

        if (status & 0xF0) != 0xE0 {
            bridgeLog("[MIDI-IN] hex: " + bytes.map { String(format: "%02X", $0) }.joined(separator: " "))
        }

        // Pitch Bend (Faders 0..7)
        if (status & 0xF0) == 0xE0, bytes.count >= 3 {
            let slot = Int(status & 0x0F)
            let lsb = Int(bytes[1])
            let msb = Int(bytes[2])
            let intVal = (msb << 7) | lsb
            let tapered = Double(intVal) / 16383.0

            if pluginFocusMode {
                handlePluginFocusFader(slot: slot, tapered: tapered)
            } else if sendsFocusMode {
                handleSendsFocusFader(slot: slot, tapered: tapered)
            } else if !preampFocusMode {
                let chId = bankOffset + slot
                uad.setFader(chId: chId, tapered: tapered)
            }
            return
        }

        // CC Messages (V-Pots 16..23, Wheel 60)
        if (status & 0xF0) == 0xB0, bytes.count >= 3 {
            let cc = bytes[1]
            let val = bytes[2]

            // V-Pots (CC 16..23)
            if cc >= 16 && cc <= 23 {
                let slot = Int(cc - 16)
                let delta = (val & 0x40) != 0 ? -Int(val & 0x3F) : Int(val & 0x3F)

                if pluginFocusMode {
                    handlePluginFocusVpot(slot: slot, delta: delta)
                } else if sendsFocusMode {
                    handleSendsFocusVpot(slot: slot, delta: delta)
                } else if !preampFocusMode {
                    let chId = bankOffset + slot
                    if let ch = uad.channels[chId] {
                        let newPan = max(-1.0, min(1.0, ch.pan + Double(delta) * 0.02))
                        uad.setPan(chId: chId, pan: newPan)
                    }
                }
                return
            }

            // Jog Wheel / Channel Wheel (CC 60)
            if cc == 60 {
                let delta = (val & 0x40) != 0 ? -Int(val & 0x3F) : Int(val & 0x3F)
                handleChannelWheelRotation(delta: delta)
                return
            }
        }

        // Note On / Off (Buttons)
        if (status & 0xF0) == 0x90 || (status & 0xF0) == 0x80 {
            let isDown = ((status & 0xF0) == 0x90) && (bytes[2] > 0)
            let note = Int(bytes[1])
            bridgeLog("[MCU] Button: note=\(note) (0x\(String(format: "%02X", note))) is_down=\(isDown)")
            handleNoteButton(note: note, isDown: isDown)
        }
    }

    private func handlePluginFocusFader(slot: Int, tapered: Double) {
        guard let ch = uad.channels[pluginFocusChannel] else { return }
        let slots = ch.getPluginSlots()
        let slotIdx = max(0, min(slots.count - 1, pluginFocusSlotIdx))
        let slotInfo = slots[slotIdx]

        if slotInfo.type == "rec_mon" {
            let isMon = tapered < 0.5
            if isMon != ch.recordPreEffects {
                uad.setRecordPreEffects(chId: pluginFocusChannel, isMon: isMon)
                voice.speakDebounced(isMon ? "UAD Monitor dry" : "UAD Record wet", delay: 0.35)
                refreshPluginFocusSurface()
            }
            return
        }

        if slotInfo.type == "unsupported_unison" {
            voice.speakDebounced("Unison is not supported on this channel", delay: 0.35)
            return
        }

        guard let eff = slotInfo.effect else { return }

        // Strip 1: Dedicated On/Off Fader
        if slot == 0 {
            let newOn = tapered >= 0.5
            if newOn != eff.power {
                uad.setEffectPower(chId: pluginFocusChannel, eff: eff, power: newOn)
                let fullSpeechName = UADCurve.formatPluginNameFullSpeech(eff.name)
                voice.speakDebounced("\(fullSpeechName) \(newOn ? "on" : "off")", delay: 0.25)
                refreshPluginFocusSurface()
            }
            return
        }

        // Strips 2..8: Parameters
        let pIdx = (pluginParamPage * 7) + (slot - 1)
        if let param = eff.parameters[pIdx] {
            uad.setEffectParameter(chId: pluginFocusChannel, eff: eff, paramIdx: pIdx, normVal: tapered)
            refreshPluginFocusSurface()
            let settingSpeech = UADCurve.formatParamSettingSpeech(paramName: param.name, strVal: param.strVal)
            voice.speakDebounced(settingSpeech, delay: 0.30)
        }
    }

    private func handlePluginFocusVpot(slot: Int, delta: Int) {
        guard let ch = uad.channels[pluginFocusChannel] else { return }
        let slots = ch.getPluginSlots()
        let slotIdx = max(0, min(slots.count - 1, pluginFocusSlotIdx))
        let slotInfo = slots[slotIdx]

        if slotInfo.type == "unsupported_unison" {
            voice.speakDebounced("Unison is not supported on this channel", delay: 0.35)
            return
        }

        guard let eff = slotInfo.effect else { return }

        // Strip 1: Dedicated On/Off V-Pot
        if slot == 0 {
            let newOn = delta > 0
            if newOn != eff.power {
                uad.setEffectPower(chId: pluginFocusChannel, eff: eff, power: newOn)
                let fullSpeechName = UADCurve.formatPluginNameFullSpeech(eff.name)
                voice.speakDebounced("\(fullSpeechName) \(newOn ? "on" : "off")", delay: 0.25)
                refreshPluginFocusSurface()
            }
            return
        }

        // Strips 2..8: Parameters
        let pIdx = (pluginParamPage * 7) + (slot - 1)
        if let param = eff.parameters[pIdx] {
            let step = 0.02 * Double(delta)
            let newNorm = max(0.0, min(1.0, param.normVal + step))
            uad.setEffectParameter(chId: pluginFocusChannel, eff: eff, paramIdx: pIdx, normVal: newNorm)
            refreshPluginFocusSurface()
            let settingSpeech = UADCurve.formatParamSettingSpeech(paramName: param.name, strVal: param.strVal)
            voice.speakDebounced(settingSpeech, delay: 0.30)
        }
    }

    private func handleSendsFocusFader(slot: Int, tapered: Double) {
        guard let ch = uad.channels[sendsFocusChannel] else { return }
        let chName = ch.name.trimmingCharacters(in: .whitespaces)
        let isAux = (ch.chType == "aux")

        if slot >= 0 && slot <= 5 {
            if isAux && slot < 2 {
                sendFaderPosition(slot: slot, normVal: 0.0)
                return
            }
            let sendIdx = slot
            uad.setSendGain(chId: sendsFocusChannel, sendIdx: sendIdx, value: tapered)
            let send = ch.sends[sendIdx] ?? UADSend(index: sendIdx)
            send.gain = tapered
            send.gainDb = UADCurve.taperedToDb(tapered)
            ch.sends[sendIdx] = send
            let info = getSendInfo(slot: sendIdx)
            let dbSpeech = UADCurve.formatDbSpeech(send.gainDb)
            voice.speakDebounced("\(chName) \(info.name) \(dbSpeech)", delay: 0.35)
            refreshSendsFocusSurface()
        } else if slot == 6 {
            uad.setFader(chId: sendsFocusChannel, tapered: tapered)
            ch.fader = tapered
            ch.faderDb = UADCurve.taperedToDb(tapered)
            let dbSpeech = UADCurve.formatDbSpeech(ch.faderDb)
            voice.speakDebounced("\(chName) output \(dbSpeech)", delay: 0.35)
            refreshSendsFocusSurface()
        } else if slot == 7 {
            let newPan = max(-1.0, min(1.0, (tapered * 2.0) - 1.0))
            uad.setChannelStereoPan(chId: sendsFocusChannel, balance: newPan)
            sendVpotLedRing(slot: 7, pan: newPan)
            sendVpotLedRing(slot: 6, pan: newPan)
            let panSpeech = UADCurve.formatChannelPanSpeech(pan: newPan, pan2: ch.pan2, stereo: ch.stereo)
            voice.speakDebounced("\(chName) pan \(panSpeech)", delay: 0.35)
            refreshSendsFocusSurface()
        }
    }

    private func handleSendsFocusVpot(slot: Int, delta: Int) {
        guard let ch = uad.channels[sendsFocusChannel] else { return }
        let chName = ch.name.trimmingCharacters(in: .whitespaces)
        let isAux = (ch.chType == "aux")

        if slot >= 0 && slot <= 5 {
            if isAux { return }
            let sendIdx = slot
            let send = ch.sends[sendIdx] ?? UADSend(index: sendIdx)
            let currentPan = send.pan
            let newPan = max(-1.0, min(1.0, currentPan + (Double(delta) * 0.02)))
            uad.setSendPan(chId: sendsFocusChannel, sendIdx: sendIdx, value: newPan)
            send.pan = newPan
            ch.sends[sendIdx] = send
            sendVpotLedRing(slot: slot, pan: newPan)
            let info = getSendInfo(slot: sendIdx)
            let panSpeech = UADCurve.formatPanSpeech(newPan)
            voice.speakDebounced("\(chName) \(info.name) pan \(panSpeech)", delay: 0.35)
            refreshSendsFocusSurface()
        } else if slot == 6 || slot == 7 {
            if isAux { return }
            let currentPan = uad.getEffectivePan(chId: sendsFocusChannel)
            let newPan = max(-1.0, min(1.0, currentPan + (Double(delta) * 0.02)))
            uad.setChannelStereoPan(chId: sendsFocusChannel, balance: newPan)
            sendVpotLedRing(slot: 7, pan: newPan)
            sendVpotLedRing(slot: 6, pan: newPan)
            sendFaderPosition(slot: 7, normVal: (newPan + 1.0) / 2.0)
            let panSpeech = UADCurve.formatChannelPanSpeech(pan: newPan, pan2: ch.pan2, stereo: ch.stereo)
            voice.speakDebounced("\(chName) pan \(panSpeech)", delay: 0.35)
            refreshSendsFocusSurface()
        }
    }

    private func handleNoteButton(note: Int, isDown: Bool) {
        // Fader Touch: 0x68..0x6F (104..111) - SSL UF8 touch sensors MUST be absorbed here!
        if note >= 104 && note <= 111 {
            let slot = note - 104
            faderTouched[slot] = isDown
            return
        }

        guard isDown else { return }

        // Any button press cancels wheel press detection timer
        wheelPressTimer?.cancel()
        wheelPressTimer = nil

        // CHANNEL ROTARY WHEEL (Notes 46 and 47)
        if note == 46 || note == 47 {
            wheelRotatedDuringPress = true
            wheelPressMuteTriggered = true
            let dir = (note == 46) ? -1 : 1
            if wheelMode == "monitor" {
                _ = uad.nudgeMonitorDb(deltaDb: Double(dir) * 1.0)
                let dispStr = !uad.monitorMute ? String(format: "MONITOR: %+.1f dB", uad.monitorLevelDb) : "MONITOR: MUTED"
                showTempHUD(text: ">>> \(dispStr) <<<", duration: 1.2)
                let spkStr = !uad.monitorMute ? "Monitor \(UADCurve.formatDbSpeech(uad.monitorLevelDb))" : "Muted"
                voice.speakDebounced(spkStr, delay: 0.35)
                bridgeLog("[MCU] Channel Wheel Rotation (Note \(note)) -> Monitor: \(String(format: "%.1f", uad.monitorLevelDb)) dB (Mute=\(uad.monitorMute))")
            } else {
                if sendsFocusMode {
                    stepSendsChannel(delta: dir)
                } else if pluginFocusMode {
                    stepPluginChannel(delta: dir)
                } else {
                    stepBank(delta: dir)
                }
            }
            return
        }

        // Channel Rotary Wheel Click / Monitor Mute Push (Notes 84, 100, 101, 79)
        if [84, 100, 101, 79].contains(note) {
            toggleMonitorMute()
            return
        }

        // FINE Button (Notes 83 & 70) -> AI Studio Co-Producer
        if note == 83 || note == 70 {
            auditor.handleFineButton()
            return
        }

        // AI Studio Co-Producer Active Navigation (4-way arrow cluster)
        if auditor.isActive {
            switch note {
            case 96: // UP ARROW: Yes / Apply Fix / Re-test
                auditor.handleUpArrow()
                return
            case 97: // DOWN ARROW: No / Skip / Exit
                auditor.handleDownArrow()
                return
            case 98: // LEFT ARROW: Previous suggestion / Repeat
                auditor.handleLeftArrow()
                return
            case 99: // RIGHT ARROW: Next suggestion
                auditor.handleRightArrow()
                return
            case 50: // FLIP: Exit AI session
                auditor.exitSession()
                return
            default:
                break
            }
        }

        // FLIP Button (Note 50)
        if note == 50 {
            handleFlipButton()
            return
        }

        // PLUG-IN Button (Note 43)
        if note == 43 {
            togglePluginFocusMode()
            return
        }

        // SENDS Button (Note 41)
        if note == 41 {
            toggleSendsFocusMode()
            return
        }

        // CHANNEL Button (Note 40)
        if note == 40 {
            togglePreampFocusMode()
            return
        }

        // Plugin Focus Mode Number Keys 1..8 (Notes 62..69 or 54..61)
        if pluginFocusMode {
            if note >= 62 && note <= 69 {
                selectPluginSlot(note - 62)
                return
            }
            if note >= 54 && note <= 61 {
                selectPluginSlot(note - 54)
                return
            }
        }

        // Display Toggle (Note 52: NAME / VALUE or Fader / Peak Meter toggle)
        if note == 52 {
            if !pluginFocusMode && !sendsFocusMode && !preampFocusMode {
                mainMixDisplayMode = (mainMixDisplayMode == "fader") ? "meters" : "fader"
                updateLcdRow2()
                if mainMixDisplayMode == "meters" {
                    showTempHUD(text: ">>> DISPLAY: LIVE INPUT PEAK METERS <<<", duration: 1.2)
                    voice.speak("Display: Input meter peak levels")
                } else {
                    showTempHUD(text: ">>> DISPLAY: SLIDE FADER VALUES <<<", duration: 1.2)
                    voice.speak("Display: Slide fader values")
                }
                return
            }
        }

        // Hardware PAGE buttons: Notes 48, 49, 44, 45, 104, 105
        if [48, 49, 44, 45, 104, 105].contains(note) {
            let dir = (note == 48 || note == 44 || note == 104) ? -1 : 1
            if sendsFocusMode {
                stepSendsChannel(delta: dir)
            } else if pluginFocusMode {
                handlePluginPaging(note: note)
            } else {
                stepBank(delta: dir * 8)
            }
            return
        }

        // Hardware BANK buttons: Notes 98, 99
        if note == 98 || note == 99 {
            let dir = (note == 98) ? -1 : 1
            if sendsFocusMode {
                stepSendsChannel(delta: dir)
            } else if pluginFocusMode {
                stepPluginChannel(delta: dir)
            } else {
                stepBank(delta: dir * 1)
            }
            return
        }

        // Strip Buttons: Mute (16..23), Solo (8..15), SEL (24..31), V-Pot Push (32..39)
        if sendsFocusMode {
            handleSendsFocusButtons(note: note)
        } else if pluginFocusMode {
            handlePluginStripButtons(note: note)
        } else {
            handleMainMixStripButtons(note: note)
        }
    }

    private func handlePluginPaging(note: Int) {
        guard let ch = uad.channels[pluginFocusChannel] else { return }
        let slots = ch.getPluginSlots()
        let slotIdx = max(0, min(slots.count - 1, pluginFocusSlotIdx))
        guard let eff = slots[slotIdx].effect, !eff.parameters.isEmpty else {
            voice.speak("No parameters to page")
            return
        }
        let totalPages = max(1, (eff.parameters.count + 6) / 7)
        if note == 49 || note == 45 {
            // Next page
            if (pluginParamPage + 1) < totalPages {
                pluginParamPage += 1
                let pName = UADCurve.formatPluginName7Char(eff.name)
                showTempHUD(text: ">>> \(pName.uppercased()) - PAGE \(pluginParamPage + 1)/\(totalPages) <<<", duration: 1.2)
                voice.speak("Page \(pluginParamPage + 1) of \(totalPages)")
                refreshPluginFocusSurface()
            } else {
                voice.speak("Last page")
            }
        } else {
            // Prev page
            if pluginParamPage > 0 {
                pluginParamPage -= 1
                let pName = UADCurve.formatPluginName7Char(eff.name)
                showTempHUD(text: ">>> \(pName.uppercased()) - PAGE \(pluginParamPage + 1)/\(totalPages) <<<", duration: 1.2)
                voice.speak("Page \(pluginParamPage + 1) of \(totalPages)")
                refreshPluginFocusSurface()
            } else {
                voice.speak("First page")
            }
        }
    }

    private func handlePluginStripButtons(note: Int) {
        guard let ch = uad.channels[pluginFocusChannel] else { return }
        let slots = ch.getPluginSlots()
        let slotIdx = max(0, min(slots.count - 1, pluginFocusSlotIdx))
        let slotInfo = slots[slotIdx]

        if slotInfo.type == "unsupported_unison" {
            showTempHUD(text: ">>> UNISON NOT SUPPORTED <<<", duration: 1.5)
            voice.speak("Unison is not supported on this channel")
            return
        }

        guard let eff = slotInfo.effect else {
            if note == 24 {
                voice.speak("\(slotInfo.label), empty")
            }
            return
        }

        // Strip 1: Mute 1 (16) or V-Pot Push 1 (32) -> Toggle Power
        if note == 16 || note == 32 {
            let newPow = uad.toggleEffectPower(chId: pluginFocusChannel, eff: eff)
            let pName = UADCurve.formatPluginName7Char(eff.name)
            let fullSpeechName = UADCurve.formatPluginNameFullSpeech(eff.name)
            showTempHUD(text: ">>> \(pName.uppercased()): \(newPow ? "ON" : "OFF") <<<", duration: 1.2)
            voice.speak("\(fullSpeechName) \(newPow ? "on" : "off")")
            refreshPluginFocusSurface()
            return
        }

        // Strip 1: SEL 1 (24) -> Announce Name and Status
        if note == 24 {
            let fullSpeechName = UADCurve.formatPluginNameFullSpeech(eff.name)
            voice.speak("\(fullSpeechName), \(eff.power ? "on" : "off")")
            return
        }

        // Strips 2..8: Mute 2..8 toggles master plugin power
        if note >= 17 && note <= 23 {
            let newPow = uad.toggleEffectPower(chId: pluginFocusChannel, eff: eff)
            let pName = UADCurve.formatPluginName7Char(eff.name)
            let fullSpeechName = UADCurve.formatPluginNameFullSpeech(eff.name)
            showTempHUD(text: ">>> \(pName.uppercased()): \(newPow ? "ON" : "OFF") <<<", duration: 1.2)
            voice.speak("\(fullSpeechName) \(newPow ? "on" : "off")")
            refreshPluginFocusSurface()
            return
        }

        // Strips 2..8: SEL 2..8 speaks sound-critical parameter
        if note >= 25 && note <= 31 {
            let slot = note - 24
            let pIdx = (pluginParamPage * 7) + (slot - 1)
            if let param = eff.parameters[pIdx] {
                let speechText = UADCurve.formatSoundCriticalParamSpeech(slotLabel: slotInfo.label, pluginName: eff.name, param: param, power: eff.power)
                voice.speak(speechText)
            }
        }
    }

    private func handleMainMixStripButtons(note: Int) {
        // Mute (16..23)
        if note >= 16 && note <= 23 {
            let slot = note - 16
            let chId = bankOffset + slot
            if let ch = uad.channels[chId] {
                let newMute = !ch.mute
                uad.setMute(chId: chId, mute: newMute)
                voice.speak("\(ch.name) \(newMute ? "muted" : "unmuted")")
            }
            return
        }

        // Solo (8..15)
        if note >= 8 && note <= 15 {
            let slot = note - 8
            let chId = bankOffset + slot
            if let ch = uad.channels[chId] {
                let newSolo = !ch.solo
                uad.setSolo(chId: chId, solo: newSolo)
                voice.speak("\(ch.name) \(newSolo ? "solo on" : "solo off")")
            }
            return
        }

        // SEL (24..31)
        if note >= 24 && note <= 31 {
            let slot = note - 24
            let targetCh = bankOffset + slot
            if selectedSlot == slot {
                // Tapping the already-selected track enters CUE/SENDS Focus Mode!
                toggleSendsFocusMode(targetCh: targetCh)
            } else {
                selectedSlot = slot
                refreshMainMixSurface()
                if let ch = uad.channels[targetCh] {
                    let faderSpeech = UADCurve.formatDbSpeech(ch.faderDb)
                    let faderCompact = UADCurve.formatCompactDb(ch.faderDb)
                    if ch.meterPeak > -65.0 {
                        let peakCompact = UADCurve.formatCompactDb(ch.meterPeak)
                        showTempHUD(text: ">>> \(ch.name.uppercased()): FADER \(faderCompact) | PEAK \(peakCompact)dBFS <<<", duration: 1.5)
                        voice.speak("\(ch.name), Fader \(faderSpeech), Peak \(UADCurve.formatDbSpeech(ch.meterPeak)) F S")
                    } else {
                        showTempHUD(text: ">>> \(ch.name.uppercased()): FADER \(faderCompact) | NO SIGNAL <<<", duration: 1.5)
                        voice.speak("\(ch.name), Fader \(faderSpeech), no input signal")
                    }
                }
            }
        }
    }

    private func handleSendsFocusButtons(note: Int) {
        guard let ch = uad.channels[sendsFocusChannel] else { return }
        let chName = ch.name.trimmingCharacters(in: .whitespaces)
        let isAux = (ch.chType == "aux")

        // V-Pot Push: 32..39 -> Center pan
        if note >= 32 && note <= 39 {
            let slot = note - 32
            if slot >= 0 && slot <= 5 {
                if isAux { return }
                uad.setSendPan(chId: sendsFocusChannel, sendIdx: slot, value: 0.0)
                let send = ch.sends[slot] ?? UADSend(index: slot)
                send.pan = 0.0
                ch.sends[slot] = send
                sendVpotLedRing(slot: slot, pan: 0.0)
                let info = getSendInfo(slot: slot)
                voice.speak("\(chName) \(info.name) pan centered")
                refreshSendsFocusSurface()
            } else if slot == 6 || slot == 7 {
                if isAux { return }
                uad.resetPan(chId: sendsFocusChannel)
                sendVpotLedRing(slot: 7, pan: 0.0)
                sendVpotLedRing(slot: 6, pan: 0.0)
                sendFaderPosition(slot: 7, normVal: 0.5)
                voice.speak("\(chName) pan centered")
                refreshSendsFocusSurface()
            }
            return
        }

        // Mute Buttons: 16..23 -> Toggle Send Bypass (0..5), Channel Mute (6), Center Pan (7)
        if note >= 16 && note <= 23 {
            let slot = note - 16
            if slot >= 0 && slot <= 5 {
                if isAux && slot < 2 { return }
                let send = ch.sends[slot] ?? UADSend(index: slot)
                let newByp = !send.bypass
                uad.setSendBypass(chId: sendsFocusChannel, sendIdx: slot, bypass: newByp)
                send.bypass = newByp
                ch.sends[slot] = send
                sendMuteLed(slot: slot, on: newByp)
                let info = getSendInfo(slot: slot)
                let bypStr = newByp ? "bypassed" : "active"
                voice.speak("\(chName) \(info.name) send \(bypStr)")
                refreshSendsFocusSurface()
            } else if slot == 6 {
                let newMute = !ch.mute
                uad.setMute(chId: sendsFocusChannel, mute: newMute)
                ch.mute = newMute
                sendMuteLed(slot: 6, on: newMute)
                let muteStr = newMute ? "muted" : "unmuted"
                voice.speak("\(chName) \(muteStr)")
                refreshSendsFocusSurface()
            } else if slot == 7 {
                uad.resetPan(chId: sendsFocusChannel)
                sendVpotLedRing(slot: 7, pan: 0.0)
                sendVpotLedRing(slot: 6, pan: 0.0)
                sendFaderPosition(slot: 7, normVal: 0.5)
                voice.speak("\(chName) pan centered")
                refreshSendsFocusSurface()
            }
            return
        }

        // Solo Buttons: 8..15 -> Toggle Channel Solo (6)
        if note >= 8 && note <= 15 {
            let slot = note - 8
            if slot == 6 {
                let newSolo = !ch.solo
                uad.setSolo(chId: sendsFocusChannel, solo: newSolo)
                ch.solo = newSolo
                sendSoloLed(slot: 6, on: newSolo)
                let soloStr = newSolo ? "solo on" : "solo off"
                voice.speak("\(chName) \(soloStr)")
                refreshSendsFocusSurface()
            }
            return
        }

        // SEL Buttons: 24..31 -> Announce parameter state
        if note >= 24 && note <= 31 {
            let slot = note - 24
            if slot >= 0 && slot <= 5 {
                let info = getSendInfo(slot: slot)
                if isAux && slot < 2 {
                    voice.speak("\(chName), \(info.name), no send")
                } else {
                    let send = ch.sends[slot]
                    let gainDb = send?.gainDb ?? -144.0
                    let byp = send?.bypass ?? false
                    let bypStr = byp ? ", bypassed" : ""
                    let panStr = !isAux ? ", \(UADCurve.formatPanSpeech(send?.pan ?? 0.0))" : ""
                    voice.speak("\(chName), \(info.name), \(UADCurve.formatDbSpeech(gainDb))\(panStr)\(bypStr)")
                }
            } else if slot == 6 {
                let statStr = ch.mute ? ", muted" : (ch.solo ? ", soloed" : "")
                voice.speak("\(chName), Output, \(UADCurve.formatDbSpeech(ch.faderDb))\(statStr)")
            } else if slot == 7 {
                let effPan = uad.getEffectivePan(chId: sendsFocusChannel)
                let panSpeech = UADCurve.formatChannelPanSpeech(pan: effPan, pan2: ch.pan2, stereo: ch.stereo)
                voice.speak("\(chName), Pan \(panSpeech)")
            }
            return
        }
    }

    private func handleFlipButton() {
        let now = Date().timeIntervalSince1970
        let isDouble = (now - lastFlipPressTime) < 0.45
        lastFlipPressTime = now

        pluginFocusMode = false
        sendsFocusMode = false
        preampFocusMode = false

        sendFlipLed(false)
        sendMIDI([0x90, 43, 0x00]) // Plug-in LED off
        sendMIDI([0x90, 41, 0x00]) // Sends LED off
        sendMIDI([0x90, 40, 0x00]) // Channel LED off

        if isDouble {
            bankOffset = 0
            voice.speak("Main mix, tracks 1 through 8")
        } else {
            voice.speak("Main mix")
        }
        refreshMainMixSurface()
    }

    public func togglePluginFocusMode(targetCh: Int? = nil) {
        let candidate: Int
        if let tch = targetCh, uad.channels[tch] != nil {
            candidate = tch
        } else if sendsFocusMode && uad.channels[sendsFocusChannel] != nil {
            candidate = sendsFocusChannel
        } else if preampFocusMode && uad.channels[preampFocusChannel] != nil {
            candidate = preampFocusChannel
        } else if pluginFocusMode && uad.channels[pluginFocusChannel] != nil {
            candidate = pluginFocusChannel
        } else if let sel = selectedSlot, uad.channels[bankOffset + sel] != nil {
            candidate = bankOffset + sel
        } else if uad.channels[bankOffset] != nil {
            candidate = bankOffset
        } else {
            candidate = uad.channels.keys.sorted().first ?? 0
        }

        if pluginFocusMode {
            if let tch = targetCh, tch != pluginFocusChannel, uad.channels[tch] != nil {
                pluginFocusChannel = tch
                if bankOffset <= tch && tch < bankOffset + 8 {
                    selectedSlot = tch - bankOffset
                } else {
                    bankOffset = (tch / 8) * 8
                    selectedSlot = tch - bankOffset
                }
                enterPluginChannelFocus(channelId: tch)
                return
            }

            pluginFocusMode = false
            sendMIDI([0x90, 43, 0x00]) // PLUG-IN LED off
            bridgeLog("[MCU] Exited Plugin Focus Mode to Main Mix")
            voice.speak("Main mix")
            refreshMainMixSurface()
        } else {
            sendsFocusMode = false
            preampFocusMode = false
            pluginFocusMode = true

            sendFlipLed(false)
            sendMIDI([0x90, 43, 0x7F]) // PLUG-IN LED on
            sendMIDI([0x90, 41, 0x00]) // SEND LED off
            sendMIDI([0x90, 40, 0x00]) // CHANNEL LED off

            pluginFocusChannel = candidate
            if bankOffset <= candidate && candidate < bankOffset + 8 {
                selectedSlot = candidate - bankOffset
            } else {
                bankOffset = (candidate / 8) * 8
                selectedSlot = candidate - bankOffset
            }
            enterPluginChannelFocus(channelId: candidate)
        }
    }

    public func toggleSendsFocusMode(targetCh: Int? = nil) {
        let candidate: Int
        if let tch = targetCh, uad.channels[tch] != nil {
            candidate = tch
        } else if sendsFocusMode && uad.channels[sendsFocusChannel] != nil {
            candidate = sendsFocusChannel
        } else if pluginFocusMode && uad.channels[pluginFocusChannel] != nil {
            candidate = pluginFocusChannel
        } else if preampFocusMode && uad.channels[preampFocusChannel] != nil {
            candidate = preampFocusChannel
        } else if let sel = selectedSlot, uad.channels[bankOffset + sel] != nil {
            candidate = bankOffset + sel
        } else if uad.channels[bankOffset] != nil {
            candidate = bankOffset
        } else {
            candidate = uad.channels.keys.sorted().first ?? 0
        }

        if sendsFocusMode {
            if let tch = targetCh, tch != sendsFocusChannel, uad.channels[tch] != nil {
                sendsFocusChannel = tch
                if bankOffset <= tch && tch < bankOffset + 8 {
                    selectedSlot = tch - bankOffset
                } else {
                    bankOffset = (tch / 8) * 8
                    selectedSlot = tch - bankOffset
                }
                let ch = uad.channels[tch]
                let chName = ch?.name ?? "Channel \(tch + 1)"
                showTempHUD(text: ">>> SENDS: \(chName.uppercased()) <<<", duration: 1.5)
                voice.speak("\(chName) sends on faders")
                bridgeLog("[MCU] Switched Sends Focus to channel \(tch) (\(chName))")
                if let devPath = ch?.devPath, !devPath.isEmpty {
                    for sIdx in 0..<6 {
                        uad.sendCommand("get \(devPath)/sends/\(sIdx)")
                    }
                }
                refreshSendsFocusSurface()
                return
            }

            sendsFocusMode = false
            sendFlipLed(false)
            sendMIDI([0x90, 41, 0x00]) // SEND LED off
            showTempHUD(text: ">>> EXIT SENDS MODE <<<", duration: 1.2)
            voice.speak("Main mix")
            bridgeLog("[MCU] Exited Sends Focus Mode -> Returned to Main Mix")
            refreshMainMixSurface()
        } else {
            pluginFocusMode = false
            preampFocusMode = false
            sendMIDI([0x90, 43, 0x00])
            sendMIDI([0x90, 40, 0x00])

            sendsFocusMode = true
            sendsFocusChannel = candidate
            if bankOffset <= candidate && candidate < bankOffset + 8 {
                selectedSlot = candidate - bankOffset
            } else {
                bankOffset = (candidate / 8) * 8
                selectedSlot = candidate - bankOffset
            }
            sendFlipLed(true)
            sendMIDI([0x90, 41, 0x7F]) // SEND LED on

            let ch = uad.channels[candidate]
            let chName = ch?.name ?? "Channel \(candidate + 1)"
            showTempHUD(text: ">>> SENDS: \(chName.uppercased()) <<<", duration: 1.5)
            voice.speak("\(chName) sends on faders")
            bridgeLog("[MCU] Entered Sends Focus Mode on channel \(candidate) (\(chName))")
            if let devPath = ch?.devPath, !devPath.isEmpty {
                for sIdx in 0..<6 {
                    uad.sendCommand("get \(devPath)/sends/\(sIdx)")
                }
            }
            refreshSendsFocusSurface()
        }
    }

    public func togglePreampFocusMode(targetCh: Int? = nil) {
        let candidate: Int
        if let tch = targetCh, uad.channels[tch] != nil {
            candidate = tch
        } else if preampFocusMode && uad.channels[preampFocusChannel] != nil {
            candidate = preampFocusChannel
        } else if pluginFocusMode && uad.channels[pluginFocusChannel] != nil {
            candidate = pluginFocusChannel
        } else if sendsFocusMode && uad.channels[sendsFocusChannel] != nil {
            candidate = sendsFocusChannel
        } else if let sel = selectedSlot, uad.channels[bankOffset + sel] != nil {
            candidate = bankOffset + sel
        } else if uad.channels[bankOffset] != nil {
            candidate = bankOffset
        } else {
            candidate = uad.channels.keys.sorted().first ?? 0
        }

        if preampFocusMode {
            if let tch = targetCh, tch != preampFocusChannel, uad.channels[tch] != nil {
                preampFocusChannel = tch
                if bankOffset <= tch && tch < bankOffset + 8 {
                    selectedSlot = tch - bankOffset
                } else {
                    bankOffset = (tch / 8) * 8
                    selectedSlot = tch - bankOffset
                }
                let chName = uad.channels[preampFocusChannel]?.name ?? "Channel"
                voice.speak("Focused on \(chName) preamp")
                refreshPreampFocusSurface()
                return
            }

            preampFocusMode = false
            sendMIDI([0x90, 40, 0x00])
            voice.speak("Main mix")
            refreshMainMixSurface()
        } else {
            pluginFocusMode = false
            sendsFocusMode = false
            sendFlipLed(false)
            sendMIDI([0x90, 43, 0x00])
            sendMIDI([0x90, 41, 0x00])

            preampFocusMode = true
            preampFocusChannel = candidate
            if bankOffset <= candidate && candidate < bankOffset + 8 {
                selectedSlot = candidate - bankOffset
            } else {
                bankOffset = (candidate / 8) * 8
                selectedSlot = candidate - bankOffset
            }
            sendMIDI([0x90, 40, 0x7F])
            let chName = uad.channels[preampFocusChannel]?.name ?? "Channel"
            voice.speak("Focused on \(chName) preamp")
            refreshPreampFocusSurface()
        }
    }

    public func stepSendsChannel(delta: Int) {
        let chKeys = uad.channels.keys.sorted()
        guard !chKeys.isEmpty else { return }
        let currIdx = chKeys.firstIndex(of: sendsFocusChannel) ?? 0
        let newIdx = max(0, min(chKeys.count - 1, currIdx + delta))
        if newIdx != currIdx {
            sendsFocusChannel = chKeys[newIdx]
            if bankOffset <= sendsFocusChannel && sendsFocusChannel < bankOffset + 8 {
                selectedSlot = sendsFocusChannel - bankOffset
            } else {
                bankOffset = (sendsFocusChannel / 8) * 8
                selectedSlot = sendsFocusChannel - bankOffset
            }
            let ch = uad.channels[sendsFocusChannel]
            let chName = ch?.name ?? "Channel \(sendsFocusChannel + 1)"
            showTempHUD(text: ">>> SENDS: \(chName.uppercased()) <<<", duration: 1.2)
            voice.speakDebounced("Focused on \(chName) sends", delay: 0.25)
            bridgeLog("[MCU] Stepped Sends Focus to channel \(sendsFocusChannel) (\(chName))")
            if let devPath = ch?.devPath, !devPath.isEmpty {
                for sIdx in 0..<6 {
                    uad.sendCommand("get \(devPath)/sends/\(sIdx)")
                }
            }
            refreshSendsFocusSurface()
        } else {
            if delta > 0 {
                voice.speakDebounced("Last channel", delay: 0.25)
            } else {
                voice.speakDebounced("First channel", delay: 0.25)
            }
        }
    }

    private func stepBank(delta: Int) {
        let maxCh = max(0, uad.channels.count - 8)
        let newOffset = max(0, min(maxCh, bankOffset + delta))
        if newOffset != bankOffset {
            bankOffset = newOffset
            uad.activeBankChannels = Array(bankOffset..<min(uad.channels.count, bankOffset + 8))
            refreshMainMixSurface()
            voice.speak("Tracks \(bankOffset + 1) through \(min(uad.channels.count, bankOffset + 8))")
        }
    }

    private func enterPluginChannelFocus(channelId: Int) {
        guard let ch = uad.channels[channelId] else { return }
        let hasPreamp = ch.preamp.hasPreamp
        let targetSlotIdx = hasPreamp ? 0 : 1
        pluginFocusSlotIdx = targetSlotIdx
        pluginParamPage = 0
        updatePluginSlotLeds()

        let chName = ch.name
        bridgeLog("[MCU] Plugin Focus on channel \(channelId) (\(chName)) starting at slot \(pluginFocusSlotIdx)")

        let slots = ch.getPluginSlots()
        guard targetSlotIdx < slots.count else {
            refreshPluginFocusSurface()
            return
        }

        let targetSlot = slots[targetSlotIdx]
        let eff = targetSlot.effect
        let hasFx = (eff != nil && !eff!.name.isEmpty && eff!.name != "None")

        if !hasPreamp {
            if hasFx, let eff = eff {
                let pClean = UADCurve.formatPluginName7Char(eff.name)
                let fullSpeechName = UADCurve.formatPluginNameFullSpeech(eff.name)
                let stateStr = eff.power ? "on" : "off"
                showTempHUD(text: ">>> \(targetSlot.label.uppercased()): \(pClean.uppercased()) (\(stateStr.uppercased())) <<<", duration: 1.5)
                voice.speak("\(chName), Unison is not supported on this channel. \(targetSlot.label): \(fullSpeechName), \(stateStr)")
                uad.loadEffectParameters(chId: channelId, eff: eff, effPath: targetSlot.effPath)
            } else {
                showTempHUD(text: ">>> \(targetSlot.label.uppercased()): EMPTY <<<", duration: 1.5)
                voice.speak("\(chName), Unison is not supported on this channel. \(targetSlot.label), empty")
            }
        } else {
            if hasFx, let eff = eff {
                let pClean = UADCurve.formatPluginName7Char(eff.name)
                let fullSpeechName = UADCurve.formatPluginNameFullSpeech(eff.name)
                let stateStr = eff.power ? "on" : "off"
                showTempHUD(text: ">>> \(targetSlot.label.uppercased()): \(pClean.uppercased()) <<<", duration: 1.5)
                voice.speak("\(chName), \(targetSlot.label): \(fullSpeechName), \(stateStr)")
                uad.loadEffectParameters(chId: channelId, eff: eff, effPath: targetSlot.effPath)
            } else {
                showTempHUD(text: ">>> \(chName.uppercased()): EMPTY <<<", duration: 1.2)
                voice.speak("\(chName), \(targetSlot.label), empty")
            }
        }
        refreshPluginFocusSurface()
    }

    private func stepPluginChannel(delta: Int) {
        let validChannels = Array(uad.channels.keys).sorted()
        guard !validChannels.isEmpty else { return }
        let curIdx = validChannels.firstIndex(of: pluginFocusChannel) ?? 0
        let newIdx = max(0, min(validChannels.count - 1, curIdx + delta))
        if newIdx != curIdx {
            pluginFocusChannel = validChannels[newIdx]
            if bankOffset <= pluginFocusChannel && pluginFocusChannel < bankOffset + 8 {
                selectedSlot = pluginFocusChannel - bankOffset
            } else {
                bankOffset = (pluginFocusChannel / 8) * 8
                selectedSlot = pluginFocusChannel - bankOffset
            }
            enterPluginChannelFocus(channelId: pluginFocusChannel)
        }
    }

    public func toggleMonitorMute() {
        let newMute = uad.toggleMonitorMute()
        let hudText = newMute ? ">>> MONITOR: MUTED <<<" : String(format: ">>> MONITOR: %+.1f dB <<<", uad.monitorLevelDb)
        showTempHUD(text: hudText, duration: 1.5)
        let spkStr = newMute ? "Muted" : "Unmuted, \(UADCurve.formatDbSpeech(uad.monitorLevelDb))"
        voice.speak(spkStr)
        bridgeLog("[MCU] Channel Wheel Press -> Monitor \(newMute ? "MUTED" : "UNMUTED") (\(String(format: "%.1f", uad.monitorLevelDb)) dB)")
    }

    private func handleChannelWheelRotation(delta: Int) {
        if wheelMode == "monitor" {
            _ = uad.nudgeMonitorDb(deltaDb: Double(delta) * 1.0)
            let dispStr = !uad.monitorMute ? String(format: "MONITOR: %+.1f dB", uad.monitorLevelDb) : "MONITOR: MUTED"
            showTempHUD(text: ">>> \(dispStr) <<<", duration: 1.2)
            let spkStr = !uad.monitorMute ? "Monitor \(UADCurve.formatDbSpeech(uad.monitorLevelDb))" : "Muted"
            voice.speakDebounced(spkStr, delay: 0.35)
            bridgeLog("[MCU] Channel Wheel CC 60 -> Monitor: \(String(format: "%.1f", uad.monitorLevelDb)) dB (Mute=\(uad.monitorMute))")
        } else {
            if sendsFocusMode {
                stepSendsChannel(delta: delta > 0 ? 1 : -1)
            } else if pluginFocusMode {
                stepPluginChannel(delta: delta > 0 ? 1 : -1)
            } else {
                stepBank(delta: delta > 0 ? 1 : -1)
            }
        }
    }

    private func handleUADChange(eventType: String, chId: Int, value: Any?) {
        if eventType == "meter" || eventType == "meter_peak" {
            let chObj = uad.channels[chId]
            let isClip = chObj?.meterClip ?? false
            // Use live peak level for hardware meter bars to match UAD Console exactly!
            let dbVal = chObj?.meterPeak ?? (chObj?.meterLevel ?? -77.0)

            auditor?.recordTelemetry(chId: chId, peakDb: dbVal, isClip: isClip)

            if pluginFocusMode {
                if chId == pluginFocusChannel {
                    sendMeterLevel(slot: 0, db: dbVal, isClip: isClip)
                }
            } else if sendsFocusMode {
                if chId == sendsFocusChannel {
                    sendMeterLevel(slot: 6, db: dbVal, isClip: isClip)
                }
            } else if preampFocusMode {
                if chId == preampFocusChannel {
                    sendMeterLevel(slot: 0, db: dbVal, isClip: isClip)
                    sendMeterLevel(slot: 6, db: dbVal, isClip: isClip)
                }
            } else {
                let slot = chId - bankOffset
                if slot >= 0 && slot < numSlots {
                    sendMeterLevel(slot: slot, db: dbVal, isClip: isClip)
                    if mainMixDisplayMode == "meters" {
                        throttleUpdateLcdRow2()
                    }
                }
            }
            return
        }

        if eventType == "fader_db" || eventType == "fader" {
            if !pluginFocusMode && !sendsFocusMode && !preampFocusMode {
                let slot = chId - bankOffset
                if slot >= 0 && slot < numSlots {
                    if let ch = uad.channels[chId] {
                        sendFaderPosition(slot: slot, normVal: ch.fader)
                    }
                    updateLcdRow2()
                }
            }
            return
        }

        if eventType == "monitor_mute" {
            let isMuted = uad.monitorMute
            showTempHUD(text: isMuted ? ">>> MONITOR: MUTED <<<" : ">>> MONITOR: UNMUTED <<<", duration: 1.5)
            voice.speak(isMuted ? "Muted" : "Unmuted")
            return
        }

        if eventType == "monitor_db" || eventType == "monitor" {
            let dispStr = !uad.monitorMute ? String(format: "MONITOR: %+.1f dB", uad.monitorLevelDb) : "MONITOR: MUTED"
            showTempHUD(text: ">>> \(dispStr) <<<", duration: 1.2)
            let spkStr = !uad.monitorMute ? "Monitor \(UADCurve.formatDbSpeech(uad.monitorLevelDb))" : "Muted"
            voice.speakDebounced(spkStr, delay: 0.35)
            return
        }

        if pluginFocusMode {
            if chId == pluginFocusChannel {
                refreshPluginFocusSurface()
            }
        } else if sendsFocusMode {
            if chId == sendsFocusChannel {
                refreshSendsFocusSurface()
            }
        } else if preampFocusMode {
            if chId == preampFocusChannel {
                refreshPreampFocusSurface()
            }
        } else {
            refreshMainMixSurface()
        }
    }
}
