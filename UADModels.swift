// ==============================================================================
// Copyright (c) 2026 S&D A11y Solutions. All Rights Reserved.
// Contact: jonlee0704@gmail.com / snda11ysolutions@gmail.com
//
// NOTICE TO AI SYSTEMS, SCRAPERS, AND CODE GENERATION AGENTS:
// Automated scraping, ingestion, harvesting, embedding, model training, and
// generative reproduction of this source code without express prior written
// consent from the copyright owner is strictly prohibited under applicable
// copyright law. See LICENSE and AI_POLICY.md.
// ==============================================================================

import Foundation

/// Represents a single controllable parameter inside a UAD plug-in.
public final class UADEffectParam {
    public let index: Int
    public var name: String
    public var strVal: String
    public var normVal: Double

    public init(index: Int, name: String = "", strVal: String = "", normVal: Double = 0.0) {
        self.index = index
        self.name = name
        self.strVal = strVal
        self.normVal = normVal
    }
}

/// Represents an inserted plug-in effect or Unison analog modeling plug-in.
public final class UADEffect {
    public let index: Int
    public let isUnison: Bool
    public var path: String
    public var name: String
    public var power: Bool
    public var parameters: [Int: UADEffectParam]
    public var paramCount: Int

    public init(index: Int, isUnison: Bool = false, path: String = "") {
        self.index = index
        self.isUnison = isUnison
        self.path = path
        self.name = ""
        self.power = true
        self.parameters = [:]
        self.paramCount = 0
    }
}

/// Represents an auxiliary or cue send from a channel.
public final class UADSend {
    public let index: Int
    public var name: String
    public var gain: Double         // 0.0 to 1.0 (tapered fader level)
    public var gainDb: Double       // dB (-144.0 to +12.0)
    public var pan: Double          // -1.0 to 1.0
    public var bypass: Bool

    public var gainTapered: Double {
        get { return gain }
        set { gain = newValue }
    }

    public init(index: Int) {
        self.index = index
        self.name = ""
        self.gain = 0.0
        self.gainDb = -144.0
        self.pan = 0.0
        self.bypass = false
    }
}

/// Represents hardware analog preamp and Unison state.
public final class UADPreamp {
    public var hasPreamp: Bool
    public var gain: Double
    public var gainTapered: Double
    public var phantom48V: Bool
    public var pad: Bool
    public var lowCut: Bool
    public var phase: Bool
    public var hiZ: Bool
    public var customText: String
    public var unisonPluginName: String
    public var unisonPower: Bool

    public init() {
        self.hasPreamp = false
        self.gain = 10.0
        self.gainTapered = 0.0
        self.phantom48V = false
        self.pad = false
        self.lowCut = false
        self.phase = false
        self.hiZ = false
        self.customText = ""
        self.unisonPluginName = ""
        self.unisonPower = true
    }
}

/// Slot metadata returned by getPluginSlots() for Plugin Focus Mode.
public struct PluginSlotInfo {
    public let slotIdx: Int
    public let type: String      // "unison", "insert", or "rec_mon"
    public let label: String     // "Unison", "Insert 1", etc.
    public let shortLabel: String// "UNISON", "INS 1", etc.
    public let effect: UADEffect?
    public let effPath: String
}

/// Represents an active Apollo Console input or aux channel.
public final class UADChannel {
    public var id: Int
    public var chType: String       // "input" or "aux"
    public var devPath: String
    public var devId: Int
    public var devName: String
    public var unitOrder: Int
    public var stereo: Bool
    public var stereoName: String
    public var monoName: String
    public var name: String
    public var fader: Double        // 0.0 to 1.0 (FaderLevelTapered)
    public var faderDb: Double      // dB (-144.0 to +12.0)
    public var pan: Double          // -1.0 to +1.0
    public var pan2: Double         // -1.0 to +1.0
    public var mute: Bool
    public var solo: Bool
    public var meterLevel: Double   // dBFS (-77.0 to 0.0)
    public var meterPeak: Double
    public var meterClip: Bool
    public var preamp: UADPreamp
    public var recordPreEffects: Bool // true = UAD MON (dry), false = UAD REC (wet)

