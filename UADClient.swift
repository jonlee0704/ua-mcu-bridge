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
import Network

/// Native TCP client for the UA Mixer Engine (127.0.0.1:4710) using Network.framework.
public final class UADClient {
    public let host: String
    public let port: UInt16

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.echonav.uamcubridge.uad", qos: .userInteractive)
    private var rxBuffer = Data()
    private var funcId: Int = 1000
    private let lock = NSLock()

    public private(set) var isConnected: Bool = false
    public var channels: [Int: UADChannel] = [:]
    public var pathToChannel: [String: UADChannel] = [:]
    public var devices: [Int: UADDevice] = [:]

    // Raw discovery caches
    private var rawInputs: [String: [String: Any]] = [:]
    private var rawAuxs: [String: [String: Any]] = [:]
    private var subscribedPaths: Set<String> = []
    private var channelRebuildTimer: DispatchSourceTimer?

    // Master Monitor Output
    public var monitorDeviceId: Int = 0
    public var monitorOutputId: Int = 20
    public var monitorPaths: [(devId: Int, outId: Int)] = [(0, 20), (1, 4)]
    public var monitorLevelTapered: Double = 0.208
    public var monitorLevelDb: Double = -37.0
    public var monitorMute: Bool = false

    // Master Monitor Meters
    public var monitorMeterLevelL: Double = -77.0
    public var monitorMeterLevelR: Double = -77.0
    public var monitorMeterPeakL: Double = -77.0
    public var monitorMeterPeakR: Double = -77.0
    public var monitorMeterClip: Bool = false

    // Active Bank for Metering
    public var activeBankChannels: [Int] = Array(0..<8)
    private var meterTimer: DispatchSourceTimer?

    // Callbacks: (eventType, chId, value)
    public var onChannelChange: ((String, Int, Any?) -> Void)?

    public init(host: String = "127.0.0.1", port: UInt16 = 4710) {
        self.host = host
        self.port = port
    }

    deinit {
        disconnect()
    }

    private func nextFuncId() -> Int {
        lock.lock()
        defer { lock.unlock() }
        funcId += 1
        return funcId
    }

    // MARK: - Connection Management

    public func connect(completion: ((Bool) -> Void)? = nil) {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        let params = NWParameters.tcp
        let conn = NWConnection(to: endpoint, using: params)

        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                bridgeLog("[UAD] Connected to UA Mixer Engine at \(self.host):\(self.port)")
                self.isConnected = true
                self.receiveNextChunk()
                self.discoverDevices()
                completion?(true)
            case .failed(let err):
                bridgeLog("[UAD] Connection failed: \(err)")
                self.isConnected = false
                completion?(false)
            case .cancelled:
                self.isConnected = false
            default:
                break
            }
        }

        self.connection = conn
        conn.start(queue: queue)
    }

    public func disconnect() {
        meterTimer?.cancel()
        meterTimer = nil
        channelRebuildTimer?.cancel()
        channelRebuildTimer = nil
        connection?.cancel()
        connection = nil
        isConnected = false
    }

    // MARK: - Inbound Frame Processing

    private func receiveNextChunk() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }
            if let data = content, !data.isEmpty {
                self.rxBuffer.append(data)
                self.extractAndHandleFrames()
            }
            if isComplete || error != nil {
                bridgeLog("[UAD] Connection closed by UA Mixer Engine")
                self.isConnected = false
                return
            }
            if self.isConnected {
                self.receiveNextChunk()
            }
        }
    }

    private func extractAndHandleFrames() {
        while let nullRange = rxBuffer.range(of: Data([0x00])) {
            let frameData = rxBuffer.subdata(in: 0..<nullRange.lowerBound)
            rxBuffer.removeSubrange(0..<nullRange.upperBound)
            if !frameData.isEmpty {
                handleFrameData(frameData)
            }
        }
    }

    private func handleFrameData(_ data: Data) {
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let path = json["path"] as? String else { return }
            let frameData = json["data"]
            processMessage(path: path, data: frameData)
        } catch {
            // Ignore malformed packets without aborting
        }
    }

    // MARK: - Outbound Commands

    public func sendCommand(_ cmd: String) {
        guard isConnected, let conn = connection else { return }
        var payload = cmd.data(using: .utf8) ?? Data()
        payload.append(0x00) // Null byte delimiter

        conn.send(content: payload, completion: .contentProcessed({ err in
            if let err = err {
                NSLog("[UAD] Send error: \(err)")
            }
        }))
    }

    // MARK: - Real-Time 30 FPS Meter Polling

    public func startMeterPolling() {
        meterTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // 30 Hz -> 33 ms interval
        timer.schedule(deadline: .now() + 0.05, repeating: .milliseconds(33))
        timer.setEventHandler { [weak self] in
            self?.pollActiveMeters()
        }
        meterTimer = timer
        timer.resume()
    }

    public func stopMeterPolling() {
        meterTimer?.cancel()
        meterTimer = nil
    }

    private func pollActiveMeters() {
        guard isConnected, let conn = connection else { return }

        var cmds: [String] = []

        // 1. Poll active bank channels (inputs, virtual tracks, auxs)
        let active = activeBankChannels
        for chId in active {
            if let ch = channels[chId] {
                cmds.append("get \(ch.devPath)/meters/0")
                if ch.stereo {
                    cmds.append("get \(ch.devPath)/meters/1")
                }
            }
        }

        // 2. Poll Master Monitor Output meters
        for p in monitorPaths {
            cmds.append("get /devices/\(p.devId)/outputs/\(p.outId)/meters/0")
            cmds.append("get /devices/\(p.devId)/outputs/\(p.outId)/meters/1")
        }

        guard !cmds.isEmpty else { return }

        var payload = Data()
        for cmd in cmds {
            if let d = cmd.data(using: .utf8) {
                payload.append(d)
                payload.append(0x00) // Null byte delimiter
            }
        }

        conn.send(content: payload, completion: .contentProcessed({ _ in }))
    }

    // MARK: - Protocol Message Parsing

    private func toDouble(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }

    private func processMessage(path: String, data: Any?) {
        if path == "/devices" {
            if let dict = data as? [String: Any], let children = dict["children"] as? [String: Any] {
                for key in children.keys {
                    if let devId = Int(key) {
                        sendCommand("get /devices/\(devId)")
                        sendCommand("get /devices/\(devId)/inputs")
                        sendCommand("get /devices/\(devId)/auxs")
                        sendCommand("get /devices/\(devId)/outputs")
                        sendCommand("subscribe /devices/\(devId)/DeviceOnline/value")
                    }
                }
            }
            return
        }

        let parts = path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).components(separatedBy: "/")

        // /devices/{id}
        if parts.count == 2, parts[0] == "devices", let devId = Int(parts[1]), let dict = data as? [String: Any] {
            let props = dict["properties"] as? [String: Any] ?? [:]
            let name = (props["DeviceName"] as? [String: Any])?["value"] as? String ?? "Apollo \(devId)"
            let order = (props["MultiUnitOrder"] as? [String: Any])?["value"] as? Int ?? devId
            let online = (props["DeviceOnline"] as? [String: Any])?["value"] as? Bool ?? true
            let cues = (props["CueBusCount"] as? [String: Any])?["value"] as? Int ?? 4
            devices[devId] = UADDevice(id: devId, name: name, order: order, online: online, cueBuses: cues)
            return
        }

        // /devices/{id}/inputs
        if parts.count == 3, parts[0] == "devices", let devId = Int(parts[1]), parts[2] == "inputs",
           let dict = data as? [String: Any], let children = dict["children"] as? [String: Any] {
            for key in children.keys {
                if let inpId = Int(key) {
                    sendCommand("get /devices/\(devId)/inputs/\(inpId)")
                }
            }
            return
        }

        // /devices/{id}/auxs
        if parts.count == 3, parts[0] == "devices", let devId = Int(parts[1]), parts[2] == "auxs",
           let dict = data as? [String: Any], let children = dict["children"] as? [String: Any] {
            for key in children.keys {
                if let auxId = Int(key) {
                    sendCommand("get /devices/\(devId)/auxs/\(auxId)")
                }
            }
            return
        }

        // /devices/{id}/outputs
        if parts.count == 3, parts[0] == "devices", let devId = Int(parts[1]), parts[2] == "outputs",
           let dict = data as? [String: Any], let children = dict["children"] as? [String: Any] {
            for key in children.keys {
                if let outId = Int(key) {
                    sendCommand("get /devices/\(devId)/outputs/\(outId)")
                }
            }
            return
        }

        // Full Input: /devices/{id}/inputs/{id}
        if parts.count == 4, parts[0] == "devices", parts[2] == "inputs", let dict = data as? [String: Any] {
            rawInputs["\(parts[1])_\(parts[3])"] = dict
            scheduleChannelRebuild()
            return
        }

        // Full Aux: /devices/{id}/auxs/{id}
        if parts.count == 4, parts[0] == "devices", parts[2] == "auxs", let dict = data as? [String: Any] {
            rawAuxs["\(parts[1])_\(parts[3])"] = dict
            scheduleChannelRebuild()
            return
        }

        // Master Monitor Outputs: /devices/{id}/outputs/{out_id}
        if parts.count >= 4, parts[0] == "devices", parts[2] == "outputs" {
            let outId = Int(parts[3]) ?? 20
            let devId = Int(parts[1]) ?? 0
            if parts.count == 4, let dict = data as? [String: Any] {
                let props = dict["properties"] as? [String: Any] ?? [:]
                if props["CRMonitorLevel"] != nil {
                    if !monitorPaths.contains(where: { $0.devId == devId && $0.outId == outId }) {
                        monitorPaths.append((devId: devId, outId: outId))
                    }
                    monitorDeviceId = devId
                    monitorOutputId = outId
                    if let m = (props["Mute"] as? [String: Any])?["value"] as? Bool {
                        monitorMute = m
                    }
                    if let ml = toDouble((props["CRMonitorLevel"] as? [String: Any])?["value"]) {
                        monitorLevelDb = ml
                    }
                    if let mlt = toDouble((props["CRMonitorLevelTapered"] as? [String: Any])?["value"]) {
                        monitorLevelTapered = mlt
                    }
                    sendCommand("subscribe /devices/\(devId)/outputs/\(outId)/CRMonitorLevelTapered/value")
                    sendCommand("subscribe /devices/\(devId)/outputs/\(outId)/CRMonitorLevel/value")
                    sendCommand("subscribe /devices/\(devId)/outputs/\(outId)/Mute/value")
                    bridgeLog("[UAD] Registered Master Monitor Output /devices/\(devId)/outputs/\(outId) (level=\(monitorLevelDb)dB, mute=\(monitorMute))")
                }
            } else if parts.count == 6, parts[5] == "value" {
                let prop = parts[4]
                if prop == "CRMonitorLevelTapered", let val = toDouble(data) {
                    monitorLevelTapered = val
                    monitorLevelDb = UADCurve.taperedToDb(val)
                    onChannelChange?("monitor", -1, val)
                } else if prop == "CRMonitorLevel", let val = toDouble(data) {
                    monitorLevelDb = val
                    monitorLevelTapered = UADCurve.dbToTapered(val)
                    onChannelChange?("monitor_db", -1, val)
                } else if prop == "Mute", let val = data as? Bool {
                    monitorMute = val
                    onChannelChange?("monitor_mute", -1, val)
                }
            }
            return
        }

        // Subscribed meter property updates: /devices/{d}/{inputs|auxs}/{i}/meters/{m}/{prop}/value
        if parts.count == 8, parts[0] == "devices", (parts[2] == "inputs" || parts[2] == "auxs"), parts[4] == "meters", parts[7] == "value" {
            let base = "/devices/\(parts[1])/\(parts[2])/\(parts[3])"
            guard let ch = pathToChannel[base] else { return }
            let prop = parts[6]
            if prop == "MeterPeakLevel", let val = toDouble(data) {
                if ch.stereo {
                    let meterIdx = Int(parts[5]) ?? 0
                    if meterIdx == 0 {
                        ch.meterPeak = val
                    } else {
                        ch.meterPeak = max(ch.meterPeak, val)
                    }
                } else {
                    ch.meterPeak = val
                }
                onChannelChange?("meter_peak", ch.id, ch.meterPeak)
            } else if prop == "MeterLevel", let val = toDouble(data) {
                if ch.stereo {
                    let meterIdx = Int(parts[5]) ?? 0
                    if meterIdx == 0 {
                        ch.meterLevel = val
                    } else {
                        ch.meterLevel = max(ch.meterLevel, val)
                    }
                } else {
                    ch.meterLevel = val
                }
                onChannelChange?("meter", ch.id, ch.meterLevel)
            } else if prop == "MeterClip", let val = data as? Bool {
                ch.meterClip = val
                onChannelChange?("meter_clip", ch.id, val)
            }
            return
        }

        // Channel meter updates: /devices/{d}/{inputs|auxs}/{i}/meters/{m}
        if parts.count == 6, parts[0] == "devices", (parts[2] == "inputs" || parts[2] == "auxs"), parts[4] == "meters" {
            let base = "/devices/\(parts[1])/\(parts[2])/\(parts[3])"
            guard let ch = pathToChannel[base] else { return }
            if let dict = data as? [String: Any], let props = dict["properties"] as? [String: Any] {
                if let lvl = toDouble((props["MeterLevel"] as? [String: Any])?["value"]) {
                    ch.meterLevel = lvl
                }
                if let peak = toDouble((props["MeterPeakLevel"] as? [String: Any])?["value"]) {
                    ch.meterPeak = peak
                }
                if let clip = (props["MeterClip"] as? [String: Any])?["value"] as? Bool {
                    ch.meterClip = clip
                }
                onChannelChange?("meter_peak", ch.id, ch.meterPeak)
                onChannelChange?("meter", ch.id, ch.meterLevel)
            }
            return
        }

        // Master Output meters: /devices/{d}/outputs/{outId}/meters/{m}
        if parts.count == 6, parts[0] == "devices", parts[2] == "outputs", parts[4] == "meters" {
            let meterIdx = Int(parts[5]) ?? 0
            if let dict = data as? [String: Any], let props = dict["properties"] as? [String: Any] {
                if let lvl = toDouble((props["MeterLevel"] as? [String: Any])?["value"]) {
                    if meterIdx == 0 { monitorMeterLevelL = lvl } else { monitorMeterLevelR = lvl }
                }
                if let peak = toDouble((props["MeterPeakLevel"] as? [String: Any])?["value"]) {
                    if meterIdx == 0 { monitorMeterPeakL = peak } else { monitorMeterPeakR = peak }
                }
                if let clip = (props["MeterClip"] as? [String: Any])?["value"] as? Bool {
                    monitorMeterClip = clip
                }
                let peakMax = max(monitorMeterPeakL, monitorMeterPeakR)
                let lvlMax = max(monitorMeterLevelL, monitorMeterLevelR)
                onChannelChange?("monitor_meter_peak", -1, peakMax)
                onChannelChange?("monitor_meter", -1, lvlMax)
            }
            return
        }

        // Property updates on channel: /devices/{d}/{inputs|auxs}/{i}/{prop}/value
        if parts.count == 6, parts[0] == "devices", parts[5] == "value" {
            let base = "/devices/\(parts[1])/\(parts[2])/\(parts[3])"
            guard let ch = pathToChannel[base] else { return }
            let prop = parts[4]

            if prop == "FaderLevelTapered", let val = toDouble(data) {
                ch.fader = val
                ch.faderDb = UADCurve.taperedToDb(val)
                onChannelChange?("fader", ch.id, val)
            } else if prop == "FaderLevel", let val = toDouble(data) {
                ch.faderDb = val
                if ch.fader == 0.0 && val > -140.0 {
                    ch.fader = UADCurve.dbToTapered(val)
                }
                onChannelChange?("fader_db", ch.id, val)
            } else if prop == "Pan", let val = toDouble(data) {
                ch.pan = val
                onChannelChange?("pan", ch.id, val)
            } else if prop == "Pan2", let val = toDouble(data) {
                ch.pan2 = val
                onChannelChange?("pan", ch.id, val)
            } else if prop == "Mute", let val = data as? Bool {
                ch.mute = val
                onChannelChange?("mute", ch.id, val)
            } else if prop == "Solo", let val = data as? Bool {
                ch.solo = val
                onChannelChange?("solo", ch.id, val)
            } else if prop == "Name", let val = data as? String {
                ch.monoName = val
                ch.name = ch.getEffectiveName()
                onChannelChange?("name", ch.id, ch.name)
            } else if prop == "StereoName", let val = data as? String {
                ch.stereoName = val
                ch.name = ch.getEffectiveName()
                onChannelChange?("name", ch.id, ch.name)
            } else if prop == "Stereo", let val = data as? Bool {
                ch.stereo = val
                ch.name = ch.getEffectiveName()
                scheduleChannelRebuild()
            } else if prop == "RecordPreEffects", let val = data as? Bool {
                ch.recordPreEffects = val
                onChannelChange?("record_pre_effects", ch.id, val)
            }
            return
        }

        // Send full properties: /devices/{d}/{inputs|auxs}/{i}/sends/{s}
        if parts.count == 6, parts[0] == "devices", (parts[2] == "inputs" || parts[2] == "auxs"), parts[4] == "sends", let rawSIdx = Int(parts[5]) {
            let base = "/devices/\(parts[1])/\(parts[2])/\(parts[3])"
            guard let ch = pathToChannel[base] else { return }
            let sIdx = (ch.chType == "aux") ? (rawSIdx + 2) : rawSIdx
            let send = ch.sends[sIdx] ?? UADSend(index: sIdx)
            if let dict = data as? [String: Any] {
                let props = dict["properties"] as? [String: Any] ?? [:]
                if let name = (props["Name"] as? [String: Any])?["value"] as? String {
                    send.name = name
                }
                if let gt = toDouble((props["GainTapered"] as? [String: Any])?["value"]) {
                    send.gain = gt
                    send.gainDb = UADCurve.taperedToDb(gt)
                }
                if let g = toDouble((props["Gain"] as? [String: Any])?["value"]) {
                    send.gainDb = g
                }
                if let p = toDouble((props["Pan"] as? [String: Any])?["value"]) {
                    send.pan = p
                }
                if let b = (props["Bypass"] as? [String: Any])?["value"] as? Bool {
                    send.bypass = b
                }
                ch.sends[sIdx] = send
                onChannelChange?("send_gain", ch.id, (sIdx, send.gain, send.gainDb))
                onChannelChange?("send_pan", ch.id, (sIdx, send.pan))
                onChannelChange?("send_bypass", ch.id, (sIdx, send.bypass))
            }
            return
        }

        // Send property updates: /devices/{d}/{inputs|auxs}/{i}/sends/{s}/{prop}/value
        if parts.count == 8, parts[0] == "devices", (parts[2] == "inputs" || parts[2] == "auxs"), parts[4] == "sends", parts[7] == "value", let rawSIdx = Int(parts[5]) {
            let base = "/devices/\(parts[1])/\(parts[2])/\(parts[3])"
            guard let ch = pathToChannel[base] else { return }
            let sIdx = (ch.chType == "aux") ? (rawSIdx + 2) : rawSIdx
            let prop = parts[6]
            let send = ch.sends[sIdx] ?? UADSend(index: sIdx)

            if prop == "GainTapered", let val = toDouble(data) {
                send.gain = val
                send.gainDb = UADCurve.taperedToDb(val)
                ch.sends[sIdx] = send
                onChannelChange?("send_gain", ch.id, (sIdx, send.gain, send.gainDb))
            } else if prop == "Gain", let val = toDouble(data) {
                send.gainDb = val
                ch.sends[sIdx] = send
                onChannelChange?("send_gain", ch.id, (sIdx, send.gain, send.gainDb))
            } else if prop == "Pan", let val = toDouble(data) {
                send.pan = val
                ch.sends[sIdx] = send
                onChannelChange?("send_pan", ch.id, (sIdx, send.pan))
            } else if prop == "Bypass", let val = data as? Bool {
                send.bypass = val
                ch.sends[sIdx] = send
                onChannelChange?("send_bypass", ch.id, (sIdx, send.bypass))
            }
            return
        }

        // Insert Effect full properties: /devices/{d}/{inputs|auxs}/{i}/effects/{eff_idx}
        if parts.count == 6, parts[0] == "devices", (parts[2] == "inputs" || parts[2] == "auxs"), parts[4] == "effects" {
            let base = "/devices/\(parts[1])/\(parts[2])/\(parts[3])"
            guard let ch = pathToChannel[base] else { return }
            let effIdx = Int(parts[5]) ?? 0
            if ch.effects[effIdx] == nil {
                ch.effects[effIdx] = UADEffect(index: effIdx)
            }
            let eff = ch.effects[effIdx]!
            eff.path = "\(base)/effects/\(effIdx)"
            if let dict = data as? [String: Any] {
                let props = dict["properties"] as? [String: Any] ?? dict
                if let nameObj = props["EffectName"] as? [String: Any], let name = nameObj["value"] as? String {
                    eff.name = name
                } else if let name = props["EffectName"] as? String {
                    eff.name = name
                }
                if let powObj = props["Power"] as? [String: Any], let pow = powObj["value"] as? Bool {
                    eff.power = pow
                } else if let pow = props["Power"] as? Bool {
                    eff.power = pow
                }
                onChannelChange?("effect_prop", ch.id, (effIdx, "EffectName", eff.name))
                onChannelChange?("effect_prop", ch.id, (effIdx, "Power", eff.power))
            }
            return
        }

        // Preamp full properties: /devices/{d}/inputs/{i}/preamps/0
        if parts.count == 6, parts[0] == "devices", parts[2] == "inputs", parts[4] == "preamps", parts[5] == "0" {
            let base = "/devices/\(parts[1])/\(parts[2])/\(parts[3])"
            guard let ch = pathToChannel[base] else { return }
            ch.preamp.hasPreamp = true
            if let dict = data as? [String: Any] {
                let props = dict["properties"] as? [String: Any] ?? [:]
                if let g = toDouble((props["Gain"] as? [String: Any])?["value"]) { ch.preamp.gain = g }
                if let gt = toDouble((props["GainTapered"] as? [String: Any])?["value"]) { ch.preamp.gainTapered = gt }
                if let p48 = (props["48V"] as? [String: Any])?["value"] as? Bool { ch.preamp.phantom48V = p48 }
                if let pad = (props["Pad"] as? [String: Any])?["value"] as? Bool { ch.preamp.pad = pad }
                if let lc = (props["LowCut"] as? [String: Any])?["value"] as? Bool { ch.preamp.lowCut = lc }
                if let ph = (props["Phase"] as? [String: Any])?["value"] as? Bool { ch.preamp.phase = ph }
                if let hz = (props["HiZ"] as? [String: Any])?["value"] as? Bool { ch.preamp.hiZ = hz }
                if let ct = (props["PreampGainCustomDisplayText"] as? [String: Any])?["value"] as? String { ch.preamp.customText = ct }
                onChannelChange?("preamp", ch.id, ch.preamp)
            }
            return
        }

        // Preamp property updates: /devices/{d}/inputs/{i}/preamps/0/{prop}/value
        if parts.count == 8, parts[0] == "devices", parts[2] == "inputs", parts[4] == "preamps", parts[5] == "0", parts[7] == "value" {
            let base = "/devices/\(parts[1])/\(parts[2])/\(parts[3])"
            guard let ch = pathToChannel[base] else { return }
            ch.preamp.hasPreamp = true
            let prop = parts[6]
            if prop == "Gain", let val = toDouble(data) { ch.preamp.gain = val }
            else if prop == "GainTapered", let val = toDouble(data) { ch.preamp.gainTapered = val }
            else if prop == "48V", let val = data as? Bool { ch.preamp.phantom48V = val }
            else if prop == "Pad", let val = data as? Bool { ch.preamp.pad = val }
            else if prop == "LowCut", let val = data as? Bool { ch.preamp.lowCut = val }
            else if prop == "Phase", let val = data as? Bool { ch.preamp.phase = val }
            else if prop == "HiZ", let val = data as? Bool { ch.preamp.hiZ = val }
            else if prop == "PreampGainCustomDisplayText", let val = data as? String { ch.preamp.customText = val }
            onChannelChange?("preamp", ch.id, ch.preamp)
            return
        }

        // Unison Effect full properties: /devices/{d}/inputs/{i}/preamps/0/effects/0
        if parts.count == 8, parts[0] == "devices", parts[2] == "inputs", parts[4] == "preamps", parts[5] == "0", parts[6] == "effects", parts[7] == "0" {
            let base = "/devices/\(parts[1])/\(parts[2])/\(parts[3])"
            guard let ch = pathToChannel[base] else { return }
            ch.unisonEffect.path = "\(base)/preamps/0/effects/0"
            if let dict = data as? [String: Any] {
                let props = dict["properties"] as? [String: Any] ?? [:]
                if let name = (props["EffectName"] as? [String: Any])?["value"] as? String {
                    ch.unisonEffect.name = name
                    ch.preamp.unisonPluginName = name
                }
                if let pow = (props["Power"] as? [String: Any])?["value"] as? Bool {
                    ch.unisonEffect.power = pow
                    ch.preamp.unisonPower = pow
                }
                onChannelChange?("unison", ch.id, (ch.unisonEffect.name, ch.unisonEffect.power))
            }
            return
        }

        // Plug-in & Unison properties and parameters
        handleEffectAndParameterMessage(parts: parts, data: data)
    }

    private func handleEffectAndParameterMessage(parts: [String], data: Any?) {
        guard parts.count >= 7, parts[0] == "devices" else { return }

        // Unison parameters: /devices/{d}/inputs/{i}/preamps/0/effects/0/parameters/{p}...
        let isUnisonParam = (parts.count >= 9 && parts[2] == "inputs" && parts[4] == "preamps" && parts[5] == "0" && parts[6] == "effects" && parts[7] == "0" && parts[8] == "parameters")
        // Insert parameters: /devices/{d}/{inputs|auxs}/{i}/effects/{eff_idx}/parameters/{p}...
        let isInsertParam = (parts.count >= 7 && (parts[2] == "inputs" || parts[2] == "auxs") && parts[4] == "effects" && parts[6] == "parameters")

        if isUnisonParam || isInsertParam {
            let base = "/devices/\(parts[1])/\(parts[2])/\(parts[3])"
            guard let ch = pathToChannel[base] else { return }
            let eff: UADEffect
            let paramParts: [String]

            if isUnisonParam {
                eff = ch.unisonEffect
                paramParts = Array(parts[9...])
            } else {
                let effIdx = Int(parts[5]) ?? 0
                if ch.effects[effIdx] == nil {
                    ch.effects[effIdx] = UADEffect(index: effIdx)
                }
                eff = ch.effects[effIdx]!
                paramParts = Array(parts[7...])
            }

            if paramParts.count == 0 {
                // Container children
                if let dict = data as? [String: Any], let children = dict["children"] as? [String: Any] {
                    eff.paramCount = children.count
                    for k in children.keys {
                        if let pNum = Int(k), pNum >= 32 {
                            sendCommand("\(eff.path)/parameters/\(pNum)")
                            sendCommand("subscribe \(eff.path)/parameters/\(pNum)/NormalizedValue/value")
                            sendCommand("subscribe \(eff.path)/parameters/\(pNum)/StringValue/value")
                        }
                    }
                }
            } else if paramParts.count == 1, let pIdx = Int(paramParts[0]), let dict = data as? [String: Any] {
                let props = dict["properties"] as? [String: Any] ?? [:]
                let pName = (props["Name"] as? [String: Any])?["value"] as? String ?? "Param \(pIdx + 1)"
                let strVal = (props["StringValue"] as? [String: Any])?["value"] as? String ?? ""
                let normVal = toDouble((props["NormalizedValue"] as? [String: Any])?["value"]) ?? 0.0

                let pObj = eff.parameters[pIdx] ?? UADEffectParam(index: pIdx)
                pObj.name = pName
                pObj.strVal = strVal
                pObj.normVal = normVal
                eff.parameters[pIdx] = pObj
                onChannelChange?("effect_param", ch.id, (eff, pIdx, pObj))
                onChannelChange?("effect_param_str", ch.id, (eff, pIdx, pObj))
            } else if paramParts.count == 3, paramParts[2] == "value", let pIdx = Int(paramParts[0]) {
                let prop = paramParts[1]
                let pObj = eff.parameters[pIdx] ?? UADEffectParam(index: pIdx)
                if prop == "NormalizedValue", let val = toDouble(data) {
                    pObj.normVal = val
                    eff.parameters[pIdx] = pObj
                    onChannelChange?("effect_param", ch.id, (eff, pIdx, pObj))
                    onChannelChange?("effect_param_norm", ch.id, (eff, pIdx, pObj))
                } else if prop == "StringValue", let val = data as? String {
                    pObj.strVal = val
                    eff.parameters[pIdx] = pObj
                    onChannelChange?("effect_param", ch.id, (eff, pIdx, pObj))
                    onChannelChange?("effect_param_str", ch.id, (eff, pIdx, pObj))
                } else if prop == "Name", let val = data as? String {
                    pObj.name = val
                    eff.parameters[pIdx] = pObj
                    onChannelChange?("effect_param", ch.id, (eff, pIdx, pObj))
                }
            }
            return
        }

        // Effect properties: /devices/{d}/{inputs|auxs}/{i}/effects/{effIdx}/{prop}/value
        if parts.count == 8, parts[4] == "effects", parts[7] == "value" {
            let base = "/devices/\(parts[1])/\(parts[2])/\(parts[3])"
            guard let ch = pathToChannel[base] else { return }
            let effIdx = Int(parts[5]) ?? 0
            if ch.effects[effIdx] == nil {
                ch.effects[effIdx] = UADEffect(index: effIdx)
            }
            let eff = ch.effects[effIdx]!
            let prop = parts[6]

            if prop == "EffectName", let name = data as? String {
                eff.name = name
                onChannelChange?("effect_prop", ch.id, (effIdx, prop, name))
            } else if prop == "Power", let pow = data as? Bool {
                eff.power = pow
                onChannelChange?("effect_prop", ch.id, (effIdx, prop, pow))
            }
            return
        }

        // Unison effect properties: /devices/{d}/inputs/{i}/preamps/0/effects/0/{prop}/value
        if parts.count == 10, parts[4] == "preamps", parts[5] == "0", parts[6] == "effects", parts[7] == "0", parts[9] == "value" {
            let base = "/devices/\(parts[1])/\(parts[2])/\(parts[3])"
            guard let ch = pathToChannel[base] else { return }
            let prop = parts[8]

            if prop == "EffectName", let name = data as? String {
                ch.unisonEffect.name = name
                ch.preamp.unisonPluginName = name
                onChannelChange?("unison_prop", ch.id, (prop, name))
            } else if prop == "Power", let pow = data as? Bool {
                ch.unisonEffect.power = pow
                ch.preamp.unisonPower = pow
                onChannelChange?("unison_prop", ch.id, (prop, pow))
            }
            return
        }
    }

    // MARK: - Channel Rebuilding

    private func scheduleChannelRebuild() {
        channelRebuildTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.1)
        timer.setEventHandler { [weak self] in
            self?.buildChannels()
        }
        channelRebuildTimer = timer
        timer.resume()
    }

    private func buildChannels() {
        lock.lock()
        defer { lock.unlock() }

        var sortedDevIds = Array(devices.keys).sorted { d1, d2 in
            let ord1 = devices[d1]?.order ?? d1
            let ord2 = devices[d2]?.order ?? d2
            return ord1 == ord2 ? d1 < d2 : ord1 < ord2
        }
        if sortedDevIds.isEmpty { sortedDevIds = [0] }

        var newChannels: [Int: UADChannel] = [:]
        var newPathMap: [String: UADChannel] = [:]
        var bridgeIdx = 0

        // 1. Process inputs
        for devId in sortedDevIds {
            let inputKeys = rawInputs.keys.filter { $0.hasPrefix("\(devId)_") }
                .sorted { Int($0.components(separatedBy: "_")[1])! < Int($1.components(separatedBy: "_")[1])! }

            for key in inputKeys {
                let parts = key.components(separatedBy: "_")
                let inpId = Int(parts[1])!
                let raw = rawInputs[key] ?? [:]
                let props = raw["properties"] as? [String: Any] ?? [:]
                let active = (props["Active"] as? [String: Any])?["value"] as? Bool ?? true
                let ioType = (props["IOType"] as? [String: Any])?["value"] as? String ?? ""
                let name = (props["Name"] as? [String: Any])?["value"] as? String ?? ""

                if !active || ioType == "None" || name.hasPrefix("N/A") {
                    continue
                }

                let devPath = "/devices/\(devId)/inputs/\(inpId)"
                let ch = pathToChannel[devPath] ?? UADChannel(id: bridgeIdx)
                ch.id = bridgeIdx
                ch.chType = "input"
                ch.devPath = devPath
                ch.devId = devId
                ch.devName = devices[devId]?.name ?? "Apollo \(devId)"
                ch.unitOrder = devices[devId]?.order ?? devId
                ch.stereo = (props["Stereo"] as? [String: Any])?["value"] as? Bool ?? false
                ch.stereoName = ((props["StereoName"] as? [String: Any])?["value"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                ch.monoName = name.isEmpty ? "Ch \(bridgeIdx + 1)" : name.trimmingCharacters(in: .whitespaces)
                ch.name = ch.getEffectiveName()

                if let fDb = toDouble((props["FaderLevel"] as? [String: Any])?["value"]) {
                    ch.faderDb = fDb
                } else if let f = toDouble((props["FaderLevelTapered"] as? [String: Any])?["value"]) {
                    ch.faderDb = UADCurve.taperedToDb(f)
                }
                if let f = toDouble((props["FaderLevelTapered"] as? [String: Any])?["value"]) {
                    ch.fader = f
                }
                if let p = toDouble((props["Pan"] as? [String: Any])?["value"]) { ch.pan = p }
                if let p2 = toDouble((props["Pan2"] as? [String: Any])?["value"]) { ch.pan2 = p2 }
                if let m = (props["Mute"] as? [String: Any])?["value"] as? Bool { ch.mute = m }
                if let s = (props["Solo"] as? [String: Any])?["value"] as? Bool { ch.solo = s }

                newChannels[bridgeIdx] = ch
                newPathMap[devPath] = ch
                bridgeIdx += 1

                subscribeChannelProperties(ch: ch, devPath: devPath)
            }
        }

        // 2. Process auxes
        for devId in sortedDevIds {
            let auxKeys = rawAuxs.keys.filter { $0.hasPrefix("\(devId)_") }
                .sorted { Int($0.components(separatedBy: "_")[1])! < Int($1.components(separatedBy: "_")[1])! }

            for key in auxKeys {
                let parts = key.components(separatedBy: "_")
                let auxId = Int(parts[1])!
                let raw = rawAuxs[key] ?? [:]
                let props = raw["properties"] as? [String: Any] ?? [:]
                let active = (props["Active"] as? [String: Any])?["value"] as? Bool ?? true
                if !active { continue }

                let devPath = "/devices/\(devId)/auxs/\(auxId)"
                let ch = pathToChannel[devPath] ?? UADChannel(id: bridgeIdx, chType: "aux")
                ch.id = bridgeIdx
                ch.chType = "aux"
                ch.devPath = devPath
                ch.devId = devId
                ch.devName = devices[devId]?.name ?? "Apollo \(devId)"
                ch.unitOrder = devices[devId]?.order ?? devId
                ch.monoName = "AUX \(auxId + 1)"
                ch.name = ch.monoName

                if let fDb = toDouble((props["FaderLevel"] as? [String: Any])?["value"]) {
                    ch.faderDb = fDb
                } else if let f = toDouble((props["FaderLevelTapered"] as? [String: Any])?["value"]) {
                    ch.faderDb = UADCurve.taperedToDb(f)
                }
                if let f = toDouble((props["FaderLevelTapered"] as? [String: Any])?["value"]) {
                    ch.fader = f
                }
                if let m = (props["Mute"] as? [String: Any])?["value"] as? Bool { ch.mute = m }

                newChannels[bridgeIdx] = ch
                newPathMap[devPath] = ch
                bridgeIdx += 1

                subscribeChannelProperties(ch: ch, devPath: devPath)
            }
        }

        self.channels = newChannels
        self.pathToChannel = newPathMap

        let chNames = newChannels.values.sorted { $0.id < $1.id }.map { $0.name }
        bridgeLog("[UAD] Active channels updated (\(newChannels.count) across \(devices.count) devices): \(chNames)")

        onChannelChange?("channel_list", channels.count, Array(channels.keys))
        onChannelChange?("refresh_all", -1, nil)
        startMeterPolling()
    }

    private func subscribeChannelProperties(ch: UADChannel, devPath: String) {
        if !subscribedPaths.contains(devPath) {
            subscribedPaths.insert(devPath)
            sendCommand("subscribe \(devPath)/FaderLevel/value")
            sendCommand("subscribe \(devPath)/FaderLevelTapered/value")
            sendCommand("subscribe \(devPath)/meters/0/MeterPeakLevel/value")
            sendCommand("subscribe \(devPath)/meters/0/MeterLevel/value")
            sendCommand("subscribe \(devPath)/meters/0/MeterClip/value")
            if ch.stereo {
                sendCommand("subscribe \(devPath)/meters/1/MeterPeakLevel/value")
                sendCommand("subscribe \(devPath)/meters/1/MeterLevel/value")
                sendCommand("subscribe \(devPath)/meters/1/MeterClip/value")
            }
            sendCommand("subscribe \(devPath)/Pan/value")
            sendCommand("subscribe \(devPath)/Pan2/value")
            sendCommand("subscribe \(devPath)/Mute/value")
            sendCommand("subscribe \(devPath)/Solo/value")
            sendCommand("subscribe \(devPath)/Name/value")
            sendCommand("subscribe \(devPath)/StereoName/value")
            sendCommand("subscribe \(devPath)/Stereo/value")
            sendCommand("subscribe \(devPath)/Active/value")

            if ch.chType == "input" {
                sendCommand("get \(devPath)/RecordPreEffects")
                sendCommand("subscribe \(devPath)/RecordPreEffects/value")
                sendCommand("get \(devPath)/preamps/0")
                sendCommand("subscribe \(devPath)/preamps/0/Gain/value")
                sendCommand("subscribe \(devPath)/preamps/0/GainTapered/value")
                sendCommand("subscribe \(devPath)/preamps/0/48V/value")
                sendCommand("subscribe \(devPath)/preamps/0/Pad/value")
                sendCommand("subscribe \(devPath)/preamps/0/LowCut/value")
                sendCommand("subscribe \(devPath)/preamps/0/Phase/value")
                sendCommand("subscribe \(devPath)/preamps/0/HiZ/value")
                sendCommand("subscribe \(devPath)/preamps/0/PreampGainCustomDisplayText/value")
                sendCommand("get \(devPath)/preamps/0/effects/0")
                sendCommand("subscribe \(devPath)/preamps/0/effects/0/EffectName/value")
                sendCommand("subscribe \(devPath)/preamps/0/effects/0/Power/value")

                for sIdx in 0..<6 {
                    sendCommand("get \(devPath)/sends/\(sIdx)")
                    sendCommand("subscribe \(devPath)/sends/\(sIdx)/GainTapered/value")
                    sendCommand("subscribe \(devPath)/sends/\(sIdx)/Pan/value")
                    sendCommand("subscribe \(devPath)/sends/\(sIdx)/Bypass/value")
                }
                for effIdx in 0..<8 {
                    sendCommand("get \(devPath)/effects/\(effIdx)")
                    sendCommand("subscribe \(devPath)/effects/\(effIdx)/EffectName/value")
                    sendCommand("subscribe \(devPath)/effects/\(effIdx)/Power/value")
                }
            } else if ch.chType == "aux" {
                for cIdx in 0..<4 {
                    sendCommand("get \(devPath)/sends/\(cIdx)")
                    sendCommand("subscribe \(devPath)/sends/\(cIdx)/GainTapered/value")
                    sendCommand("subscribe \(devPath)/sends/\(cIdx)/Bypass/value")
                }
                for effIdx in 0..<4 {
                    sendCommand("get \(devPath)/effects/\(effIdx)")
                    sendCommand("subscribe \(devPath)/effects/\(effIdx)/EffectName/value")
                    sendCommand("subscribe \(devPath)/effects/\(effIdx)/Power/value")
                }
            }
        }
    }

    private func discoverDevices() {
        sendCommand("get /devices")
        sendCommand("get /devices/0")
        sendCommand("get /devices/0/outputs")
        sendCommand("get /devices/1")
        sendCommand("get /devices/1/outputs")
    }



    // MARK: - Control Setters

    public func setFader(chId: Int, tapered: Double) {
        guard let ch = channels[chId], !ch.devPath.isEmpty else { return }
        let fid = nextFuncId()
        let val = max(0.0, min(1.0, tapered))
        sendCommand("set \(ch.devPath)/FaderLevelTapered/value?context_type=main&func_id=\(fid) \(String(format: "%.6f", val))")
        ch.fader = val
        ch.faderDb = UADCurve.taperedToDb(val)
    }

    public func setMute(chId: Int, mute: Bool) {
        guard let ch = channels[chId], !ch.devPath.isEmpty else { return }
        let fid = nextFuncId()
        sendCommand("set \(ch.devPath)/Mute/value?context_type=main&func_id=\(fid) \(mute ? "true" : "false")")
        ch.mute = mute
        onChannelChange?("mute", chId, mute)
    }

    public func setSolo(chId: Int, solo: Bool) {
        guard let ch = channels[chId], !ch.devPath.isEmpty else { return }
        let fid = nextFuncId()
        sendCommand("set \(ch.devPath)/Solo/value?context_type=main&func_id=\(fid) \(solo ? "true" : "false")")
        ch.solo = solo
        onChannelChange?("solo", chId, solo)
    }

    public func setPan(chId: Int, pan: Double) {
        guard let ch = channels[chId], !ch.devPath.isEmpty else { return }
        let fid = nextFuncId()
        let val = max(-1.0, min(1.0, pan))
        sendCommand("set \(ch.devPath)/Pan/value?context_type=main&func_id=\(fid) \(String(format: "%.4f", val))")
        ch.pan = val
    }

    public func setPan2(chId: Int, pan: Double) {
        guard let ch = channels[chId], !ch.devPath.isEmpty else { return }
        let fid = nextFuncId()
        let val = max(-1.0, min(1.0, pan))
        sendCommand("set \(ch.devPath)/Pan2/value?context_type=main&func_id=\(fid) \(String(format: "%.4f", val))")
        ch.pan2 = val
    }

    public func setPreampGain(chId: Int, gainDb: Double) {
        guard let ch = channels[chId], ch.preamp.hasPreamp, !ch.devPath.isEmpty else { return }
        let fid = nextFuncId()
        let val = max(10.0, min(65.0, gainDb))
        sendCommand("set \(ch.devPath)/preamps/0/Gain/value?context_type=main&func_id=\(fid) \(String(format: "%.1f", val))")
        ch.preamp.gain = val
        onChannelChange?("preamp_gain", chId, val)
    }

    public func setPreampLowCut(chId: Int, on: Bool) {
        guard let ch = channels[chId], ch.preamp.hasPreamp, !ch.devPath.isEmpty else { return }
        let fid = nextFuncId()
        sendCommand("set \(ch.devPath)/preamps/0/LowCut/value?context_type=main&func_id=\(fid) \(on ? "true" : "false")")
        ch.preamp.lowCut = on
        onChannelChange?("preamp_lowcut", chId, on)
    }

    public func setPreampPad(chId: Int, on: Bool) {
        guard let ch = channels[chId], ch.preamp.hasPreamp, !ch.devPath.isEmpty else { return }
        let fid = nextFuncId()
        sendCommand("set \(ch.devPath)/preamps/0/Pad/value?context_type=main&func_id=\(fid) \(on ? "true" : "false")")
        ch.preamp.pad = on
        onChannelChange?("preamp_pad", chId, on)
    }

    public func setPreampPhase(chId: Int, inverted: Bool) {
        guard let ch = channels[chId], ch.preamp.hasPreamp, !ch.devPath.isEmpty else { return }
        let fid = nextFuncId()
        sendCommand("set \(ch.devPath)/preamps/0/Phase/value?context_type=main&func_id=\(fid) \(inverted ? "true" : "false")")
        ch.preamp.phase = inverted
        onChannelChange?("preamp_phase", chId, inverted)
    }

    public func setSendGain(chId: Int, sendIdx: Int, value: Double) {
        guard let ch = channels[chId], !ch.devPath.isEmpty else { return }
        if ch.chType == "aux" && sendIdx < 2 { return }
        let val = max(0.0, min(1.0, value))
        let fid = nextFuncId()
        let targetSendIdx = (ch.chType == "aux") ? (sendIdx - 2) : sendIdx
        sendCommand("set \(ch.devPath)/sends/\(targetSendIdx)/GainTapered/value?context_type=main&func_id=\(fid) \(String(format: "%.6f", val))")
        let send = ch.sends[sendIdx] ?? UADSend(index: sendIdx)
        send.gain = val
        send.gainDb = UADCurve.taperedToDb(val)
        ch.sends[sendIdx] = send
    }

    public func setSendPan(chId: Int, sendIdx: Int, value: Double) {
        guard let ch = channels[chId], !ch.devPath.isEmpty else { return }
        if ch.chType == "aux" { return }
        let val = max(-1.0, min(1.0, value))
        let fid = nextFuncId()
        sendCommand("set \(ch.devPath)/sends/\(sendIdx)/Pan/value?context_type=main&func_id=\(fid) \(String(format: "%.4f", val))")
        let send = ch.sends[sendIdx] ?? UADSend(index: sendIdx)
        send.pan = val
        ch.sends[sendIdx] = send
    }

    public func setSendBypass(chId: Int, sendIdx: Int, bypass: Bool) {
        guard let ch = channels[chId], !ch.devPath.isEmpty else { return }
        if ch.chType == "aux" && sendIdx < 2 { return }
        let fid = nextFuncId()
        let targetSendIdx = (ch.chType == "aux") ? (sendIdx - 2) : sendIdx
        sendCommand("set \(ch.devPath)/sends/\(targetSendIdx)/Bypass/value?context_type=main&func_id=\(fid) \(bypass ? "true" : "false")")
        let send = ch.sends[sendIdx] ?? UADSend(index: sendIdx)
        send.bypass = bypass
        ch.sends[sendIdx] = send
    }

    public func getEffectivePan(chId: Int) -> Double {
        guard let ch = channels[chId] else { return 0.0 }
        if ch.stereo {
            return (ch.pan + ch.pan2) / 2.0
        }
        return ch.pan
    }

    public func setChannelStereoPan(chId: Int, balance: Double) {
        guard let ch = channels[chId], !ch.devPath.isEmpty, ch.chType != "aux" else { return }
        let bal = max(-1.0, min(1.0, balance))
        if ch.stereo {
            let panL: Double
            let panR: Double
            if bal <= 0.0 {
                panL = -1.0
                panR = max(-1.0, min(1.0, 1.0 + (bal * 2.0)))
            } else {
                panL = max(-1.0, min(1.0, -1.0 + (bal * 2.0)))
                panR = 1.0
            }
            setPan(chId: chId, pan: panL)
            setPan2(chId: chId, pan: panR)
        } else {
            setPan(chId: chId, pan: bal)
        }
    }

    public func resetPan(chId: Int) {
        guard let ch = channels[chId], !ch.devPath.isEmpty, ch.chType != "aux" else { return }
        if ch.stereo {
            setPan(chId: chId, pan: -1.0)
            setPan2(chId: chId, pan: 1.0)
        } else {
            setPan(chId: chId, pan: 0.0)
        }
    }

    public func setEffectPower(chId: Int, eff: UADEffect, power: Bool) {
        guard let ch = channels[chId], !ch.devPath.isEmpty else { return }
        let fid = nextFuncId()
        let targetPath = eff.path.isEmpty ? (eff.isUnison ? "\(ch.devPath)/preamps/0/effects/0" : "\(ch.devPath)/effects/\(eff.index)") : eff.path
        sendCommand("set \(targetPath)/Power/value?context_type=main&func_id=\(fid) \(power ? "true" : "false")")
        eff.power = power
        if eff.isUnison {
            ch.preamp.unisonPower = power
            onChannelChange?("unison_prop", chId, ("Power", power))
        } else {
            onChannelChange?("effect_prop", chId, (eff.index, "Power", power))
        }
    }

    public func toggleEffectPower(chId: Int, eff: UADEffect) -> Bool {
        let newPow = !eff.power
        setEffectPower(chId: chId, eff: eff, power: newPow)
        return newPow
    }

    public func loadEffectParameters(chId: Int, eff: UADEffect, effPath: String = "") {
        let path = effPath.isEmpty ? eff.path : effPath
        guard !path.isEmpty else { return }
        eff.path = path
        sendCommand("get \(path)/parameters")
        for p in 0..<32 {
            sendCommand("get \(path)/parameters/\(p)")
            sendCommand("subscribe \(path)/parameters/\(p)/NormalizedValue/value")
            sendCommand("subscribe \(path)/parameters/\(p)/StringValue/value")
        }
    }

    public func setEffectParameter(chId: Int, eff: UADEffect, paramIdx: Int, normVal: Double) {
        guard !eff.path.isEmpty else { return }
        let val = max(0.0, min(1.0, normVal))
        let fid = nextFuncId()
        sendCommand("set \(eff.path)/parameters/\(paramIdx)/NormalizedValue/value?context_type=main&func_id=\(fid) \(String(format: "%.6f", val))")
        if let p = eff.parameters[paramIdx] {
            p.normVal = val
        }
    }

    public func setRecordPreEffects(chId: Int, isMon: Bool) {
        guard let ch = channels[chId], !ch.devPath.isEmpty else { return }
        let fid = nextFuncId()
        sendCommand("set \(ch.devPath)/RecordPreEffects/value?context_type=main&func_id=\(fid) \(isMon ? "true" : "false")")
        ch.recordPreEffects = isMon
        onChannelChange?("record_pre_effects", chId, isMon)
    }

    public func toggleRecordPreEffects(chId: Int) -> Bool {
        guard let ch = channels[chId] else { return false }
        let newMon = !ch.recordPreEffects
        setRecordPreEffects(chId: chId, isMon: newMon)
        return newMon
    }

    public func setMonitorLevelTapered(tapered: Double) {
        let val = max(0.0, min(1.0, tapered))
        let db = UADCurve.taperedToDb(val)
        let paths = monitorPaths.isEmpty ? [(monitorDeviceId, monitorOutputId)] : monitorPaths
        for (dId, oId) in paths {
            let fid1 = nextFuncId()
            let fid2 = nextFuncId()
            sendCommand("set /devices/\(dId)/outputs/\(oId)/CRMonitorLevelTapered/value?context_type=main&func_id=\(fid1) \(String(format: "%.6f", val))")
            sendCommand("set /devices/\(dId)/outputs/\(oId)/CRMonitorLevel/value?context_type=main&func_id=\(fid2) \(String(format: "%.1f", db))")
        }
        monitorLevelTapered = val
        monitorLevelDb = db
        bridgeLog("[UAD] setMonitorLevelTapered -> \(String(format: "%.4f", val)) (\(String(format: "%.1f", db)) dB) dispatched to \(paths.map { "/devices/\($0.devId)/outputs/\($0.outId)" })")
    }

    public func setMonitorMute(mute: Bool) {
        let paths = monitorPaths.isEmpty ? [(monitorDeviceId, monitorOutputId)] : monitorPaths
        for (dId, oId) in paths {
            let fid = nextFuncId()
            sendCommand("set /devices/\(dId)/outputs/\(oId)/Mute/value?context_type=main&func_id=\(fid) \(mute ? "true" : "false")")
        }
        monitorMute = mute
        bridgeLog("[UAD] setMonitorMute -> \(mute) dispatched to \(paths.map { "/devices/\($0.devId)/outputs/\($0.outId)" })")
    }

    public func toggleMonitorMute() -> Bool {
        let newMute = !monitorMute
        setMonitorMute(mute: newMute)
        return newMute
    }

    public func setMonitorDb(db: Double) {
        let val = max(-96.0, min(0.0, db))
        let tapered = UADCurve.dbToTapered(val)
        let paths = monitorPaths.isEmpty ? [(monitorDeviceId, monitorOutputId)] : monitorPaths
        for (dId, oId) in paths {
            let fid1 = nextFuncId()
            let fid2 = nextFuncId()
            sendCommand("set /devices/\(dId)/outputs/\(oId)/CRMonitorLevel/value?context_type=main&func_id=\(fid1) \(String(format: "%.1f", val))")
            sendCommand("set /devices/\(dId)/outputs/\(oId)/CRMonitorLevelTapered/value?context_type=main&func_id=\(fid2) \(String(format: "%.6f", tapered))")
        }
        monitorLevelDb = val
        monitorLevelTapered = tapered
        bridgeLog("[UAD] setMonitorDb -> \(String(format: "%.1f", val)) dB (tapered=\(String(format: "%.4f", tapered))) dispatched to \(paths.map { "/devices/\($0.devId)/outputs/\($0.outId)" })")
    }

    public func nudgeMonitorDb(deltaDb: Double) -> Bool {
        let currentDb = monitorLevelDb
        let targetDb = max(-96.0, min(0.0, currentDb + deltaDb))
        setMonitorDb(db: targetDb)
        return abs(targetDb - currentDb) >= 0.05
    }
}