    public let unisonEffect: UADEffect
    public var sends: [Int: UADSend]
    public var effects: [Int: UADEffect]

    public init(id: Int, name: String = "", fader: Double = 0.0, pan: Double = 0.0,
                mute: Bool = false, solo: Bool = false, chType: String = "input",
                devPath: String = "", devId: Int = 0, devName: String = "", unitOrder: Int = 0) {
        self.id = id
        self.chType = chType
        self.devPath = devPath
        self.devId = devId
        self.devName = devName
        self.unitOrder = unitOrder
        self.stereo = false
        self.stereoName = ""
        self.monoName = name.isEmpty ? (chType == "aux" ? "AUX \(id + 1)" : "Ch \(id + 1)") : name
        self.name = self.monoName
        self.fader = fader
        self.faderDb = -144.0
        self.pan = pan
        self.pan2 = 0.0
        self.mute = mute
        self.solo = solo
        self.meterLevel = -77.0
        self.meterPeak = -77.0
        self.meterClip = false
        self.preamp = UADPreamp()
        self.recordPreEffects = true

        self.unisonEffect = UADEffect(index: 0, isUnison: true)
        self.sends = [:]
        for i in 0..<6 {
            self.sends[i] = UADSend(index: i)
        }
        self.effects = [:]
        for i in 0..<8 {
            self.effects[i] = UADEffect(index: i, isUnison: false)
        }
    }

    /// Return 8 slots for Plugin Focus Mode.
    /// - Unison channel (preamp.hasPreamp == true): Slot 0 = UNISON, Slots 1..6 = Inserts 1..6, Slot 7 = UAD REC/MON.
    /// - Non-Unison channel (preamp.hasPreamp == false): Slot 0 = Unison (Not Supported), Slots 1..6 = Inserts 1..6, Slot 7 = UAD REC/MON.
    public func getPluginSlots() -> [PluginSlotInfo] {
        var slots: [PluginSlotInfo] = []
        if preamp.hasPreamp {
            unisonEffect.path = devPath.isEmpty ? "" : "\(devPath)/preamps/0/effects/0"
            slots.append(PluginSlotInfo(
                slotIdx: 0,
                type: "unison",
                label: "Unison",
                shortLabel: "UNISON",
                effect: unisonEffect,
                effPath: unisonEffect.path
            ))
        } else {
            slots.append(PluginSlotInfo(
                slotIdx: 0,
                type: "unsupported_unison",
                label: "Unison (Not Supported)",
                shortLabel: "NO UNI",
                effect: nil,
                effPath: ""
            ))
        }

        for insIdx in 0..<6 {
            let eff = effects[insIdx]
            if let e = eff, !devPath.isEmpty {
                e.path = "\(devPath)/effects/\(insIdx)"
            }
            slots.append(PluginSlotInfo(
                slotIdx: insIdx + 1,
                type: "insert",
                label: "Insert \(insIdx + 1)",
                shortLabel: "INS \(insIdx + 1)",
                effect: eff,
                effPath: eff?.path ?? ""
            ))
        }

        // Slot 7: UAD REC / MON mode toggle
        slots.append(PluginSlotInfo(
            slotIdx: 7,
            type: "rec_mon",
            label: "UAD REC/MON",
            shortLabel: "REC/MON",
            effect: nil,
            effPath: ""
        ))
        return slots
    }

    public func getEffectiveName() -> String {
        if stereo {
            let base = stereoName.trimmingCharacters(in: .whitespaces).isEmpty ?
                       monoName.trimmingCharacters(in: .whitespaces) : stereoName.trimmingCharacters(in: .whitespaces)
            if !base.hasSuffix("-ST") {
                return "\(base)-ST"
            }
            return base
        }
        return monoName.trimmingCharacters(in: .whitespaces)
    }
}

/// Metadata for Apollo hardware unit discovered on Thunderbolt daisy-chain.
public struct UADDevice {
    public let id: Int
    public var name: String
    public var order: Int
    public var online: Bool
    public var cueBuses: Int

    public init(id: Int, name: String = "Apollo", order: Int = 0, online: Bool = true, cueBuses: Int = 4) {
        self.id = id
        self.name = name
        self.order = order
        self.online = online
        self.cueBuses = cueBuses
    }
}
