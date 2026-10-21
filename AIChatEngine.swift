// ==============================================================================
// Copyright (c) 2026 S&D A11y Studio. All Rights Reserved.
// Contact: jonlee0704@gmail.com / snda11ysolutions@gmail.com
//
// AI Studio Co-Producer: Natural Language Chat Dialog & Mixer Command Engine
// Hybrid Architecture: Instant Offline Mixer Automation + Optional Google Gemini API
// ==============================================================================

import Foundation
import Cocoa

// MARK: - Mixer State Snapshot for Undo / Redo

public struct MixerSnapshot {
    public let timestamp: Date
    public let description: String
    public let channelFaders: [Int: Double]       // chId -> tapered (0.0 .. 1.0)
    public let channelMutes: [Int: Bool]          // chId -> isMuted
    public let channelSolos: [Int: Bool]          // chId -> isSoloed
    public let channelPans: [Int: Double]         // chId -> pan (-1.0 .. 1.0)
    public let sendGains: [Int: [Int: Double]]    // chId -> [sendIdx: gainTapered]
    public let sendBypasses: [Int: [Int: Bool]]   // chId -> [sendIdx: isBypassed]
    public let effectPowers: [Int: [Int: Bool]]   // chId -> [effectIdx: isPowerOn]
    public let unisonPowers: [Int: Bool]          // chId -> isPowerOn
    public let effectParams: [Int: [Int: [Int: Double]]] // chId -> [effectIdx: [paramIdx: normVal]]
    public let unisonParams: [Int: [Int: Double]]        // chId -> [paramIdx: normVal]

    public init(description: String, uad: UADClient) {
        self.timestamp = Date()
        self.description = description

        var faders: [Int: Double] = [:]
        var mutes: [Int: Bool] = [:]
        var solos: [Int: Bool] = [:]
        var pans: [Int: Double] = [:]
        var sendsG: [Int: [Int: Double]] = [:]
        var sendsB: [Int: [Int: Bool]] = [:]
        var effPows: [Int: [Int: Bool]] = [:]
        var uniPows: [Int: Bool] = [:]
        var effPars: [Int: [Int: [Int: Double]]] = [:]
        var uniPars: [Int: [Int: Double]] = [:]

        for (id, ch) in uad.channels {
            faders[id] = ch.fader
            mutes[id] = ch.mute
            solos[id] = ch.solo
            pans[id] = ch.pan

            var sg: [Int: Double] = [:]
            var sb: [Int: Bool] = [:]
            for (sIdx, send) in ch.sends {
                sg[sIdx] = send.gain
                sb[sIdx] = send.bypass
            }
            sendsG[id] = sg
            sendsB[id] = sb

            var ep: [Int: Bool] = [:]
            var eParams: [Int: [Int: Double]] = [:]
            for (eIdx, eff) in ch.effects {
                ep[eIdx] = eff.power
                var pMap: [Int: Double] = [:]
                for (pIdx, param) in eff.parameters {
                    pMap[pIdx] = param.normVal
                }
                eParams[eIdx] = pMap
            }
            effPows[id] = ep
            effPars[id] = eParams

            if ch.preamp.hasPreamp {
                uniPows[id] = ch.unisonEffect.power
                var uMap: [Int: Double] = [:]
                for (pIdx, param) in ch.unisonEffect.parameters {
                    uMap[pIdx] = param.normVal
                }
                uniPars[id] = uMap
            }
        }

        self.channelFaders = faders
        self.channelMutes = mutes
        self.channelSolos = solos
        self.channelPans = pans
        self.sendGains = sendsG
        self.sendBypasses = sendsB
        self.effectPowers = effPows
        self.unisonPowers = uniPows
        self.effectParams = effPars
        self.unisonParams = uniPars
    }

    public func restore(to uad: UADClient) {
        for (id, fader) in channelFaders {
            uad.setFader(chId: id, tapered: fader)
        }
        for (id, mute) in channelMutes {
            uad.setMute(chId: id, mute: mute)
        }
        for (id, solo) in channelSolos {
            uad.setSolo(chId: id, solo: solo)
        }
        for (id, pan) in channelPans {
            uad.setPan(chId: id, pan: pan)
        }
        for (id, sMap) in sendGains {
            for (sIdx, gain) in sMap {
                uad.setSendGain(chId: id, sendIdx: sIdx, value: gain)
            }
        }
        for (id, bMap) in sendBypasses {
            for (sIdx, bypass) in bMap {
                uad.setSendBypass(chId: id, sendIdx: sIdx, bypass: bypass)
            }
        }
        for (id, epMap) in effectPowers {
            guard let ch = uad.channels[id] else { continue }
            for (effIdx, power) in epMap {
                if let eff = ch.effects[effIdx] {
                    uad.setEffectPower(chId: id, eff: eff, power: power)
                }
            }
        }
        for (id, power) in unisonPowers {
            guard let ch = uad.channels[id], ch.preamp.hasPreamp else { continue }
            uad.setEffectPower(chId: id, eff: ch.unisonEffect, power: power)
        }
        for (id, eMap) in effectParams {
            guard let ch = uad.channels[id] else { continue }
            for (effIdx, pMap) in eMap {
                if let eff = ch.effects[effIdx] {
                    for (pIdx, val) in pMap {
                        uad.setEffectParameter(chId: id, eff: eff, paramIdx: pIdx, normVal: val)
                    }
                }
            }
        }
        for (id, uMap) in unisonParams {
            guard let ch = uad.channels[id], ch.preamp.hasPreamp else { continue }
            for (pIdx, val) in uMap {
                uad.setEffectParameter(chId: id, eff: ch.unisonEffect, paramIdx: pIdx, normVal: val)
            }
        }
    }
}

// MARK: - Mixer History Manager

public final class MixerHistoryManager {
    public private(set) var undoStack: [MixerSnapshot] = []
    public private(set) var redoStack: [MixerSnapshot] = []
    public let maxDepth: Int = 20

    public init() {}

    public func takeSnapshot(uad: UADClient, description: String) {
        let snap = MixerSnapshot(description: description, uad: uad)
        undoStack.append(snap)
        if undoStack.count > maxDepth {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }

    public func undo(uad: UADClient) -> String? {
        guard let prev = undoStack.popLast() else { return nil }
        let current = MixerSnapshot(description: "Redo of \(prev.description)", uad: uad)
        redoStack.append(current)
        prev.restore(to: uad)
        return prev.description
    }

    public func redo(uad: UADClient) -> String? {
        guard let next = redoStack.popLast() else { return nil }
        let current = MixerSnapshot(description: "Undo of \(next.description)", uad: uad)
        undoStack.append(current)
        next.restore(to: uad)
        return next.description
    }

    public func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}

// MARK: - Local LLM (Ollama) Service Manager

public final class OllamaServiceManager: @unchecked Sendable {
    public static let shared = OllamaServiceManager()
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2.0
        config.timeoutIntervalForResource = 3.0
        self.session = URLSession(configuration: config)
    }

    /// Check if Ollama endpoint is actively responding
    public func isOllamaRunning(endpoint: String = "http://127.0.0.1:11434", completion: @escaping @Sendable (Bool) -> Void) {
        let cleanEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "\(cleanEndpoint)/api/tags") else {
            completion(false)
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 2.0

        let task = session.dataTask(with: req) { _, response, error in
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                completion(true)
            } else {
                completion(false)
            }
        }
        task.resume()
    }

    /// Verifies model availability and automatically establishes alias if needed
    public func ensureModelAlias(endpoint: String = "http://127.0.0.1:11434") {
        let cleanEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "\(cleanEndpoint)/api/tags") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 2.0
        let task = session.dataTask(with: req) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else { return }
            let names = models.compactMap { $0["name"] as? String }
            let has3b = names.contains { $0.contains("llama3.2:3b") }
            let hasPlain = names.contains { $0 == "llama3.2" || $0 == "llama3.2:latest" }
            if has3b && !hasPlain {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                proc.arguments = ["ollama", "cp", "llama3.2:3b", "llama3.2"]
                try? proc.run()
            }
        }
        task.resume()
    }

    /// Automatically ensure Ollama is running. If not responding, starts via brew services or ollama serve in background.
    public func ensureOllamaRunning(endpoint: String = "http://127.0.0.1:11434", completion: @escaping @Sendable (Bool) -> Void) {
        isOllamaRunning(endpoint: endpoint) { [weak self] running in
            if running {
                self?.ensureModelAlias(endpoint: endpoint)
                completion(true)
                return
            }

            guard let self = self else {
                completion(false)
                return
            }

            // 1. Attempt to launch via brew services
            let brewProc = Process()
            brewProc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            brewProc.arguments = ["brew", "services", "start", "ollama"]
            try? brewProc.run()

            // 2. Also attempt direct launch of ollama binary in background if installed
            let candidates = ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"]
            for path in candidates {
                if FileManager.default.fileExists(atPath: path) {
                    let proc = Process()
                    proc.executableURL = URL(fileURLWithPath: path)
                    proc.arguments = ["serve"]
                    try? proc.run()
                    break
                }
            }

            // 3. Poll for readiness for up to 4.5 seconds
            final class AttemptBox: @unchecked Sendable {
                var count: Int = 0
            }
            let box = AttemptBox()
            let maxAttempts = 6
            Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { timer in
                box.count += 1
                self.isOllamaRunning(endpoint: endpoint) { active in
                    if active {
                        timer.invalidate()
                        self.ensureModelAlias(endpoint: endpoint)
                        completion(true)
                    } else if box.count >= maxAttempts {
                        timer.invalidate()
                        completion(false)
                    }
                }
            }
        }
    }
}

// MARK: - AI Chat Engine & Natural Language Intent Processor

public final class AIChatEngine: @unchecked Sendable {
    public static let shared = AIChatEngine()

    public let history = MixerHistoryManager()
    public var geminiApiKey: String = ""
    public var geminiModel: String = "gemini-3.8-flash"
    public var aiProvider: String = "local" // "local" (default), "auto", "gemini"
    public var preferLocalLLMOverTelemetry: Bool = true
    public var ollamaEndpoint: String = "http://127.0.0.1:11434"
    public var ollamaModel: String = "llama3.2"

    // Cancellation & In-flight Task Management
    public private(set) var isQueryCancelled: Bool = false
    private var activeTask: URLSessionDataTask?
    private var timedListenTimer: DispatchSourceTimer?
    private var timedListenCompletion: ((String) -> Void)?
    private weak var timedListenAuditor: AIAudioAuditor?
    private let queryLock = NSLock()

    public init() {}

    /// Abort in-flight network query or cancel pending execution.
    public func cancelCurrentQuery() {
        queryLock.lock()
        isQueryCancelled = true
        let task = activeTask
        activeTask = nil
        let timer = timedListenTimer
        timedListenTimer = nil
        let timedComp = timedListenCompletion
        timedListenCompletion = nil
        let auditor = timedListenAuditor
        timedListenAuditor = nil
        queryLock.unlock()

        task?.cancel()
        timer?.cancel()

        if let comp = timedComp {
            auditor?.mcu?.sendMIDI([0x90, 70, 0x00])
            auditor?.mcu?.sendMIDI([0x90, 83, 0x00])
            comp("⏹ *Listening session cancelled.*")
        }
    }

    /// Process user natural language input.
    /// Returns: assistant response message (via completion).
    public func processQuery(query: String, uad: UADClient, auditor: AIAudioAuditor, completion: @escaping (String) -> Void) {
        processQuery(query: query, uad: uad, auditor: auditor, progress: nil, completion: completion)
    }

    /// Process user natural language input with real-time progress reporting.
    public func processQuery(query: String, uad: UADClient, auditor: AIAudioAuditor, progress: ((String) -> Void)? = nil, completion: @escaping (String) -> Void) {
        queryLock.lock()
        isQueryCancelled = false
        queryLock.unlock()

        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            completion("Please enter a command or ask a question.")
            return
        }

        // 0. Timed Telemetry Listening & Capture (e.g. "listening 10 secs and analyze xyz...")
        if let timedIntent = Self.parseTimedListeningIntent(text) {
            handleTimedListeningQuery(
                intent: timedIntent,
                rawQuery: text,
                uad: uad,
                auditor: auditor,
                progress: progress,
                completion: completion
            )
            return
        }

        let lower = text.lowercased()

        // 0.5 Prompt Examples & Help Page Command
        if Self.isPromptExamplesQuery(lower) {
            let helpSummary = AIPromptCatalog.generateChatHelpSummary()
            NotificationCenter.default.post(name: NSNotification.Name("ShowAIPromptHelpNotification"), object: nil)
            completion(helpSummary)
            return
        }

        // 1. Direct Physical Actions & Hardware Mutations (0ms Local Execution)
        if Self.isSetAllInfinityQuery(lower) {
            let response = handleSetAllInfinity(uad: uad)
            completion(response)
            return
        }

        if Self.isUndoQuery(lower) {
            if let desc = history.undo(uad: uad) {
                completion("↩️ Undid: \(desc). Mixer state restored to previous step.")
            } else {
                completion("No previous history states to undo.")
            }
            return
        }

        if Self.isRedoQuery(lower) {
            if let desc = history.redo(uad: uad) {
                completion("🔁 Redid: \(desc).")
            } else {
                completion("No redo states available.")
            }
            return
        }

        if let cueCmd = handleCueCommandOnly(lower, rawQuery: text, uad: uad, auditor: auditor) {
            completion(cueCmd)
            return
        }

        if let pluginCmd = handlePluginCommandOnly(lower, rawQuery: text, uad: uad, auditor: auditor) {
            completion(pluginCmd)
            return
        }

        if let trackResponse = handleTrackMuteSoloQuery(lower, rawQuery: text, uad: uad, auditor: auditor) {
            completion(trackResponse)
            return
        }

        if let faderResponse = handleFaderControlQuery(lower, rawQuery: text, uad: uad, auditor: auditor) {
            completion(faderResponse)
            return
        }

        if let panResponse = handlePanControlQuery(lower, rawQuery: text, uad: uad, auditor: auditor) {
            completion(panResponse)
            return
        }

        if let preampResponse = handlePreampControlQuery(lower, rawQuery: text, uad: uad, auditor: auditor) {
            completion(preampResponse)
            return
        }

        if let monitorResponse = handleMonitorControlQuery(lower, rawQuery: text, uad: uad) {
            completion(monitorResponse)
            return
        }

        if let surfaceResponse = handleSurfaceControlQuery(lower, rawQuery: text, uad: uad, auditor: auditor) {
            completion(surfaceResponse)
            return
        }

        if let recMonResponse = handleUADRecMonQuery(lower, uad: uad) {
            completion(recMonResponse)
            return
        }

        // 2. Interactive Conversational & AI Telemetry Comprehension (Local LLM by Default)
        let currentProvider = aiProvider.lowercased()
        let isInteractive = (progress != nil)

        if preferLocalLLMOverTelemetry && (currentProvider == "local" || currentProvider == "auto") && isInteractive {
            progress?("Thinking with Local Llama 3.2...")
            let fallbackHandler: () -> String = { [weak self] in
                guard let self = self else { return "" }
                return self.handleOfflineTelemetryOrInquiry(lower: lower, rawQuery: text, uad: uad, auditor: auditor)
            }
            queryLocalLLM(prompt: text, uad: uad, auditor: auditor, fallback: fallbackHandler, completion: completion)
            return
        }

        if currentProvider == "gemini" && !geminiApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isInteractive {
            progress?("Querying Google Gemini 3.8 Flash...")
            queryGeminiAPI(prompt: text, uad: uad, auditor: auditor, completion: completion)
            return
        }

        // 3. Offline Synchronous Telemetry & Inspection (For Unit Tests, Offline Mode & Fallback)
        let response = handleOfflineTelemetryOrInquiry(lower: lower, rawQuery: text, uad: uad, auditor: auditor)
        completion(response)
    }

    /// Detects if query is a direct CUE send mute/unmute or gain level command
    private func handleCueCommandOnly(_ lower: String, rawQuery: String, uad: UADClient, auditor: AIAudioAuditor) -> String? {
        guard Self.isCueQuery(lower) else { return nil }
        let isQuestion = lower.contains("show") || lower.contains("what") || lower.contains("list") || lower.contains("which") || lower.contains("info") || lower.contains("who") || lower.contains("?")
        if isQuestion { return nil }
        let labels = getSendLabels(auditor: auditor)
        let isMute = lower.contains("mute") && !lower.contains("unmute")
        let isUnmute = lower.contains("unmute")
        let isGain = (lower.contains("set") || lower.contains("level") || lower.contains("to") || lower.contains("db")) && !lower.contains("show")
        if (isMute || isUnmute || isGain), detectSendIndex(lower, labels: labels) != nil {
            return handleCueQuery(lower, rawQuery: rawQuery, uad: uad, auditor: auditor)
        }
        return nil
    }

    /// Detects if query is a direct plugin bypass/enable/power command
    private func handlePluginCommandOnly(_ lower: String, rawQuery: String, uad: UADClient, auditor: AIAudioAuditor) -> String? {
        guard Self.isPluginQuery(lower) else { return nil }
        let isQuestion = lower.contains("show") || lower.contains("what") || lower.contains("list") || lower.contains("which") || lower.contains("info") || lower.contains("how") || lower.contains("?")
        if isQuestion { return nil }
        let isPowerToggle = lower.contains("bypass") || lower.contains("unbypass") || lower.contains("enable") || lower.contains("disable") || lower.contains("turn on") || lower.contains("turn off") || lower.contains("toggle")
        if isPowerToggle {
            return handlePluginQuery(lower, rawQuery: rawQuery, uad: uad, auditor: auditor)
        }
        return nil
    }

    /// Formats deterministic offline telemetry inspection tables or guides
    public func handleOfflineTelemetryOrInquiry(lower: String, rawQuery: String, uad: UADClient, auditor: AIAudioAuditor) -> String {
        // 1. Overloaded / Clipping Channels
        if Self.isOverloadQuery(lower) {
            return handleOverloadQuery(uad: uad, auditor: auditor)
        }

        // 2. Zero Input / Silent Channels
        if Self.isZeroInputQuery(lower) {
            return handleZeroInputQuery(uad: uad)
        }

        // 3. Active Signal / Audio Streams
        if Self.isActiveSignalQuery(lower) {
            return handleActiveSignalQuery(uad: uad)
        }

        // 4. Mute / Solo Status Inspection
        if isMuteSoloStatusQuery(lower) {
            return handleMuteSoloStatusQuery(lower: lower, uad: uad)
        }

        // 5. Full Channel List / Complete Inventory
        if Self.isFullChannelListQuery(lower) {
            return handleFullChannelListQuery(uad: uad)
        }

        // 6. Console / Session Summary
        if Self.isConsoleSummaryQuery(lower) {
            return handleConsoleSummaryQuery(uad: uad)
        }

        // 7. Fader Levels Inspection
        if isFaderInspectionQuery(lower) {
            return handleFaderInspectionQuery(uad: uad)
        }

        // 8. Pan Positions Inspection
        if isPanInspectionQuery(lower) {
            return handlePanInspectionQuery(uad: uad)
        }

        // 9. CUE & Sends Information
        if Self.isCueQuery(lower), let cueResp = handleCueQuery(lower, rawQuery: rawQuery, uad: uad, auditor: auditor) {
            return cueResp
        }

        // 10. UAD Plugins & Inserts Information
        if Self.isPluginQuery(lower), let plugResp = handlePluginQuery(lower, rawQuery: rawQuery, uad: uad, auditor: auditor) {
            return plugResp
        }

        // 11. SSL UF8 & Hardware Operation Guide
        if let guideResponse = handleHardwareGuideQuery(lower) {
            return guideResponse
        }

        // 12. Mix Audit / Pre-Flight Inspection
        if lower.contains("audit") || lower.contains("gain stage") || lower.contains("inspect") {
            if let latestUrl = AIReportManager.shared.latestReport(),
               let content = try? String(contentsOf: latestUrl) {
                return "📋 Latest Acoustic Audit Report:\n\n" + content
            } else if !auditor.suggestions.isEmpty {
                let items = auditor.suggestions.map { "• \($0.channelName): \($0.issueTitle) — \($0.voiceDescription)" }.joined(separator: "\n")
                return "📋 Active Co-Producer Recommendations:\n\n" + items
            } else {
                return "No active audit report found. Tap the FINE key on your UF8 to run a 32-channel acoustic pre-flight inspection!"
            }
        }

        // 13. Fallback Help Guidance
        return generateHelpGuidance()
    }

    public func generateHelpGuidance() -> String {
        return """
        🤖 S&D Co-Producer UAD Console Telemetry & Mixer Commands:
        • "Show CUE sends" / "CUE information" — Comprehensive 4 Cue buses + 2 Aux matrix
        • "Show CUE 1" / "CUE 2 sends" — Live tracks routing to specific Cue bus
        • "CUE sends for Vocal" / "Cues on Track 1" — Channel-specific 8-strip send readout
        • "Mute C2 level for System out" / "Set CUE 1 on Track 1 to 0 dB" — Direct CUE level & mute
        • "Show plugins" / "What plugins are loaded" — 32-channel UAD DSP & Unison inventory
        • "Plugins on Track 1" / "Plugins on Vocal" — Channel insert slots & parameter settings
        • "Show Unison plugins" — Analog preamp modeling models & analog hardware settings
        • "Which plugins are bypassed?" / "Bypass plugin on Track 1" — Plugin bypass control
        • "Which channels have zero input?" — Instant 0ms detection of silent channels/dead inputs
        • "Which channels have signal?" — Instant 0ms scan of live audio streams & peak dBFS
        • "Console summary" — Comprehensive Apollo mixer overview (mutes, solos, gains, headroom)
        • "Tell me channels in Overloaded" — List clipping/distorted tracks
        • "Set -infinite dB for all channels" — Pull down all 32 channel faders
        • "Go back to -1 step back history" (or "Undo") — Revert last mixer change
        • "Redo" — Re-apply undone changes
        • "Mute track 1" / "Unmute vocal" / "Mute all" — Tactile mute control
        • "Solo track 1" / "Unsolo kick" / "Clear solos" — Tactile solo control
        • "Set track 1 to 0 dB" / "Fader vocal to -6 dB" / "Unity all faders" — Motorized fader levels
        • "Pan track 1 left 40" / "Pan vocal center" / "Center all pans" — Stereo balance
        • "Turn on 48V on track 1" / "Low cut on vocal" / "Invert phase SD-Bottom" — Preamp controls
        • "Mute monitor" / "Unmute monitor" / "Set monitor volume to -18 dB" — Master hearing safety
        • "Bank 1" / "Bank 2" / "Page right" — SSL UF8 physical bank navigation
        • "Enter sends mode" / "Enter preamp mode" / "Main mix" — Hardware focus modes
        • "Rough mix" — One-Touch motorized fader auto-rough mix balancing
        • "Set track 1 to UAD REC" (or UAD MON) — Track print vs live monitor mode
        • "Listening 10 secs and analyze xyz" — Record 10s of 32-channel telemetry, save report & summarize
        • "Audit mix" — Run full acoustic pre-flight inspection

        💡 Tip: Running on Local Llama 3.2 by default! You can ask free-form mixing questions, gain staging recommendations, and track analysis anytime.
        """
    }

    // MARK: - Timed Telemetry Listening & Capture

    public struct TimedListeningIntent {
        public let seconds: Double
        public let subQuery: String
    }

    public struct ChannelSampleSummary {
        public let id: Int
        public let name: String
        public let chType: String
        public var maxPeak: Double = -144.0
        public var minPeak: Double = 0.0
        public var sumPeak: Double = 0.0
        public var sampleCount: Int = 0
        public var activeCount: Int = 0
        public var clipCount: Int = 0
        public var faderDb: Double = -144.0
        public var pan: Double = 0.0
        public var isMuted: Bool = false
        public var isSoloed: Bool = false

        public init(id: Int, name: String, chType: String) {
            self.id = id
            self.name = name
            self.chType = chType
        }

        public var avgPeak: Double {
            guard activeCount > 0 else { return -144.0 }
            return sumPeak / Double(activeCount)
        }

        public var activityPercent: Double {
            guard sampleCount > 0 else { return 0.0 }
            return (Double(activeCount) / Double(sampleCount)) * 100.0
        }
    }

    /// Parses prompts requesting timed listening (e.g. "listening 10 secs and analyze xyz...", "listen 10 seconds and analyze").
    public static func parseTimedListeningIntent(_ text: String) -> TimedListeningIntent? {
        let lower = text.lowercased()

        let hasVerb = lower.contains("listen") || lower.contains("listening") || lower.contains("sample") || lower.contains("sampling") || lower.contains("record")
        guard hasVerb else { return nil }

        var seconds: Double = 10.0
        var foundExplicitDuration = false

        let pattern = #"(\d+(?:\.\d+)?)\s*(?:seconds?|secs?|s\b)"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: lower, options: [], range: NSRange(lower.startIndex..., in: lower)),
           let numRange = Range(match.range(at: 1), in: lower),
           let parsedVal = Double(lower[numRange]) {
            seconds = max(1.0, min(60.0, parsedVal))
            foundExplicitDuration = true
        }

        if !foundExplicitDuration {
            if lower.contains("listen and") || lower.contains("listening and") || lower.contains("listen to") || lower.contains("listening to") {
                seconds = 10.0
            } else {
                return nil
            }
        }

        var subQuery = ""
        let delimiters = [" and ", " then ", " to analyze ", " to summarize ", " to check ", " to inspect "]
        for delim in delimiters {
            if let r = lower.range(of: delim) {
                subQuery = String(text[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        if subQuery.isEmpty {
            for keyword in ["analyze", "summarise", "summarize", "check", "inspect", "report"] {
                if let r = lower.range(of: keyword) {
                    subQuery = String(text[r.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }
        }
        if subQuery.isEmpty {
            subQuery = "analyze overall mixer telemetry and gain staging"
        }

        return TimedListeningIntent(seconds: seconds, subQuery: subQuery)
    }

    public func handleTimedListeningQuery(
        intent: TimedListeningIntent,
        rawQuery: String,
        uad: UADClient,
        auditor: AIAudioAuditor,
        sampleInterval: Double = 0.1,
        progress: ((String) -> Void)? = nil,
        completion: @escaping (String) -> Void
    ) {
        let duration = intent.seconds
        let totalTicks = max(1, Int(duration / sampleInterval))
        var currentTick = 0

        var channelSummaries: [Int: ChannelSampleSummary] = [:]
        for ch in uad.channels.values {
            channelSummaries[ch.id] = ChannelSampleSummary(id: ch.id, name: ch.name, chType: ch.chType)
        }

        bridgeLog("[AI Chat] Starting timed listening session (\(String(format: "%.1f", duration))s) for query: '\(intent.subQuery)'")

        auditor.mcu?.sendMIDI([0x90, 70, 0x7F])
        auditor.mcu?.sendMIDI([0x90, 83, 0x7F])
        auditor.mcu?.showTempHUD(text: ">>> AI LISTENING (\(Int(duration))s): SAMPLING TELEMETRY <<<", duration: duration)

        let chCount = channelSummaries.count > 0 ? channelSummaries.count : 32
        progress?("🎧 Listening across \(chCount) Apollo channels... (\(Int(duration))s remaining)")

        let queue = DispatchQueue(label: "com.snd.uamcu.timedlistening", qos: .userInitiated)
        let timer = DispatchSource.makeTimerSource(queue: queue)

        queryLock.lock()
        self.timedListenTimer = timer
        self.timedListenCompletion = completion
        self.timedListenAuditor = auditor
        queryLock.unlock()

        timer.schedule(deadline: .now() + sampleInterval, repeating: sampleInterval)
        timer.setEventHandler { [weak self] in
            guard let self = self else {
                timer.cancel()
                return
            }

            self.queryLock.lock()
            let cancelled = self.isQueryCancelled
            self.queryLock.unlock()

            if cancelled {
                timer.cancel()
                self.queryLock.lock()
                self.timedListenTimer = nil
                let comp = self.timedListenCompletion
                self.timedListenCompletion = nil
                self.timedListenAuditor = nil
                self.queryLock.unlock()

                auditor.mcu?.sendMIDI([0x90, 70, 0x00])
                auditor.mcu?.sendMIDI([0x90, 83, 0x00])
                comp?("⏹ *Listening session cancelled.*")
                return
            }

            currentTick += 1

            for ch in uad.channels.values {
                let peak = ch.meterPeak
                let isClip = ch.meterClip
                auditor.recordTelemetry(chId: ch.id, peakDb: peak, isClip: isClip)

                if var s = channelSummaries[ch.id] {
                    s.sampleCount += 1
                    if peak > s.maxPeak { s.maxPeak = peak }
                    if peak > -60.0 {
                        s.activeCount += 1
                        s.sumPeak += peak
                    }
                    if isClip || peak >= 0.0 { s.clipCount += 1 }
                    s.faderDb = ch.faderDb
                    s.pan = ch.pan
                    s.isMuted = ch.mute
                    s.isSoloed = ch.solo
                    channelSummaries[ch.id] = s
                } else {
                    var s = ChannelSampleSummary(id: ch.id, name: ch.name, chType: ch.chType)
                    s.sampleCount = 1
                    s.maxPeak = peak
                    if peak > -60.0 {
                        s.activeCount = 1
                        s.sumPeak = peak
                    }
                    if isClip || peak >= 0.0 { s.clipCount = 1 }
                    s.faderDb = ch.faderDb
                    s.pan = ch.pan
                    s.isMuted = ch.mute
                    s.isSoloed = ch.solo
                    channelSummaries[ch.id] = s
                }
            }

            let ticksPerSec = max(1, Int(1.0 / sampleInterval))
            if currentTick % ticksPerSec == 0 && currentTick < totalTicks {
                let remaining = max(0, Int(duration - (Double(currentTick) * sampleInterval)))
                progress?("🎧 Listening across \(channelSummaries.count) Apollo channels... (\(remaining)s remaining)")
                auditor.mcu?.showTempHUD(text: ">>> AI LISTENING (\(remaining)s REMAINING) <<<", duration: 1.0)
            }

            if currentTick >= totalTicks {
                timer.cancel()
                self.queryLock.lock()
                self.timedListenTimer = nil
                self.timedListenCompletion = nil
                self.timedListenAuditor = nil
                self.queryLock.unlock()

                auditor.mcu?.sendMIDI([0x90, 70, 0x00])
                auditor.mcu?.sendMIDI([0x90, 83, 0x00])
                progress?("💾 Saving \(Int(duration))s telemetry data points & summarizing...")

                self.finalizeTimedListeningSession(
                    duration: duration,
                    subQuery: intent.subQuery,
                    rawQuery: rawQuery,
                    summaries: Array(channelSummaries.values),
                    totalSamples: currentTick,
                    uad: uad,
                    auditor: auditor,
                    completion: completion
                )
            }
        }

        timer.resume()
    }

    private func finalizeTimedListeningSession(
        duration: Double,
        subQuery: String,
        rawQuery: String,
        summaries: [ChannelSampleSummary],
        totalSamples: Int,
        uad: UADClient,
        auditor: AIAudioAuditor,
        completion: @escaping (String) -> Void
    ) {
        let savedReportURL = saveTelemetryCaptureReport(
            duration: duration,
            subQuery: subQuery,
            summaries: summaries,
            totalSamples: totalSamples,
            uad: uad
        )

        let summaryMarkdown = generateTelemetrySummaryMarkdown(
            duration: duration,
            subQuery: subQuery,
            summaries: summaries,
            totalSamples: totalSamples,
            savedReportURL: savedReportURL
        )

        let cleanKey = geminiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentProv = aiProvider.lowercased()
        let prompt = """
        User prompt: "\(rawQuery)"
        The user requested to listen for \(String(format: "%.1f", duration)) seconds and analyze: "\(subQuery)".
        We conducted a real-time 32-channel audio telemetry capture of the Universal Audio Apollo Console over \(String(format: "%.1f", duration)) seconds.
        Here is the recorded telemetry data across monitored tracks:
        \(formatTelemetryForGemini(summaries: summaries))

        Please provide an expert audio engineering assessment answering: "\(subQuery)".
        Provide actionable mixing advice, gain staging recommendations, and reference tactile SSL UF8 controls where relevant.
        """

        if currentProv == "local" {
            queryLocalLLM(prompt: prompt, uad: uad, auditor: auditor) { localReply in
                let combined = summaryMarkdown + "\n\n---\n\n" + localReply
                completion(combined)
            }
        } else if (currentProv == "gemini" || currentProv == "auto") && !cleanKey.isEmpty {
            queryGeminiAPI(prompt: prompt, uad: uad, auditor: auditor) { geminiReply in
                let combined = summaryMarkdown + "\n\n---\n\n🧠 **AI Co-Producer Analysis (Gemini 3.8 Flash):**\n\n" + geminiReply
                completion(combined)
            }
        } else {
            let localAnalysis = generateLocalAcousticAnalysis(subQuery: subQuery, summaries: summaries)
            let combined = summaryMarkdown + "\n\n---\n\n💡 **Co-Producer Mixing Insights ('\(subQuery)'):**\n\n" + localAnalysis
            completion(combined)
        }
    }

    @discardableResult
    public func saveTelemetryCaptureReport(
        duration: Double,
        subQuery: String,
        summaries: [ChannelSampleSummary],
        totalSamples: Int,
        uad: UADClient
    ) -> URL? {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestampStr = formatter.string(from: now)

        let fileFormatter = DateFormatter()
        fileFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let filename = "AI_Telemetry_\(Int(duration))s_\(fileFormatter.string(from: now)).txt"
        let fileURL = AIReportManager.shared.reportsDir.appendingPathComponent(filename)

        let activeChannels = summaries.filter { $0.maxPeak > -60.0 }.sorted(by: { $0.id < $1.id })
        let silentChannels = summaries.filter { $0.maxPeak <= -60.0 }.sorted(by: { $0.id < $1.id })
        var maxSessionPeak: Double = -144.0
        var hottestChannel: String = "None"
        for ch in summaries {
            if ch.maxPeak > maxSessionPeak {
                maxSessionPeak = ch.maxPeak
                hottestChannel = "Ch \(ch.id + 1) [\(ch.name)]"
            }
        }

        var report = ""
        report += "================================================================================\n"
        report += "  UA-MCU BRIDGE - AI STUDIO CO-PRODUCER TELEMETRY CAPTURE\n"
        report += "================================================================================\n"
        report += "Timestamp:         \(timestampStr)\n"
        report += "Sampling Window:   \(String(format: "%.1f", duration)) Seconds (\(totalSamples) Samples Monitored)\n"
        report += "Analysis Request:  \(subQuery)\n"
        report += "Hardware Surface:  Solid State Logic UF8 (8 Motorized Faders)\n"
        report += "Audio Interface:   Universal Audio Apollo Console (32 Channels)\n"
        report += "Engine Status:     Connected | Master Monitor: \(String(format: "%.1f", uad.monitorLevelDb)) dB (Mute=\(uad.monitorMute))\n\n"

        report += "--------------------------------------------------------------------------------\n"
        report += "1. SESSION ACOUSTIC OVERVIEW\n"
        report += "--------------------------------------------------------------------------------\n"
        report += "• Total Channels Monitored:   \(summaries.count)\n"
        report += "• Active Channels Detected:   \(activeChannels.count) tracks (> -60.0 dBFS)\n"
        report += "• Silent / Inactive Channels: \(silentChannels.count) tracks\n"
        report += "• Maximum Session Peak:       \(String(format: "%.1f", maxSessionPeak)) dBFS (\(hottestChannel))\n"
        report += "• Master Headroom Margin:     \(String(format: "%.1f", max(0.0, -maxSessionPeak))) dB\n"
        report += "• Converter Clipping (0 dB):  \(summaries.filter { $0.clipCount > 0 }.count) tracks\n\n"

        report += "--------------------------------------------------------------------------------\n"
        report += "2. MONITORED CHANNEL DATA POINTS (\(Int(duration))-SECOND SAMPLING WINDOW)\n"
        report += "--------------------------------------------------------------------------------\n"
        report += "Ch   | Name            | Type    | Peak dBFS | Avg dBFS  | Active % | Clips | Fader dB | Pan\n"
        report += "-----+-----------------+---------+-----------+-----------+----------+-------+----------+-----\n"

        for ch in summaries.sorted(by: { $0.id < $1.id }) {
            let chNumStr = String(format: "%02d", ch.id + 1)
            let nameStr = Self.padRight(ch.name, 15)
            let typeStr = Self.padRight(ch.chType, 7)
            let peakStr = ch.maxPeak <= -140.0 ? "  -oo  " : String(format: "%6.1f ", ch.maxPeak)
            let avgStr = ch.avgPeak <= -140.0 ? "  -oo  " : String(format: "%6.1f ", ch.avgPeak)
            let actStr = String(format: "%3d%%  ", Int(ch.activityPercent))
            let clipStr = String(format: "%3d  ", ch.clipCount)
            let faderStr = ch.faderDb <= -140.0 ? "  -oo  " : String(format: "%6.1f ", ch.faderDb)
            let panStr = ch.pan == 0 ? "  C " : (ch.pan < 0 ? String(format: "L%2d", Int(-ch.pan * 100)) : String(format: "R%2d", Int(ch.pan * 100)))

            report += "\(chNumStr)   | \(nameStr) | \(typeStr) |  \(peakStr) |  \(avgStr) |  \(actStr) | \(clipStr) |  \(faderStr) | \(panStr)\n"
        }

        report += "\n================================================================================\n"

        try? report.write(to: fileURL, atomically: true, encoding: .utf8)
        AIReportManager.shared.activeReportURL = fileURL
        return fileURL
    }

    private func generateTelemetrySummaryMarkdown(
        duration: Double,
        subQuery: String,
        summaries: [ChannelSampleSummary],
        totalSamples: Int,
        savedReportURL: URL?
    ) -> String {
        let activeChannels = summaries.filter { $0.maxPeak > -60.0 }.sorted(by: { $0.id < $1.id })
        let silentChannels = summaries.filter { $0.maxPeak <= -60.0 }.sorted(by: { $0.id < $1.id })
        var maxSessionPeak: Double = -144.0
        var hottestChannel: String = "None"
        for ch in summaries {
            if ch.maxPeak > maxSessionPeak {
                maxSessionPeak = ch.maxPeak
                hottestChannel = "Ch \(ch.id + 1) [\(ch.name)]"
            }
        }

        var summary = "⏱ **\(Int(duration))-Second Mixer Telemetry Capture & Analysis**\n"
        summary += "*Sampled \(totalSamples) telemetry data points across \(summaries.count) Apollo channels over \(String(format: "%.1f", duration))s.*\n"
        if let reportURL = savedReportURL {
            summary += "📁 *Saved session report: `\(reportURL.lastPathComponent)`*\n\n"
        } else {
            summary += "\n"
        }

        summary += "📊 **Session Acoustic Summary:**\n"
        summary += "• **Active Channels:** \(activeChannels.count) / \(summaries.count) tracks received audio signal (> -60 dBFS)\n"
        summary += "• **Silent / Dead Inputs:** \(silentChannels.count) channels remained silent throughout\n"
        summary += "• **Session Peak:** \(String(format: "%.1f", maxSessionPeak)) dBFS on \(hottestChannel)\n"
        summary += "• **Available Headroom:** +\(String(format: "%.1f", max(0.0, -maxSessionPeak))) dBFS margin below digital 0 dBFS\n"

        let clippedChannels = summaries.filter { $0.clipCount > 0 }
        if clippedChannels.isEmpty {
            summary += "• **Converter Clipping:** 0 channels clipped (Clean digital headroom)\n\n"
        } else {
            let clipNames = clippedChannels.map { "Ch \($0.id + 1) [\($0.name)] (\($0.clipCount) clips)" }.joined(separator: ", ")
            summary += "• **⚠️ Clipping / Overload:** \(clippedChannels.count) channels clipped: \(clipNames)\n\n"
        }

        if !activeChannels.isEmpty {
            summary += "🎚 **Active Channel Dynamics (\(Int(duration))-Second Window):**\n"
            for ch in activeChannels {
                let dynStr = String(format: "%.1f", max(0.0, ch.maxPeak - ch.avgPeak))
                var badge = "Healthy"
                if ch.clipCount > 0 {
                    badge = "⚠️ Clipping"
                } else if ch.maxPeak > -3.0 {
                    badge = "⚠️ Hot (<3 dB Headroom)"
                } else if ch.maxPeak < -24.0 {
                    badge = "Low Level"
                }
                summary += "• **Track \(ch.id + 1) [\(ch.name)]:** Peak: \(String(format: "%.1f", ch.maxPeak)) dBFS | Avg: \(String(format: "%.1f", ch.avgPeak)) dBFS | Activity: \(Int(ch.activityPercent))% | Dynamics: \(dynStr) dB | \(badge)\n"
            }
            summary += "\n"
        }

        if !silentChannels.isEmpty {
            summary += "🔇 **Silent Channels Detected:**\n"
            let silentNames = silentChannels.map { "Ch \($0.id + 1) (\($0.name))" }.prefix(8).joined(separator: ", ")
            let remainder = silentChannels.count > 8 ? " and \(silentChannels.count - 8) others" : ""
            summary += "Tracks \(silentNames)\(remainder) had zero signal (< -60 dBFS) during the \(Int(duration))-second capture.\n"
        }

        return summary
    }

    private func generateLocalAcousticAnalysis(subQuery: String, summaries: [ChannelSampleSummary]) -> String {
        let activeChannels = summaries.filter { $0.maxPeak > -60.0 }.sorted(by: { $0.id < $1.id })
        let clippedChannels = summaries.filter { $0.clipCount > 0 }
        let hotChannels = summaries.filter { $0.maxPeak > -3.0 }
        let lowChannels = activeChannels.filter { $0.maxPeak < -24.0 }
        let lowerQuery = subQuery.lowercased()

        var lines: [String] = []

        if !clippedChannels.isEmpty {
            lines.append("• **⚠️ Clipping Danger:** \(clippedChannels.count) track(s) redlined into 0 dBFS during the session (\(clippedChannels.map { "Ch \($0.id + 1) [\($0.name)]" }.joined(separator: ", "))). Lower preamp input gain or channel trim by 4–6 dB immediately to avoid digital converter distortion.")
        } else if !hotChannels.isEmpty {
            lines.append("• **⚠️ Hot Gain Staging:** \(hotChannels.map { "Ch \($0.id + 1) [\($0.name)] (\(String(format: "%.1f", $0.maxPeak)) dBFS)" }.joined(separator: ", ")) peaked above -3 dBFS. Target -12 to -14 dBFS peak for optimal analog warmth without saturating DSP converters.")
        } else if !activeChannels.isEmpty {
            lines.append("• **✅ Healthy Converter Headroom:** All active signals remained well below digital clipping with generous headroom.")
        }

        if !lowChannels.isEmpty {
            lines.append("• **📈 Low Level Tracks:** \(lowChannels.map { "Ch \($0.id + 1) [\($0.name)] (\(String(format: "%.1f", $0.maxPeak)) dBFS)" }.joined(separator: ", ")) are tracking low. Consider boosting preamp gain (+10 to +65 dB on UF8 CHANNEL mode) to maximize signal-to-noise ratio.")
        }

        if lowerQuery.contains("drum") || lowerQuery.contains("snare") || lowerQuery.contains("kick") {
            let drumTracks = activeChannels.filter {
                let n = $0.name.lowercased()
                return n.contains("kick") || n.contains("kd") || n.contains("snare") || n.contains("sd") || n.contains("tom") || n.contains("oh") || n.contains("hat")
            }
            if !drumTracks.isEmpty {
                lines.append("• **🥁 Rhythm Section Dynamics:** Analyzed \(drumTracks.count) drum tracks. Ensure Kick & Snare are anchored at -14 to -12 dBFS peak, with Overheads sitting 4–6 dB beneath to maintain punch.")
            }
        }

        if lowerQuery.contains("vocal") || lowerQuery.contains("vox") {
            let vocTracks = activeChannels.filter {
                let n = $0.name.lowercased()
                return n.contains("vox") || n.contains("vocal") || n.contains("mic") || n.contains("lead")
            }
            if !vocTracks.isEmpty {
                lines.append("• **🎙️ Vocal Presence:** Vocal track(s) (\(vocTracks.map { $0.name }.joined(separator: ", "))) peak at \(vocTracks.map { String(format: "%.1f dBFS", $0.maxPeak) }.joined(separator: ", ")). Place lead vocals at -10 to -12 dBFS with a 75 Hz analog low cut (UF8 CHANNEL mode Strip 4) to eliminate low rumble.")
            }
        }

        lines.append("• **🎛️ SSL UF8 Fader Action:** Press AUTO + SEL on any track to snap to 0.0 dB Unity Gain, or tap FINE to trigger the 3-step automatic rough mix balancing.")

        return lines.joined(separator: "\n")
    }

    private func formatTelemetryForGemini(summaries: [ChannelSampleSummary]) -> String {
        return summaries.sorted(by: { $0.id < $1.id }).map { s in
            let peakStr = s.maxPeak <= -140.0 ? "-oo" : String(format: "%.1f", s.maxPeak)
            let avgStr = s.avgPeak <= -140.0 ? "-oo" : String(format: "%.1f", s.avgPeak)
            let faderStr = s.faderDb <= -140.0 ? "-oo" : String(format: "%.1f", s.faderDb)
            return "Ch \(s.id + 1) (\(s.name) [\(s.chType)]): MaxPeak: \(peakStr) dBFS, AvgPeak: \(avgStr) dBFS, Activity: \(Int(s.activityPercent))%, Clips: \(s.clipCount), Fader: \(faderStr) dB, Pan: \(s.pan == 0 ? "C" : (s.pan < 0 ? "L" : "R")), Muted: \(s.isMuted), Soloed: \(s.isSoloed)"
        }.joined(separator: "\n")
    }

    private static func padRight(_ text: String, _ width: Int) -> String {
        if text.count >= width {
            return String(text.prefix(width))
        }
        return text + String(repeating: " ", count: width - text.count)
    }

    // MARK: - Intent Handlers

    public static func isPromptExamplesQuery(_ lower: String) -> Bool {
        let trimmed = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "help" || trimmed == "prompts" || trimmed == "prompt examples" ||
           trimmed == "example prompts" || trimmed == "commands" || trimmed == "command guide" ||
           trimmed == "prompt guide" || trimmed == "show help" || trimmed == "help page" ||
           trimmed == "show prompt examples" || trimmed == "prompt examples help" {
            return true
        }
        if (trimmed.contains("prompt") || trimmed.contains("command") || trimmed.contains("help")) &&
           (trimmed.contains("example") || trimmed.contains("guide") || trimmed.contains("list")) {
            return true
        }
        return false
    }

    public static func isOverloadQuery(_ text: String) -> Bool {
        return text.contains("overload") || text.contains("clipping") || text.contains("clipped") || text.contains("hot channel") || text.contains("distort") || text.contains("peaking") || text.contains("redline") || text.contains("red-line")
    }

    private func handleOverloadQuery(uad: UADClient, auditor: AIAudioAuditor) -> String {
        var clippingChannels: [(name: String, peak: Double)] = []

        for ch in uad.channels.values.sorted(by: { $0.id < $1.id }) {
            if ch.meterClip || ch.meterPeak >= -0.1 {
                clippingChannels.append((ch.name, ch.meterPeak))
            }
        }

        if clippingChannels.isEmpty {
            return "✅ No channels are currently in Overload. All active channels have clean headroom below 0 dBFS."
        }

        let names = clippingChannels.map { "\($0.name) (\(String(format: "%.1f", $0.peak)) dBFS)" }.joined(separator: ", ")
        return "⚠️ Overloaded Channels Detected (\(clippingChannels.count)):\n\(names)\n\nRecommendation: Lower preamp gain or trim faders to preserve at least 14 dB converter headroom."
    }

    public static func isSetAllInfinityQuery(_ text: String) -> Bool {
        let hasAll = text.contains("all") || text.contains("every")
        let hasInf = text.contains("-infinite") || text.contains("-inf") || text.contains("infinity") || text.contains("zero fader") || text.contains("down") || text.contains("kill fader")
        return hasAll && hasInf
    }

    private func handleSetAllInfinity(uad: UADClient) -> String {
        history.takeSnapshot(uad: uad, description: "Set all channel faders to -infinity dB")
        let count = uad.channels.count
        for ch in uad.channels.values {
            uad.setFader(chId: ch.id, tapered: 0.0)
        }
        return "🎚️ Set all \(count) channels to -infinity dB (-oo dB). Use 'undo' or 'go back 1 step' to restore fader positions."
    }

    public static func isUndoQuery(_ text: String) -> Bool {
        return text.contains("undo") || text.contains("-1 step") || text.contains("1 step back") || text.contains("step back") || text.contains("go back") || text.contains("revert")
    }

    public static func isRedoQuery(_ text: String) -> Bool {
        return text == "redo" || text.contains("step forward") || text.contains("redo last")
    }

    // MARK: - Local CUE & Sends Information Engine (Instant 0ms, Zero Network Latency)

    public static func isCueQuery(_ lower: String) -> Bool {
        if lower.contains("how to use sends mode") || lower.contains("how does sends mode work") || lower.contains("sends mode guide") || lower.contains("sends focus mode guide") || (lower.contains("sends mode") && lower.contains("guide")) {
            return false
        }
        let hasCue = lower.contains("cue") || lower.contains("cues") || lower.contains("c1") || lower.contains("c2") || lower.contains("c3") || lower.contains("c4")
        let hasHeadphone = lower.contains("headphone") || lower.contains("hp 1") || lower.contains("hp 2") || lower.contains("hp sends") || lower.contains("hp mix")
        let hasSendWord = lower.contains("send") || lower.contains("sends")
        let hasActionOrInfo = lower.contains("info") || lower.contains("show") || lower.contains("list") || lower.contains("level") || lower.contains("what") || lower.contains("status") || lower.contains("matrix") || lower.contains("which") || lower.contains("mix") || lower.contains("set") || lower.contains("mute") || lower.contains("unmute") || lower.contains("for") || lower.contains("on")
        return hasCue || hasHeadphone || (hasSendWord && hasActionOrInfo)
    }

    private func getSendLabels(auditor: AIAudioAuditor) -> [String] {
        if let labels = auditor.mcu?.sendLabels, labels.count >= 6 {
            return labels
        }
        return ["AUX 1", "AUX 2", "HP 1", "HP 2", "CUE 3", "CUE 4", "OUTPUT", "PAN"]
    }

    private func detectSendIndex(_ lower: String, labels: [String]) -> (index: Int, label: String)? {
        if lower.contains("c2") || lower.contains("cue 2") || lower.contains("hp 2") || lower.contains("headphone 2") {
            let label = labels.count > 3 ? labels[3] : "HP 2"
            return (3, "C2 (\(label))")
        } else if lower.contains("c1") || lower.contains("cue 1") || lower.contains("hp 1") || lower.contains("headphone 1") {
            let label = labels.count > 2 ? labels[2] : "HP 1"
            return (2, "C1 (\(label))")
        } else if lower.contains("c3") || lower.contains("cue 3") {
            let label = labels.count > 4 ? labels[4] : "CUE 3"
            return (4, "CUE 3 (\(label))")
        } else if lower.contains("c4") || lower.contains("cue 4") {
            let label = labels.count > 5 ? labels[5] : "CUE 4"
            return (5, "CUE 4 (\(label))")
        } else if lower.contains("a1") || lower.contains("aux 1") {
            let label = labels.count > 0 ? labels[0] : "AUX 1"
            return (0, "AUX 1 (\(label))")
        } else if lower.contains("a2") || lower.contains("aux 2") {
            let label = labels.count > 1 ? labels[1] : "AUX 2"
            return (1, "AUX 2 (\(label))")
        }
        return nil
    }

    private func handleCueQuery(_ lower: String, rawQuery: String, uad: UADClient, auditor: AIAudioAuditor) -> String? {
        let labels = getSendLabels(auditor: auditor)

        // 1. Send Mute / Unmute Command (e.g. "mute C2 level for System out", "unmute C1 on Logic", "mute cue 1 on track 1")
        let isMute = lower.contains("mute") && !lower.contains("unmute")
        let isUnmute = lower.contains("unmute")
        if (isMute || isUnmute), let sendInfo = detectSendIndex(lower, labels: labels) {
            var matchedCh = Self.findChannel(in: uad, text: lower)
            if matchedCh == nil {
                for ch in uad.channels.values {
                    let chNameLower = ch.name.lowercased()
                    let baseName = chNameLower.replacingOccurrences(of: "-st", with: "").trimmingCharacters(in: .whitespaces)
                    if lower.contains(chNameLower) || lower.contains(baseName) {
                        matchedCh = ch
                        break
                    }
                }
            }
            guard let ch = matchedCh else {
                return "Found \(sendInfo.label), but could not identify the target track name in: \"\(rawQuery)\". Available tracks: " + uad.channels.values.prefix(8).map { $0.name }.joined(separator: ", ")
            }
            let bypass = isMute
            history.takeSnapshot(uad: uad, description: "\(bypass ? "Muted" : "Unmuted") \(sendInfo.label) on \(ch.name)")
            uad.setSendBypass(chId: ch.id, sendIdx: sendInfo.index, bypass: bypass)
            auditor.mcu?.refreshSendsFocusSurface()
            return "\(bypass ? "🔇 Muted" : "🔊 Unmuted") \(sendInfo.label) on channel '\(ch.name)'."
        }

        // 2. Send Gain / Level Command (e.g. "set cue 1 on track 1 to 0 dB", "cue 2 vocal to -6 dB", "set hp 1 on kick to -inf")
        if (lower.contains("set") || lower.contains("level") || lower.contains("to") || lower.contains("db")),
           let sendInfo = detectSendIndex(lower, labels: labels),
           let ch = Self.findChannel(in: uad, text: lower) {
            var targetDb: Double? = nil
            if lower.contains("unity") || lower.contains("0 db") || lower.contains("0db") || lower.contains("zero db") {
                targetDb = 0.0
            } else if lower.contains("-oo") || lower.contains("-inf") || lower.contains("minimum") || lower.contains("floor") {
                targetDb = -144.0
            } else {
                let dbPattern = #"(?:to|=|\sat)\s*(-?\d+(?:\.\d+)?)\s*(?:db)?"#
                if let regex = try? NSRegularExpression(pattern: dbPattern, options: .caseInsensitive),
                   let match = regex.firstMatch(in: lower, options: [], range: NSRange(lower.startIndex..., in: lower)),
                   let numRange = Range(match.range(at: 1), in: lower),
                   let val = Double(lower[numRange]) {
                    targetDb = max(-144.0, min(12.0, val))
                }
            }
            if let db = targetDb {
                history.takeSnapshot(uad: uad, description: "Set \(sendInfo.label) on \(ch.name) to \(db) dB")
                let tap = UADCurve.dbToTapered(db)
                uad.setSendGain(chId: ch.id, sendIdx: sendInfo.index, value: tap)
                auditor.mcu?.refreshSendsFocusSurface()
                let displayDb = db <= -100.0 ? "-oo dB" : String(format: "%.1f dB", db)
                return "🎚️ Set **\(sendInfo.label)** send on Track \(ch.id + 1) (**\(ch.name)**) to **\(displayDb)**."
            }
        }

        // 3. Track-specific CUE & SENDS inspection (e.g. "cue sends for vocal", "cues on track 1", "sends for kick", "cue info vocal")
        let hasExplicitTrackRef = lower.contains("track") || lower.contains("channel") || lower.contains("ch ") || lower.contains("for ") || lower.contains("on ") || lower.contains("vox") || lower.contains("vocal") || lower.contains("gtr") || lower.contains("guitar") || lower.contains("kick") || lower.contains("snare") || lower.contains("bass")
        if hasExplicitTrackRef, let ch = Self.findChannel(in: uad, text: lower), (lower.contains("cue") || lower.contains("send") || lower.contains("hp") || lower.contains("headphone")) {
            var lines: [String] = []
            lines.append("🎧 **CUE & SENDS Matrix for Track \(ch.id + 1) (\(ch.name)):**")
            lines.append("")
            let slotNames = [
                ("Slot 1 (AUX 1)", labels.count > 0 ? labels[0] : "AUX 1", 0),
                ("Slot 2 (AUX 2)", labels.count > 1 ? labels[1] : "AUX 2", 1),
                ("Slot 3 (CUE 1)", labels.count > 2 ? labels[2] : "HP 1", 2),
                ("Slot 4 (CUE 2)", labels.count > 3 ? labels[3] : "HP 2", 3),
                ("Slot 5 (CUE 3)", labels.count > 4 ? labels[4] : "CUE 3", 4),
                ("Slot 6 (CUE 4)", labels.count > 5 ? labels[5] : "CUE 4", 5)
            ]
            for (slotHdr, busName, sIdx) in slotNames {
                let send = ch.sends[sIdx]
                let gainDb = send?.gainDb ?? -144.0
                let levelStr = gainDb <= -100.0 ? "-oo dB" : String(format: "%+.1f dB", gainDb)
                let pan = send?.pan ?? 0.0
                let panStr = abs(pan) < 0.03 ? "C" : (pan < 0 ? "L\(Int(abs(pan) * 100))" : "R\(Int(pan * 100))")
                let byp = send?.bypass ?? false
                let statusStr = byp ? "🔇 Muted" : "🟢 Active"
                lines.append("• **\(slotHdr) — \(busName):** \(levelStr) | Pan: \(panStr) | \(statusStr)")
            }
            let outDb = ch.faderDb <= -100.0 ? "-oo dB" : String(format: "%+.1f dB", ch.faderDb)
            let effPan = uad.getEffectivePan(chId: ch.id)
            let outPanStr = abs(effPan) < 0.03 ? "Center" : (effPan < 0 ? "L\(Int(abs(effPan) * 100))" : "R\(Int(effPan * 100))")
            lines.append("• **Slot 7 (Track Output):** \(outDb) | \(ch.mute ? "🔇 Muted" : "🔊 Active")")
            lines.append("• **Slot 8 (Track Pan):** \(outPanStr)")
            lines.append("")
            lines.append("💡 **SSL UF8 Tactile Control:** Double-tap **SEL** on Track \(ch.id + 1) or press **SEND** (`Note 41`) to expand these 8 sends directly across your motorized faders. Tap **FLIP** to return to Main Mix.")
            return lines.joined(separator: "\n")
        }

        // 4. Specific CUE Bus query across all channels (e.g. "show cue 1", "cue 1 levels", "cue 2 sends", "headphone 1 mix", "who is routed to cue 2")
        if let sendInfo = detectSendIndex(lower, labels: labels) {
            let sortedChs = uad.channels.values.sorted { $0.id < $1.id }
            var activeFeeds: [String] = []
            var totalDb: Double = 0.0
            var countActive = 0
            var mutedCount = 0

            for ch in sortedChs {
                let send = ch.sends[sendInfo.index]
                let gainDb = send?.gainDb ?? -144.0
                let byp = send?.bypass ?? false
                if byp { mutedCount += 1 }
                if gainDb > -100.0 || (send?.gain ?? 0.0) > 0.001 {
                    countActive += 1
                    totalDb += gainDb
                    let levelStr = String(format: "%+.1f dB", gainDb)
                    let pan = send?.pan ?? 0.0
                    let panStr = abs(pan) < 0.03 ? "Center" : (pan < 0 ? "L\(Int(abs(pan) * 100))" : "R\(Int(pan * 100))")
                    let status = byp ? "🔇 Muted" : "🟢 Active"
                    activeFeeds.append("• **Track \(ch.id + 1) (\(ch.name)):** \(levelStr) | Pan: \(panStr) | \(status)")
                }
            }

            var lines: [String] = []
            lines.append("🎧 **\(sendInfo.label) Send Levels Across Apollo Channels:**")
            lines.append("")
            if activeFeeds.isEmpty {
                lines.append("All 32 channels currently have \(sendInfo.label) set to **-oo dB (inactive)**.")
            } else {
                lines.append(contentsOf: activeFeeds)
                lines.append("")
                let avg = totalDb / Double(max(1, countActive))
                lines.append("📊 **Bus Summary:** \(countActive) active tracks feeding \(sendInfo.label) (Average send level: \(String(format: "%.1f", avg)) dB\(mutedCount > 0 ? ", \(mutedCount) muted" : "")).")
            }
            lines.append("")
            lines.append("💡 **UF8 Tip:** Press **SEND** (`Note 41`) or double-tap **SEL** on any track to adjust its \(sendInfo.label) send on Strip \(sendInfo.index + 1) fader.")
            return lines.joined(separator: "\n")
        }

        // 5. Global Session CUE & SENDS Matrix (e.g. "show cue sends", "cue information", "cue status", "what are the cue levels", "cue mix", "list cues", "show cues", "headphone sends")
        let sortedChs = uad.channels.values.sorted { $0.id < $1.id }
        let busDefs = [
            ("CUE 1 / HP 1", labels.count > 2 ? labels[2] : "HP 1", 2),
            ("CUE 2 / HP 2", labels.count > 3 ? labels[3] : "HP 2", 3),
            ("CUE 3", labels.count > 4 ? labels[4] : "CUE 3", 4),
            ("CUE 4", labels.count > 5 ? labels[5] : "CUE 4", 5),
            ("AUX 1", labels.count > 0 ? labels[0] : "AUX 1", 0),
            ("AUX 2", labels.count > 1 ? labels[1] : "AUX 2", 1)
        ]

        var lines: [String] = []
        lines.append("🎧 **Apollo CUE & SENDS Matrix (Local 0ms Telemetry):**")
        lines.append("")

        for (busTitle, customLabel, sIdx) in busDefs {
            var activeTracks: [String] = []
            var mutedTracks: [String] = []
            for ch in sortedChs {
                let send = ch.sends[sIdx]
                let gainDb = send?.gainDb ?? -144.0
                let byp = send?.bypass ?? false
                if byp { mutedTracks.append(ch.name) }
                if gainDb > -100.0 || (send?.gain ?? 0.0) > 0.001 {
                    let lvl = String(format: "%+.1f dB", gainDb)
                    activeTracks.append("\(ch.name) (\(lvl))")
                }
            }
            let activeDesc = activeTracks.isEmpty ? "All tracks at -oo dB" : activeTracks.prefix(4).joined(separator: ", ") + (activeTracks.count > 4 ? " +\(activeTracks.count - 4) more" : "")
            lines.append("• **\(busTitle)** [Label: *\(customLabel)*]:")
            lines.append("  - Routing: \(activeDesc)")
            if !mutedTracks.isEmpty {
                lines.append("  - Muted: \(mutedTracks.joined(separator: ", "))")
            }
        }

        lines.append("")
        lines.append("💡 **SSL UF8 Tactile SENDS on Faders:**")
        lines.append("• Press **`SEND`** (`Note 41`) or double-tap **`SEL`** on any track to flip its 6 sends + Output + Pan across the 8 motorized faders.")
        lines.append("• Step between channels with **`< BANK >`** or Master Jog Wheel without leaving Sends mode.")
        lines.append("• Single-tap **`FLIP`** (`Note 50`) returns to Main Mix at current bank; double-tap snaps to Ch 1–8.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Local UAD Plug-ins & Inserts Information Engine (Instant 0ms, Zero Network Latency)

    public static func isPluginQuery(_ lower: String) -> Bool {
        if lower.contains("how to tweak plugins") || lower.contains("how does plugin mode work") || lower.contains("how to use plugin mode") || lower.contains("plugin mode guide") || lower.contains("plug-in mode guide") || lower.contains("tweak plugin") {
            return false
        }
        let hasPlugin = lower.contains("plugin") || lower.contains("plugins") || lower.contains("plug-in") || lower.contains("plug-ins")
        let hasInsert = lower.contains("insert") || lower.contains("inserts")
        let hasUnison = lower.contains("unison")
        let hasDsp = lower.contains("dsp")
        let hasParamWord = lower.contains("parameter") || lower.contains("param") || lower.contains("ratio") || lower.contains("threshold") || lower.contains("attack") || lower.contains("release") || lower.contains("peak reduction") || lower.contains("reduction") || (lower.contains("gain") && (lower.contains("plugin") || lower.contains("plug-in") || lower.contains("insert") || lower.contains("slot") || lower.contains("la-2a") || lower.contains("1176") || lower.contains("eq") || lower.contains("compressor") || lower.contains("unison"))) || (lower.contains("setting") && (lower.contains("plugin") || lower.contains("track") || lower.contains("vocal") || lower.contains("channel") || lower.contains("kick")))
        let hasCompressorOrEq = lower.contains("compressor") || lower.contains("eq") || lower.contains("la-2a") || lower.contains("la2a") || lower.contains("1176") || lower.contains("fairchild") || lower.contains("pultec") || lower.contains("neve")
        return hasPlugin || hasInsert || hasUnison || hasDsp || hasParamWord || hasCompressorOrEq
    }

    private func handlePluginQuery(_ lower: String, rawQuery: String, uad: UADClient, auditor: AIAudioAuditor) -> String? {
        let sortedChs = uad.channels.values.sorted { $0.id < $1.id }

        let isPowerToggle = lower.contains("bypass") || lower.contains("unbypass") || lower.contains("enable") || lower.contains("disable") || lower.contains("turn on") || lower.contains("turn off") || lower.contains("toggle")

        // 1. Channel-wide Plugin Power: "bypass all plugins on track 1", "turn off plugins on vocal", "enable plugins on snare"
        if isPowerToggle, let ch = Self.findChannel(in: uad, text: lower), (lower.contains("all plugins") || lower.contains("all inserts") || lower.contains("plugins on") || lower.contains("all plug-ins") || (lower.contains("plugins") && !lower.contains("show") && !lower.contains("what") && !lower.contains("list") && !lower.contains("which") && !lower.contains("info") && !lower.contains("insert ") && !lower.contains("slot "))) {
            let actualPowerOn = lower.contains("enable") || lower.contains("turn on") || lower.contains("unbypass") || lower.contains("activate")
            history.takeSnapshot(uad: uad, description: "\(actualPowerOn ? "Enable" : "Bypass") all plug-ins on \(ch.name)")
            var count = 0
            if ch.preamp.hasPreamp && !ch.unisonEffect.name.isEmpty {
                uad.setEffectPower(chId: ch.id, eff: ch.unisonEffect, power: actualPowerOn)
                ch.preamp.unisonPower = actualPowerOn
                count += 1
            }
            for s in 0..<6 {
                if let eff = ch.effects[s], !eff.name.isEmpty && eff.name != "None" {
                    uad.setEffectPower(chId: ch.id, eff: eff, power: actualPowerOn)
                    count += 1
                }
            }
            auditor.mcu?.refreshPluginFocusSurface()
            auditor.mcu?.refreshPreampFocusSurface()
            return "\(actualPowerOn ? "🟢 **Enabled All Plug-ins**" : "⚪ **Bypassed All Plug-ins**") on Track \(ch.id + 1) (**\(ch.name)**) (\(count) plug-in\(count == 1 ? "" : "s") \(actualPowerOn ? "activated" : "disabled"))."
        }

        // 2. Global Plugin Power: "bypass all plugins", "turn off all plugins", "enable all plugins", "turn on all plugins"
        if isPowerToggle && (lower.contains("all plugins") || lower.contains("plugins on all") || (lower.contains("all") && lower.contains("plugin"))) {
            let actualPowerOn = lower.contains("enable") || lower.contains("turn on") || lower.contains("unbypass") || lower.contains("activate")
            history.takeSnapshot(uad: uad, description: "\(actualPowerOn ? "Enable" : "Bypass") all plug-ins across console")
            var count = 0
            for ch in sortedChs {
                if ch.preamp.hasPreamp && !ch.unisonEffect.name.isEmpty {
                    uad.setEffectPower(chId: ch.id, eff: ch.unisonEffect, power: actualPowerOn)
                    ch.preamp.unisonPower = actualPowerOn
                    count += 1
                }
                for s in 0..<6 {
                    if let eff = ch.effects[s], !eff.name.isEmpty && eff.name != "None" {
                        uad.setEffectPower(chId: ch.id, eff: eff, power: actualPowerOn)
                        count += 1
                    }
                }
            }
            auditor.mcu?.refreshPluginFocusSurface()
            auditor.mcu?.refreshPreampFocusSurface()
            return "\(actualPowerOn ? "🟢 **Enabled All Plug-ins**" : "⚪ **Bypassed All Plug-ins**"): \(actualPowerOn ? "Activated" : "Disabled") \(count) plug-ins across all 32 Apollo Console channels."
        }

        // 3. Per-Slot Across All Channels: "turn off insert 1 on all channels", "bypass insert 2 across all tracks"
        if isPowerToggle && (lower.contains("all channels") || lower.contains("all tracks") || lower.contains("across all")) {
            for i in 1...6 {
                if lower.contains("insert \(i)") || lower.contains("ins \(i)") || lower.contains("slot \(i)") {
                    let sIdx = i - 1
                    let actualPowerOn = lower.contains("enable") || lower.contains("turn on") || lower.contains("unbypass") || lower.contains("activate")
                    history.takeSnapshot(uad: uad, description: "\(actualPowerOn ? "Enable" : "Bypass") Insert \(i) across all channels")
                    var count = 0
                    for ch in sortedChs {
                        if let eff = ch.effects[sIdx], !eff.name.isEmpty && eff.name != "None" {
                            uad.setEffectPower(chId: ch.id, eff: eff, power: actualPowerOn)
                            count += 1
                        }
                    }
                    auditor.mcu?.refreshPluginFocusSurface()
                    return "\(actualPowerOn ? "🟢 **Enabled Insert \(i)**" : "⚪ **Bypassed Insert \(i)**") across all channels (\(count) active instances updated)."
                }
            }
        }

        // 4. Single Plugin Power Control (Track + Slot OR Track + Plugin Name)
        if isPowerToggle, let ch = Self.findChannel(in: uad, text: lower) {
            let actualPowerOn = lower.contains("enable") || lower.contains("turn on") || lower.contains("unbypass") || lower.contains("activate") || (lower.contains("toggle") && !ch.unisonEffect.power)

            if lower.contains("unison") {
                if !ch.preamp.hasPreamp {
                    return "⚠️ Track \(ch.id + 1) (\(ch.name)) does not have an analog hardware preamp (Unison not supported on Line/Aux channels)."
                }
                let uniName = !ch.unisonEffect.name.isEmpty ? ch.unisonEffect.name : (!ch.preamp.unisonPluginName.isEmpty ? ch.preamp.unisonPluginName : "Unison Preamp")
                history.takeSnapshot(uad: uad, description: "\(actualPowerOn ? "Enabled" : "Bypassed") Unison on \(ch.name)")
                uad.setEffectPower(chId: ch.id, eff: ch.unisonEffect, power: actualPowerOn)
                ch.preamp.unisonPower = actualPowerOn
                auditor.mcu?.refreshPluginFocusSurface()
                auditor.mcu?.refreshPreampFocusSurface()
                return "\(actualPowerOn ? "🟢 Enabled" : "⚪ Bypassed") Unison modeling plug-in (**\(uniName)**) on Track \(ch.id + 1) (**\(ch.name)**)."
            }

            // Check if specific insert index is requested (insert 1..6)
            var targetSlot: Int? = nil
            for i in 1...6 {
                if lower.contains("insert \(i)") || lower.contains("ins \(i)") || lower.contains("slot \(i)") {
                    targetSlot = i - 1
                    break
                }
            }

            // If not found by slot number, check if a plugin is referenced by name
            if targetSlot == nil {
                for s in 0..<6 {
                    if let eff = ch.effects[s], !eff.name.isEmpty {
                        let effLow = eff.name.lowercased()
                        if lower.contains(effLow) ||
                           (lower.contains("la-2a") || lower.contains("la2a")) && effLow.contains("la-2a") ||
                           lower.contains("1176") && effLow.contains("1176") ||
                           lower.contains("fairchild") && effLow.contains("fairchild") ||
                           lower.contains("pultec") && effLow.contains("pultec") ||
                           lower.contains("neve") && effLow.contains("neve") ||
                           lower.contains("eq") && effLow.contains("eq") ||
                           lower.contains("compressor") && (effLow.contains("1176") || effLow.contains("la-2a") || effLow.contains("fairchild") || effLow.contains("compressor")) {
                            targetSlot = s
                            break
                        }
                    }
                }
            }

            let slotIdx = targetSlot ?? 0
            if let eff = ch.effects[slotIdx] {
                let effName = eff.name.isEmpty ? "Insert \(slotIdx + 1)" : eff.name
                let newPow = lower.contains("toggle") ? !eff.power : actualPowerOn
                history.takeSnapshot(uad: uad, description: "\(newPow ? "Enabled" : "Bypassed") \(effName) on \(ch.name)")
                uad.setEffectPower(chId: ch.id, eff: eff, power: newPow)
                auditor.mcu?.refreshPluginFocusSurface()
                return "\(newPow ? "🟢 Enabled" : "⚪ Bypassed") Insert \(slotIdx + 1) (**\(effName)**) on Track \(ch.id + 1) (**\(ch.name)**)."
            }
        }

        // 5. Direct Plugin Parameter & Setting Control:
        // e.g. "set ratio to 4:1 on vocal", "set threshold to -18 dB on track 1", "set attack to 3 on vocal", "set release to 5 on kick",
        //      "set peak reduction to 60 on vocal", "set gain to 35 on unison track 1", "set parameter 2 on track 1 to 0.75"
        let isSettingChange = lower.contains("set") || lower.contains("change") || lower.contains("adjust") || lower.contains("tweak") || lower.contains("tune")
        let hasParamWord = lower.contains("ratio") || lower.contains("threshold") || lower.contains("attack") || lower.contains("release") || lower.contains("peak reduction") || lower.contains("reduction") || lower.contains("gain") || lower.contains("mix") || lower.contains("freq") || lower.contains("parameter") || lower.contains("param") || lower.contains("p1") || lower.contains("p2") || lower.contains("input") || lower.contains("output") || lower.contains("recovery")
        if isSettingChange && hasParamWord, let ch = Self.findChannel(in: uad, text: lower) {
            return handlePluginParameterChange(lower: lower, rawQuery: rawQuery, channel: ch, uad: uad, auditor: auditor)
        }

        // 6. Reset Plugin Settings: "reset plugin settings on track 1", "reset plugins on vocal"
        if lower.contains("reset") && (lower.contains("plugin") || lower.contains("setting") || lower.contains("parameter")), let ch = Self.findChannel(in: uad, text: lower) {
            history.takeSnapshot(uad: uad, description: "Reset plug-in settings on \(ch.name)")
            var updated = 0
            if ch.preamp.hasPreamp {
                for (pIdx, param) in ch.unisonEffect.parameters {
                    uad.setEffectParameter(chId: ch.id, eff: ch.unisonEffect, paramIdx: pIdx, normVal: 0.5)
                    param.normVal = 0.5
                    updated += 1
                }
            }
            for s in 0..<6 {
                if let eff = ch.effects[s] {
                    for (pIdx, param) in eff.parameters {
                        uad.setEffectParameter(chId: ch.id, eff: eff, paramIdx: pIdx, normVal: 0.5)
                        param.normVal = 0.5
                        updated += 1
                    }
                }
            }
            auditor.mcu?.refreshPluginFocusSurface()
            return "🔄 **Reset Plug-in Settings:** Restored parameters to default (50% / nominal) across all plug-ins on Track \(ch.id + 1) (**\(ch.name)**)."
        }

        // 2. Track-specific Plugin & Insert Query (e.g. "plugins on track 1", "plugins on vocal", "what plugins are on kick", "show inserts for guitar", "track 2 plugin info")
        if let ch = Self.findChannel(in: uad, text: lower), (lower.contains("plugin") || lower.contains("insert") || lower.contains("unison") || lower.contains("dsp")) {
            var lines: [String] = []
            let modeDesc = ch.recordPreEffects ? "🔵 **UAD MON** (Live DSP monitor, audio recorded dry)" : "🔴 **UAD REC** (Inserts printed directly to DAW track)"
            lines.append("🔌 **UAD Plug-ins & Inserts for Track \(ch.id + 1) (\(ch.name)):**")
            lines.append("• **Print Mode:** \(modeDesc)")
            lines.append("")

            // Unison slot
            if ch.preamp.hasPreamp {
                let uniName = !ch.unisonEffect.name.isEmpty ? ch.unisonEffect.name : (!ch.preamp.unisonPluginName.isEmpty ? ch.preamp.unisonPluginName : "")
                if !uniName.isEmpty && uniName != "None" {
                    let pwr = ch.unisonEffect.power && ch.preamp.unisonPower
                    lines.append("• **Slot 0 (UNISON)**: \(uniName) (\(pwr ? "🟢 Active" : "⚪ Bypassed"))")
                } else {
                    lines.append("• **Slot 0 (UNISON)**: [Empty — Transparent Analog Preamp]")
                }
            } else {
                lines.append("• **Slot 0 (UNISON)**: *Not supported on this channel (Line/Aux)*")
            }

            // Inserts 1 to 6
            for s in 0..<6 {
                let eff = ch.effects[s]
                let effName = eff?.name.trimmingCharacters(in: .whitespaces) ?? ""
                if !effName.isEmpty && effName != "None" {
                    let pwr = eff?.power ?? true
                    var paramDetail = ""
                    if let params = eff?.parameters, !params.isEmpty {
                        let topParams = params.values.prefix(2).map { "\($0.name): \($0.strVal.isEmpty ? String(format: "%.0f%%", $0.normVal * 100) : $0.strVal)" }.joined(separator: " | ")
                        paramDetail = " — \(topParams)"
                    }
                    lines.append("• **Slot \(s + 1) (Insert \(s + 1))**: \(effName) (\(pwr ? "🟢 Active" : "⚪ Bypassed"))\(paramDetail)")
                } else {
                    lines.append("• **Slot \(s + 1) (Insert \(s + 1))**: [Empty]")
                }
            }

            lines.append("")
            lines.append("💡 **SSL UF8 Tactile Control:** Press **`PLUG-IN`** (`Note 43`) on SSL UF8 to edit this track's plugins. Keys 1–8 select slots; Fader 1 / Mute 1 toggles bypass; Faders 2–8 tweak 7 live parameters per page.")
            return lines.joined(separator: "\n")
        }

        // 3. Unison Preamp Focus Query (e.g. "show unison plugins", "unison status", "what unison plugins are active", "unison info")
        if lower.contains("unison") {
            let preampChs = sortedChs.filter { $0.preamp.hasPreamp }
            var lines: [String] = []
            lines.append("🎙️ **UAD Unison Preamp Modeling Status:**")
            lines.append("")

            var loadedCount = 0
            for ch in preampChs {
                let uniName = !ch.unisonEffect.name.isEmpty ? ch.unisonEffect.name : (!ch.preamp.unisonPluginName.isEmpty ? ch.preamp.unisonPluginName : "")
                let gainStr = String(format: "%.1f dB", ch.preamp.gain)
                let p48 = ch.preamp.phantom48V ? "+48V" : ""
                let pad = ch.preamp.pad ? "Pad" : ""
                let lc = ch.preamp.lowCut ? "75Hz" : ""
                let tags = [p48, pad, lc].filter { !$0.isEmpty }.joined(separator: ", ")
                let tagStr = tags.isEmpty ? "" : " [\(tags)]"

                if !uniName.isEmpty && uniName != "None" {
                    loadedCount += 1
                    let pwr = ch.unisonEffect.power && ch.preamp.unisonPower
                    lines.append("• **Track \(ch.id + 1) (\(ch.name)):** **\(uniName)** (\(pwr ? "🟢 Active" : "⚪ Bypassed")) — Gain: \(gainStr)\(tagStr)")
                } else {
                    lines.append("• **Track \(ch.id + 1) (\(ch.name)):** [None / Clean Preamp] — Gain: \(gainStr)\(tagStr)")
                }
            }

            lines.append("")
            lines.append("📊 **Unison Summary:** \(loadedCount) of \(preampChs.count) hardware preamp channels modeled with Unison DSP.")
            lines.append("💡 **UF8 Tip:** Press **`CHANNEL`** (`Note 40`) for Preamp Focus or **`PLUG-IN`** Key 1 to tweak Unison parameters.")
            return lines.joined(separator: "\n")
        }

        // 4. Bypassed Plugins Query (e.g. "which plugins are bypassed?", "show bypassed plugins", "bypassed plugins")
        if lower.contains("bypassed") || lower.contains("disabled plugin") {
            var bypassedList: [String] = []
            for ch in sortedChs {
                if ch.preamp.hasPreamp {
                    let uniName = !ch.unisonEffect.name.isEmpty ? ch.unisonEffect.name : ch.preamp.unisonPluginName
                    if !uniName.isEmpty && uniName != "None" && (!ch.unisonEffect.power || !ch.preamp.unisonPower) {
                        bypassedList.append("• **Track \(ch.id + 1) (\(ch.name)):** Unison — **\(uniName)**")
                    }
                }
                for s in 0..<6 {
                    if let eff = ch.effects[s], !eff.name.isEmpty, eff.name != "None", !eff.power {
                        bypassedList.append("• **Track \(ch.id + 1) (\(ch.name)):** Insert \(s + 1) — **\(eff.name)**")
                    }
                }
            }

            if bypassedList.isEmpty {
                return "🟢 **All UAD Plug-ins Active:** No plug-ins or Unison models are currently bypassed across the 32 Apollo channels."
            }
            var lines: [String] = []
            lines.append("⚪ **Bypassed UAD Plug-ins (\(bypassedList.count)):**")
            lines.append(contentsOf: bypassedList)
            lines.append("")
            lines.append("💡 **Tip:** Say \"enable plugin on track [N]\" or press Mute on Strip 1 in UF8 Plugin Mode to re-engage.")
            return lines.joined(separator: "\n")
        }

        // 5. Global Session Plugin Inventory (e.g. "show plugins", "plugin information", "what plugins are loaded", "plugin list", "show inserts", "all plugins", "list plugins", "dsp plugins")
        var pluginEntries: [String] = []
        var totalCount = 0
        var activeCount = 0
        var bypassedCount = 0

        for ch in sortedChs {
            var chFx: [String] = []
            if ch.preamp.hasPreamp {
                let uniName = !ch.unisonEffect.name.isEmpty ? ch.unisonEffect.name : (!ch.preamp.unisonPluginName.isEmpty ? ch.preamp.unisonPluginName : "")
                if !uniName.isEmpty && uniName != "None" {
                    totalCount += 1
                    let pwr = ch.unisonEffect.power && ch.preamp.unisonPower
                    if pwr { activeCount += 1 } else { bypassedCount += 1 }
                    chFx.append("Unison: **\(uniName)** (\(pwr ? "🟢 Active" : "⚪ Bypassed"))")
                }
            }
            for s in 0..<6 {
                if let eff = ch.effects[s] {
                    let effName = eff.name.trimmingCharacters(in: .whitespaces)
                    if !effName.isEmpty && effName != "None" {
                        totalCount += 1
                        let pwr = eff.power
                        if pwr { activeCount += 1 } else { bypassedCount += 1 }
                        chFx.append("Ins \(s + 1): **\(effName)** (\(pwr ? "🟢 Active" : "⚪ Bypassed"))")
                    }
                }
            }
            if !chFx.isEmpty {
                let mode = ch.recordPreEffects ? "UAD MON" : "UAD REC"
                pluginEntries.append("• **Track \(ch.id + 1) (\(ch.name))** [\(mode)]:\n  - " + chFx.joined(separator: "\n  - "))
            }
        }

        if pluginEntries.isEmpty {
            return """
            🔌 **Apollo Plug-in & Inserts Status (Local Telemetry):**

            No plug-ins or Unison models are currently inserted across the 32 Apollo channels (Clean session).

            💡 **SSL UF8 Tactile Insert Control:**
            • Select any channel with **`SEL`**, then press the **`PLUG-IN`** button (`Note 43`).
            • Use Number Keys 1–8 (`Notes 62–69`) to select Unison (Key 1) or Inserts 1–6 (Keys 2–7).
            • Strip 1 motorized fader/mute toggles power; Strips 2–8 adjust 7 live parameters per page.
            • Use **`< PAGE >`** to flip parameter pages.
            • Key 8 toggles between **UAD REC** (print effects) and **UAD MON** (monitor only).
            """
        }

        var lines: [String] = []
        lines.append("🔌 **UAD Plug-ins & Inserts Inventory (Local 0ms Telemetry):**")
        lines.append("")
        lines.append(contentsOf: pluginEntries)
        lines.append("")
        lines.append("📊 **Session DSP Summary:** \(totalCount) plug-ins loaded (\(activeCount) active, \(bypassedCount) bypassed).")
        lines.append("💡 **UF8 Quick Tip:** Press **`PLUG-IN`** (`Note 43`) to tweak parameters live across the 7 motorized faders per page.")
        return lines.joined(separator: "\n")
    }

    private func handlePluginParameterChange(lower: String, rawQuery: String, channel: UADChannel, uad: UADClient, auditor: AIAudioAuditor) -> String? {
        // 1. Identify Target Effect
        var targetEff: UADEffect? = nil
        var effLabel: String = ""

        if lower.contains("unison") {
            if channel.preamp.hasPreamp {
                targetEff = channel.unisonEffect
                effLabel = !channel.unisonEffect.name.isEmpty ? channel.unisonEffect.name : (!channel.preamp.unisonPluginName.isEmpty ? channel.preamp.unisonPluginName : "Unison Preamp")
            } else {
                return "⚠️ Track \(channel.id + 1) (\(channel.name)) does not support Unison plug-ins (Line/Aux channel)."
            }
        }

        // Check for specific insert slot: insert 1..6
        if targetEff == nil {
            for i in 1...6 {
                if lower.contains("insert \(i)") || lower.contains("ins \(i)") || lower.contains("slot \(i)") {
                    if let eff = channel.effects[i - 1] {
                        targetEff = eff
                        effLabel = eff.name.isEmpty ? "Insert \(i)" : eff.name
                        break
                    }
                }
            }
        }

        // Check for matching plugin by name in loaded effects
        if targetEff == nil {
            for s in 0..<6 {
                if let eff = channel.effects[s], !eff.name.isEmpty {
                    let effLow = eff.name.lowercased()
                    if lower.contains(effLow) ||
                       (lower.contains("la-2a") || lower.contains("la2a")) && effLow.contains("la-2a") ||
                       lower.contains("1176") && effLow.contains("1176") ||
                       lower.contains("fairchild") && effLow.contains("fairchild") ||
                       lower.contains("pultec") && effLow.contains("pultec") ||
                       lower.contains("neve") && effLow.contains("neve") ||
                       lower.contains("eq") && effLow.contains("eq") ||
                       lower.contains("compressor") && (effLow.contains("1176") || effLow.contains("la-2a") || effLow.contains("fairchild") || effLow.contains("compressor")) {
                        targetEff = eff
                        effLabel = eff.name
                        break
                    }
                }
            }
        }

        // Check if any insert effect explicitly has the requested parameter
        if targetEff == nil {
            let kwList = ["peak reduction", "reduction", "ratio", "threshold", "attack", "release", "recovery", "input", "output", "gain", "frequency", "q", "mix"]
            for kw in kwList where lower.contains(kw) {
                // Check inserts 0..<6 first
                for s in 0..<6 {
                    if let eff = channel.effects[s], !eff.name.isEmpty {
                        for (_, p) in eff.parameters {
                            if p.name.lowercased().contains(kw) {
                                targetEff = eff
                                effLabel = eff.name
                                break
                            }
                        }
                        if targetEff != nil { break }
                    }
                }
                if targetEff != nil { break }
                // Then check unison
                if channel.preamp.hasPreamp && !channel.unisonEffect.name.isEmpty {
                    for (_, p) in channel.unisonEffect.parameters {
                        if p.name.lowercased().contains(kw) {
                            targetEff = channel.unisonEffect
                            effLabel = channel.unisonEffect.name
                            break
                        }
                    }
                }
                if targetEff != nil { break }
            }
        }

        // Fallback: pick the first loaded effect on the channel
        if targetEff == nil {
            if channel.preamp.hasPreamp && !channel.unisonEffect.name.isEmpty {
                targetEff = channel.unisonEffect
                effLabel = channel.unisonEffect.name
            } else {
                for s in 0..<6 {
                    if let eff = channel.effects[s], !eff.name.isEmpty && eff.name != "None" {
                        targetEff = eff
                        effLabel = eff.name
                        break
                    }
                }
            }
        }

        guard let eff = targetEff else {
            return "⚠️ No active plug-in was found on Track \(channel.id + 1) (\(channel.name)) to adjust."
        }

        // 2. Identify Target Parameter
        var targetParamIdx: Int? = nil
        var targetParamObj: UADEffectParam? = nil

        // Check if numeric parameter index is specified (e.g. parameter 1, param 2)
        let paramNumPattern = #"(?:parameter|param|p)\s*(\d+)"#
        if let regex = try? NSRegularExpression(pattern: paramNumPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: lower, options: [], range: NSRange(lower.startIndex..., in: lower)),
           let numRange = Range(match.range(at: 1), in: lower),
           let pNum = Int(lower[numRange]) {
            let pIdx = max(0, pNum > 0 ? pNum - 1 : 0)
            targetParamIdx = pIdx
            targetParamObj = eff.parameters[pIdx] ?? UADEffectParam(index: pIdx, name: "Param \(pIdx + 1)")
        }

        // Match parameter by semantic keywords in eff.parameters
        if targetParamIdx == nil {
            let keywords = ["ratio", "threshold", "thresh", "attack", "release", "peak reduction", "reduction", "gain", "makeup", "make-up", "mix", "blend", "wet", "frequency", "freq", "input", "output", "recovery", "q"]
            for kw in keywords {
                if lower.contains(kw) {
                    for (pIdx, param) in eff.parameters {
                        let pNameLow = param.name.lowercased()
                        if pNameLow.contains(kw) || (kw == "thresh" && pNameLow.contains("threshold")) || (kw == "freq" && pNameLow.contains("frequency")) || (kw == "makeup" && (pNameLow.contains("gain") || pNameLow.contains("make up"))) {
                            targetParamIdx = pIdx
                            targetParamObj = param
                            break
                        }
                    }
                    if targetParamIdx != nil { break }
                }
            }
        }

        // If eff.parameters is empty, fallback to common standard plugin parameter layouts
        if targetParamIdx == nil {
            let effLow = eff.name.lowercased()
            if lower.contains("peak reduction") || (effLow.contains("la-2a") && lower.contains("reduction")) {
                targetParamIdx = 0
                targetParamObj = eff.parameters[0] ?? UADEffectParam(index: 0, name: "Peak Reduction")
            } else if lower.contains("gain") && effLow.contains("la-2a") {
                targetParamIdx = 1
                targetParamObj = eff.parameters[1] ?? UADEffectParam(index: 1, name: "Gain")
            } else if lower.contains("input") && effLow.contains("1176") {
                targetParamIdx = 0
                targetParamObj = eff.parameters[0] ?? UADEffectParam(index: 0, name: "Input")
            } else if lower.contains("output") && effLow.contains("1176") {
                targetParamIdx = 1
                targetParamObj = eff.parameters[1] ?? UADEffectParam(index: 1, name: "Output")
            } else if lower.contains("attack") && effLow.contains("1176") {
                targetParamIdx = 2
                targetParamObj = eff.parameters[2] ?? UADEffectParam(index: 2, name: "Attack")
            } else if lower.contains("release") && effLow.contains("1176") {
                targetParamIdx = 3
                targetParamObj = eff.parameters[3] ?? UADEffectParam(index: 3, name: "Release")
            } else if lower.contains("ratio") && effLow.contains("1176") {
                targetParamIdx = 4
                targetParamObj = eff.parameters[4] ?? UADEffectParam(index: 4, name: "Ratio")
            } else if lower.contains("threshold") {
                targetParamIdx = 0
                targetParamObj = eff.parameters[0] ?? UADEffectParam(index: 0, name: "Threshold")
            } else if lower.contains("ratio") {
                targetParamIdx = 1
                targetParamObj = eff.parameters[1] ?? UADEffectParam(index: 1, name: "Ratio")
            } else if lower.contains("attack") {
                targetParamIdx = 2
                targetParamObj = eff.parameters[2] ?? UADEffectParam(index: 2, name: "Attack")
            } else if lower.contains("release") {
                targetParamIdx = 3
                targetParamObj = eff.parameters[3] ?? UADEffectParam(index: 3, name: "Release")
            } else if lower.contains("gain") {
                targetParamIdx = 0
                targetParamObj = eff.parameters[0] ?? UADEffectParam(index: 0, name: "Gain")
            } else {
                targetParamIdx = 0
                targetParamObj = eff.parameters[0] ?? UADEffectParam(index: 0, name: "Parameter 1")
            }
        }

        guard let pIdx = targetParamIdx, let pObj = targetParamObj else {
            return "⚠️ Could not identify which parameter to adjust on \(effLabel)."
        }

        // 3. Parse Target Normalized Value (0.0 to 1.0)
        var normVal: Double = 0.5
        var displayStr = "50%"

        // Percentage (e.g. 75%, 40%)
        let pctPattern = #"(\d+(?:\.\d+)?)\s*%"#
        if let regex = try? NSRegularExpression(pattern: pctPattern),
           let match = regex.firstMatch(in: lower, options: [], range: NSRange(lower.startIndex..., in: lower)),
           let numRange = Range(match.range(at: 1), in: lower),
           let pct = Double(lower[numRange]) {
            normVal = max(0.0, min(1.0, pct / 100.0))
            displayStr = "\(String(format: "%.0f%%", pct))"
        }
        // Ratio format (e.g. 4:1, 8:1, 12:1, 20:1)
        else if let rMatch = lower.range(of: #"(\d+)\s*:\s*1"#, options: .regularExpression) {
            let rStr = String(lower[rMatch]).replacingOccurrences(of: " ", with: "")
            let rNum = Int(rStr.components(separatedBy: ":").first ?? "") ?? 4
            switch rNum {
            case 4: normVal = 0.0
            case 8: normVal = 0.333
            case 12: normVal = 0.666
            case 20: normVal = 1.0
            default: normVal = max(0.0, min(1.0, Double(rNum) / 20.0))
            }
            displayStr = "\(rNum):1"
        }
        // Decibel values (e.g. -18 dB, -24 dB)
        else if let dbMatch = lower.range(of: #"(-?\d+(?:\.\d+)?)\s*db"#, options: .regularExpression) {
            let dbSub = String(lower[dbMatch]).replacingOccurrences(of: "db", with: "").trimmingCharacters(in: .whitespaces)
            if let dbVal = Double(dbSub) {
                normVal = max(0.0, min(1.0, (dbVal + 60.0) / 60.0))
                displayStr = "\(String(format: "%+.1f dB", dbVal))"
            }
        }
        // Semantic keywords
        else if lower.contains("fast") || lower.contains("maximum") || lower.contains("max") || lower.contains("full") {
            normVal = 1.0
            displayStr = "100% (Max / Fast)"
        } else if lower.contains("slow") || lower.contains("minimum") || lower.contains("min") || lower.contains("zero") {
            normVal = 0.0
            displayStr = "0% (Min / Slow)"
        } else if lower.contains("default") || lower.contains("center") || lower.contains("half") || lower.contains("mid") {
            normVal = 0.5
            displayStr = "50% (Nominal)"
        }
        // Numeric value (e.g. "to 0.75", "to 60", "to 4")
        else {
            let numPattern = #"(?:to|set|at)\s*(-?\d+(?:\.\d+)?)"#
            if let regex = try? NSRegularExpression(pattern: numPattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: lower, options: [], range: NSRange(lower.startIndex..., in: lower)),
               let numRange = Range(match.range(at: 1), in: lower),
               let num = Double(lower[numRange]) {
                if num >= 0.0 && num <= 1.0 {
                    normVal = num
                    displayStr = String(format: "%.0f%%", num * 100.0)
                } else if num > 1.0 && num <= 100.0 {
                    normVal = num / 100.0
                    displayStr = String(format: "%.0f%%", num)
                } else {
                    normVal = max(0.0, min(1.0, num / 100.0))
                    displayStr = "\(num)"
                }
            } else if let genRegex = try? NSRegularExpression(pattern: #"\b(\d+(?:\.\d+)?)\b"#),
                      let match = genRegex.firstMatch(in: lower, options: [], range: NSRange(lower.startIndex..., in: lower)),
                      let numRange = Range(match.range(at: 1), in: lower),
                      let num = Double(lower[numRange]) {
                if num >= 0.0 && num <= 1.0 {
                    normVal = num
                    displayStr = String(format: "%.0f%%", num * 100.0)
                } else if num > 1.0 && num <= 100.0 {
                    normVal = num / 100.0
                    displayStr = String(format: "%.0f%%", num)
                }
            }
        }

        // 4. Apply Parameter Change to Apollo Hardware
        history.takeSnapshot(uad: uad, description: "Set \(pObj.name) on \(effLabel) (\(channel.name)) to \(displayStr)")
        uad.setEffectParameter(chId: channel.id, eff: eff, paramIdx: pIdx, normVal: normVal)
        pObj.normVal = normVal
        eff.parameters[pIdx] = pObj

        auditor.mcu?.refreshPluginFocusSurface()

        return "🎛️ **Plugin Setting Updated:** Set **\(pObj.name)** on **\(effLabel)** (Track \(channel.id + 1) [**\(channel.name)**]) to **\(displayStr)** (Normalized: \(String(format: "%.2f", normVal)))."
    }

    // MARK: - Direct SSL UF8 Hardware & UAD Console Commands (Local 0ms)

    /// Resolves target channel by track number ("track 1", "ch 2", "1"), exact name ("vocal"), or token ("kick").
    public static func findChannel(in uad: UADClient, text: String) -> UADChannel? {
        let lower = text.lowercased()

        // 1. Explicit track / channel number regex: track 1, channel 2, ch 3, tr 4
        let trackPattern = #"(?:track|channel|ch|tr)\s*(\d{1,2})\b"#
        if let regex = try? NSRegularExpression(pattern: trackPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: lower, options: [], range: NSRange(lower.startIndex..., in: lower)),
           let numRange = Range(match.range(at: 1), in: lower),
           let num = Int(lower[numRange]),
           num >= 1 && num <= 32 {
            return uad.channels[num - 1]
        }

        // 2. Exact or substring match on channel name (prioritize longer name matches first)
        let sortedChannels = uad.channels.values.sorted { $0.name.count > $1.name.count }
        for ch in sortedChannels {
            let chLower = ch.name.lowercased()
            guard !chLower.isEmpty else { continue }
            if lower.contains(chLower) {
                return ch
            }
        }

        // 3. Significant token match on channel name (e.g. "kick", "snare", "vocal", "vox", "guitar", "bass", "ampeg", "aux")
        for ch in sortedChannels {
            let chLower = ch.name.lowercased()
            let tokens = chLower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { String($0) }
            for token in tokens where token.count >= 3 || token == "kd" || token == "sd" || token == "oh" {
                if lower.contains(token) {
                    return ch
                }
            }
        }

        // 4. Standalone channel number if preceded or followed by space/boundary (e.g. "mute 1", "solo 2")
        // Exclude numbers attached to cue, insert, slot, aux, bank, page, hp
        var strippedText = lower
        let prefixesToStrip = [#"cue\s*\d+"#, #"c\d+"#, #"insert\s*\d+"#, #"ins\s*\d+"#, #"slot\s*\d+"#, #"aux\s*\d+"#, #"a\d+"#, #"bank\s*\d+"#, #"page\s*\d+"#, #"hp\s*\d+"#, #"step\s*\d+"#]
        for pat in prefixesToStrip {
            if let r = try? NSRegularExpression(pattern: pat, options: .caseInsensitive) {
                strippedText = r.stringByReplacingMatches(in: strippedText, options: [], range: NSRange(strippedText.startIndex..., in: strippedText), withTemplate: " ")
            }
        }
        let standalonePattern = #"\b(\d{1,2})\b"#
        if let regex = try? NSRegularExpression(pattern: standalonePattern, options: []),
           let match = regex.firstMatch(in: strippedText, options: [], range: NSRange(strippedText.startIndex..., in: strippedText)),
           let numRange = Range(match.range(at: 1), in: strippedText),
           let num = Int(strippedText[numRange]),
           num >= 1 && num <= 32 {
            return uad.channels[num - 1]
        }

        return nil
    }

    private func handleTrackMuteSoloQuery(_ lower: String, rawQuery: String, uad: UADClient, auditor: AIAudioAuditor) -> String? {
        if lower.contains("?") || lower.contains("status") || lower.contains("which") || lower.contains("who is") || lower.contains("are muted") {
            return nil
        }

        // Global Mutes / Solos
        if lower == "mute all" || lower.contains("mute all channels") || lower.contains("mute all tracks") {
            history.takeSnapshot(uad: uad, description: "Mute all channels")
            for ch in uad.channels.values { uad.setMute(chId: ch.id, mute: true) }
            auditor.mcu?.refreshMainMixSurface()
            return "🔇 **Muted all channels** across the entire mixer."
        }
        if lower == "unmute all" || lower.contains("unmute all channels") || lower.contains("unmute all tracks") {
            history.takeSnapshot(uad: uad, description: "Unmute all channels")
            for ch in uad.channels.values { uad.setMute(chId: ch.id, mute: false) }
            auditor.mcu?.refreshMainMixSurface()
            return "🔊 **Unmuted all channels** across the entire mixer."
        }
        if lower == "clear all solos" || lower == "unsolo all" || lower == "clear solos" || lower == "clear solo" {
            history.takeSnapshot(uad: uad, description: "Clear all solos")
            for ch in uad.channels.values { uad.setSolo(chId: ch.id, solo: false) }
            auditor.mcu?.refreshMainMixSurface()
            return "⚪ **Cleared all solos** across all channels."
        }

        // Single Track Unmute
        if lower.contains("unmute") {
            if let ch = Self.findChannel(in: uad, text: lower) {
                history.takeSnapshot(uad: uad, description: "Unmute \(ch.name)")
                uad.setMute(chId: ch.id, mute: false)
                let slot = ch.id - (auditor.mcu?.bankOffset ?? 0)
                if slot >= 0 && slot < 8 { auditor.mcu?.sendMuteLed(slot: slot, on: false) }
                return "🔊 **Unmuted** Track \(ch.id + 1) (**\(ch.name)**)."
            }
        }

        // Single Track Mute (avoid matching send mute like "mute c2")
        if lower.contains("mute") && !lower.contains("monitor") && !lower.contains(" c1") && !lower.contains(" c2") && !lower.contains(" c3") && !lower.contains(" c4") && !lower.contains(" a1") && !lower.contains(" a2") {
            if let ch = Self.findChannel(in: uad, text: lower) {
                history.takeSnapshot(uad: uad, description: "Mute \(ch.name)")
                uad.setMute(chId: ch.id, mute: true)
                let slot = ch.id - (auditor.mcu?.bankOffset ?? 0)
                if slot >= 0 && slot < 8 { auditor.mcu?.sendMuteLed(slot: slot, on: true) }
                return "🔇 **Muted** Track \(ch.id + 1) (**\(ch.name)**)."
            }
        }

        // Single Track Unsolo
        if lower.contains("unsolo") {
            if let ch = Self.findChannel(in: uad, text: lower) {
                history.takeSnapshot(uad: uad, description: "Unsolo \(ch.name)")
                uad.setSolo(chId: ch.id, solo: false)
                let slot = ch.id - (auditor.mcu?.bankOffset ?? 0)
                if slot >= 0 && slot < 8 { auditor.mcu?.sendSoloLed(slot: slot, on: false) }
                return "⚪ **Unsoloed** Track \(ch.id + 1) (**\(ch.name)**)."
            }
        }

        // Single Track Solo
        if lower.contains("solo") && !lower.contains("unsolo") && !lower.contains("clear") {
            if let ch = Self.findChannel(in: uad, text: lower) {
                history.takeSnapshot(uad: uad, description: "Solo \(ch.name)")
                uad.setSolo(chId: ch.id, solo: true)
                let slot = ch.id - (auditor.mcu?.bankOffset ?? 0)
                if slot >= 0 && slot < 8 { auditor.mcu?.sendSoloLed(slot: slot, on: true) }
                return "🟡 **Soloed** Track \(ch.id + 1) (**\(ch.name)**)."
            }
        }

        return nil
    }

    private func handleFaderControlQuery(_ lower: String, rawQuery: String, uad: UADClient, auditor: AIAudioAuditor) -> String? {
        if lower.contains("?") || lower.contains("what are") || lower.contains("show fader") || lower.contains("list fader") {
            return nil
        }

        // Reset all faders to unity (0.0 dB)
        if lower == "unity all" || lower.contains("unity all faders") || lower.contains("reset all faders") || lower.contains("all faders to unity") || lower.contains("all faders to 0") {
            history.takeSnapshot(uad: uad, description: "Reset all faders to 0.0 dB unity")
            let unityTap = UADCurve.dbToTapered(0.0)
            for ch in uad.channels.values {
                uad.setFader(chId: ch.id, tapered: unityTap)
            }
            auditor.mcu?.refreshMainMixSurface()
            return "🎚️ Reset all 32 channel faders to **0.0 dB Unity Gain**."
        }

        let isFaderCommand = lower.contains("fader") || lower.contains("volume") || lower.contains("level") || lower.contains("unity") || lower.contains("pull down") || lower.contains("nudge") || lower.contains("db")
        guard isFaderCommand else { return nil }
        guard !lower.contains("monitor") && !lower.contains("send") && !lower.contains("gain") else { return nil }

        guard let ch = Self.findChannel(in: uad, text: lower) else { return nil }

        var targetDb: Double? = nil

        if lower.contains("unity") || lower.contains("0 db") || lower.contains("0db") || lower.contains("zero db") {
            targetDb = 0.0
        } else if lower.contains("-oo") || lower.contains("-inf") || lower.contains("minimum") || lower.contains("floor") || lower.contains("pull down") {
            targetDb = -144.0
        } else {
            let dbPattern = #"(-?\d+(?:\.\d+)?)\s*(?:db)?"#
            if let regex = try? NSRegularExpression(pattern: dbPattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: lower, options: [], range: NSRange(lower.startIndex..., in: lower)),
               let numRange = Range(match.range(at: 1), in: lower),
               let val = Double(lower[numRange]) {
                targetDb = max(-144.0, min(6.0, val))
            }
        }

        guard let db = targetDb else { return nil }

        history.takeSnapshot(uad: uad, description: "Set fader \(ch.name) to \(db) dB")
        let tap = UADCurve.dbToTapered(db)
        uad.setFader(chId: ch.id, tapered: tap)

        let slot = ch.id - (auditor.mcu?.bankOffset ?? 0)
        if slot >= 0 && slot < 8 {
            auditor.mcu?.sendFaderPosition(slot: slot, normVal: tap)
        }

        let dbStr = db <= -140.0 ? "-oo dB" : String(format: "%.1f dB", db)
        return "🎚️ Set **Track \(ch.id + 1) (\(ch.name))** fader to **\(dbStr)**."
    }

    private func handlePanControlQuery(_ lower: String, rawQuery: String, uad: UADClient, auditor: AIAudioAuditor) -> String? {
        if lower.contains("?") || lower.contains("show pan") || lower.contains("panned tracks") {
            return nil
        }

        // Center all pans
        if lower == "center all pans" || lower.contains("center all") || lower.contains("reset all pans") || lower.contains("all pans center") {
            history.takeSnapshot(uad: uad, description: "Center all channel pans")
            for ch in uad.channels.values {
                uad.resetPan(chId: ch.id)
            }
            auditor.mcu?.refreshMainMixSurface()
            return "🎛️ Centered pan on all 32 channels."
        }

        let isPanCmd = lower.contains("pan ") || lower.contains("pan to") || lower.starts(with: "pan") || lower.contains("panned") || lower.contains("balance")
        guard isPanCmd else { return nil }

        guard let ch = Self.findChannel(in: uad, text: lower) else { return nil }

        var targetPan: Double? = nil

        if lower.contains("center") || lower.contains(" c ") || lower.hasSuffix(" c") || lower.contains("middle") {
            targetPan = 0.0
        } else {
            let leftPattern = #"(?:left|l)\s*(\d{1,3})?"#
            let rightPattern = #"(?:right|r)\s*(\d{1,3})?"#

            if let regex = try? NSRegularExpression(pattern: leftPattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: lower, options: [], range: NSRange(lower.startIndex..., in: lower)) {
                if match.range(at: 1).location != NSNotFound,
                   let numRange = Range(match.range(at: 1), in: lower),
                   let val = Double(lower[numRange]) {
                    targetPan = max(-1.0, min(0.0, -val / 100.0))
                } else {
                    targetPan = -1.0
                }
            } else if let regex = try? NSRegularExpression(pattern: rightPattern, options: .caseInsensitive),
                      let match = regex.firstMatch(in: lower, options: [], range: NSRange(lower.startIndex..., in: lower)) {
                if match.range(at: 1).location != NSNotFound,
                   let numRange = Range(match.range(at: 1), in: lower),
                   let val = Double(lower[numRange]) {
                    targetPan = max(0.0, min(1.0, val / 100.0))
                } else {
                    targetPan = 1.0
                }
            }
        }

        guard let pan = targetPan else { return nil }

        history.takeSnapshot(uad: uad, description: "Set pan on \(ch.name)")
        uad.setPan(chId: ch.id, pan: pan)

        let slot = ch.id - (auditor.mcu?.bankOffset ?? 0)
        if slot >= 0 && slot < 8 {
            auditor.mcu?.sendVpotLedRing(slot: slot, pan: pan)
        }

        let panDesc: String
        if pan == 0.0 {
            panDesc = "Center (C)"
        } else if pan < 0.0 {
            panDesc = "Left \(Int(-pan * 100))"
        } else {
            panDesc = "Right \(Int(pan * 100))"
        }

        return "🎛️ Panned **Track \(ch.id + 1) (\(ch.name))** to **\(panDesc)**."
    }

    private func handlePreampControlQuery(_ lower: String, rawQuery: String, uad: UADClient, auditor: AIAudioAuditor) -> String? {
        let is48V = lower.contains("48v") || lower.contains("phantom")
        let isLowCut = lower.contains("low cut") || lower.contains("low-cut") || lower.contains("high pass") || lower.contains("high-pass")
        let isPad = lower.contains("pad")
        let isPhase = lower.contains("phase") || lower.contains("polarity")
        let isPreampGain = (lower.contains("preamp") || lower.contains("mic gain")) && (lower.contains("gain") || lower.contains("db"))

        guard is48V || isLowCut || isPad || isPhase || isPreampGain else { return nil }

        guard let ch = Self.findChannel(in: uad, text: lower) else { return nil }

        guard ch.preamp.hasPreamp else {
            return "⚠️ **Track \(ch.id + 1) (\(ch.name))** is a line/aux input without an analog Unison preamp."
        }

        if is48V {
            let isOn = !lower.contains("off") && !lower.contains("disable")
            history.takeSnapshot(uad: uad, description: "\(isOn ? "Enable" : "Disable") 48V on \(ch.name)")
            uad.setPreamp48V(chId: ch.id, on: isOn)
            auditor.mcu?.refreshPreampFocusSurface()
            return "\(isOn ? "⚡ **Enabled +48V Phantom Power**" : "⚪ **Disabled +48V Phantom Power**") on **Track \(ch.id + 1) (\(ch.name))**."
        }

        if isLowCut {
            let isOn = !lower.contains("off") && !lower.contains("disable")
            history.takeSnapshot(uad: uad, description: "\(isOn ? "Enable" : "Disable") Low Cut on \(ch.name)")
            uad.setPreampLowCut(chId: ch.id, on: isOn)
            auditor.mcu?.refreshPreampFocusSurface()
            return "\(isOn ? "🧹 **Enabled 75 Hz Analog Low-Cut Filter**" : "⚪ **Disabled Low-Cut Filter**") on **Track \(ch.id + 1) (\(ch.name))**."
        }

        if isPad {
            let isOn = !lower.contains("off") && !lower.contains("disable")
            history.takeSnapshot(uad: uad, description: "\(isOn ? "Enable" : "Disable") Pad on \(ch.name)")
            uad.setPreampPad(chId: ch.id, on: isOn)
            auditor.mcu?.refreshPreampFocusSurface()
            return "\(isOn ? "🛡️ **Engaged -20 dB Pad**" : "⚪ **Disengaged Pad**") on **Track \(ch.id + 1) (\(ch.name))**."
        }

        if isPhase {
            let isInverted = !lower.contains("normal") && !lower.contains("off") && !lower.contains("uninvert")
            history.takeSnapshot(uad: uad, description: "\(isInverted ? "Invert" : "Normal") Phase on \(ch.name)")
            uad.setPreampPhase(chId: ch.id, inverted: isInverted)
            auditor.mcu?.refreshPreampFocusSurface()
            return "\(isInverted ? "🔄 **Inverted Phase Polarity (Ø)**" : "⚪ **Restored Normal Phase Polarity**") on **Track \(ch.id + 1) (\(ch.name))**."
        }

        if isPreampGain {
            let gainPattern = #"(\d+(?:\.\d+)?)\s*(?:db)?"#
            if let regex = try? NSRegularExpression(pattern: gainPattern, options: []),
               let match = regex.firstMatch(in: lower, options: [], range: NSRange(lower.startIndex..., in: lower)),
               let numRange = Range(match.range(at: 1), in: lower),
               let val = Double(lower[numRange]) {
                let clamped = max(10.0, min(65.0, val))
                history.takeSnapshot(uad: uad, description: "Set preamp gain \(ch.name) to \(clamped) dB")
                uad.setPreampGain(chId: ch.id, gainDb: clamped)
                auditor.mcu?.refreshPreampFocusSurface()
                return "🎙️ Set preamp gain on **Track \(ch.id + 1) (\(ch.name))** to **+\(String(format: "%.1f", clamped)) dB**."
            }
        }

        return nil
    }

    private func handleMonitorControlQuery(_ lower: String, rawQuery: String, uad: UADClient) -> String? {
        guard lower.contains("monitor") || lower.contains("master volume") || lower.contains("master level") else { return nil }

        if lower.contains("unmute monitor") {
            history.takeSnapshot(uad: uad, description: "Unmute Master Monitor")
            uad.setMonitorMute(mute: false)
            return "🔊 **Master Monitor Unmuted** (Current: \(String(format: "%.1f", uad.monitorLevelDb)) dB)."
        }

        if lower.contains("mute monitor") {
            history.takeSnapshot(uad: uad, description: "Mute Master Monitor")
            uad.setMonitorMute(mute: true)
            return "🔇 **Master Monitor Muted** (Hearing protection active)."
        }

        if lower.contains("toggle monitor mute") {
            let isMuted = uad.toggleMonitorMute()
            return isMuted ? "🔇 **Master Monitor Muted**." : "🔊 **Master Monitor Unmuted** (Current: \(String(format: "%.1f", uad.monitorLevelDb)) dB)."
        }

        // Relative nudge
        let isNudgeUp = lower.contains("turn up") || lower.contains("nudge up") || lower.contains("raise monitor") || lower.contains("increase monitor") || lower.contains("up by")
        if isNudgeUp {
            let pat = #"(\d+(?:\.\d+)?)"#
            if let regex = try? NSRegularExpression(pattern: pat, options: []),
               let match = regex.firstMatch(in: lower, options: [], range: NSRange(lower.startIndex..., in: lower)),
               let r = Range(match.range(at: 1), in: lower),
               let val = Double(lower[r]) {
                _ = uad.nudgeMonitorDb(deltaDb: val)
                return "🔊 Nudged Master Monitor up by +\(String(format: "%.1f", val)) dB (Now: **\(String(format: "%.1f", uad.monitorLevelDb)) dB**)."
            }
        }

        let isNudgeDown = lower.contains("turn down") || lower.contains("nudge down") || lower.contains("lower monitor") || lower.contains("decrease monitor") || lower.contains("down by")
        if isNudgeDown {
            let pat = #"(\d+(?:\.\d+)?)"#
            if let regex = try? NSRegularExpression(pattern: pat, options: []),
               let match = regex.firstMatch(in: lower, options: [], range: NSRange(lower.startIndex..., in: lower)),
               let r = Range(match.range(at: 1), in: lower),
               let val = Double(lower[r]) {
                _ = uad.nudgeMonitorDb(deltaDb: -val)
                return "🔉 Nudged Master Monitor down by -\(String(format: "%.1f", val)) dB (Now: **\(String(format: "%.1f", uad.monitorLevelDb)) dB**)."
            }
        }

        // Absolute level
        let pat = #"(-?\d+(?:\.\d+)?)\s*(?:db)?"#
        if let regex = try? NSRegularExpression(pattern: pat, options: []),
           let match = regex.firstMatch(in: lower, options: [], range: NSRange(lower.startIndex..., in: lower)),
           let r = Range(match.range(at: 1), in: lower),
           let val = Double(lower[r]) {
            let clamped = max(-144.0, min(12.0, val))
            history.takeSnapshot(uad: uad, description: "Set monitor volume to \(clamped) dB")
            uad.setMonitorDb(db: clamped)
            return "🔊 Master Monitor volume set to **\(String(format: "%.1f", clamped)) dB**."
        }

        return nil
    }

    private func handleSurfaceControlQuery(_ lower: String, rawQuery: String, uad: UADClient, auditor: AIAudioAuditor) -> String? {
        // Banking
        if lower == "bank 1" || lower.contains("bank to bank 1") || lower.contains("channels 1-8") || lower.contains("tracks 1-8") {
            auditor.mcu?.bankOffset = 0
            auditor.mcu?.refreshMainMixSurface()
            return "🎛️ Switched SSL UF8 to **Bank 1 (Tracks 1–8)**."
        }
        if lower == "bank 2" || lower.contains("bank to bank 2") || lower.contains("channels 9-16") || lower.contains("tracks 9-16") {
            auditor.mcu?.bankOffset = 8
            auditor.mcu?.refreshMainMixSurface()
            return "🎛️ Switched SSL UF8 to **Bank 2 (Tracks 9–16)**."
        }
        if lower == "bank 3" || lower.contains("bank to bank 3") || lower.contains("channels 17-24") || lower.contains("tracks 17-24") {
            auditor.mcu?.bankOffset = 16
            auditor.mcu?.refreshMainMixSurface()
            return "🎛️ Switched SSL UF8 to **Bank 3 (Tracks 17–24)**."
        }
        if lower == "bank 4" || lower.contains("bank to bank 4") || lower.contains("channels 25-32") || lower.contains("tracks 25-32") {
            auditor.mcu?.bankOffset = 24
            auditor.mcu?.refreshMainMixSurface()
            return "🎛️ Switched SSL UF8 to **Bank 4 (Tracks 25–32)**."
        }

        if lower.contains("page left") || lower == "bank left" {
            let current = auditor.mcu?.bankOffset ?? 0
            let newBank = max(0, current - 8)
            auditor.mcu?.bankOffset = newBank
            auditor.mcu?.refreshMainMixSurface()
            return "🎛️ Paged left to **Bank \(newBank / 8 + 1) (Tracks \(newBank + 1)–\(newBank + 8))**."
        }

        if lower.contains("page right") || lower == "bank right" {
            let current = auditor.mcu?.bankOffset ?? 0
            let newBank = min(24, current + 8)
            auditor.mcu?.bankOffset = newBank
            auditor.mcu?.refreshMainMixSurface()
            return "🎛️ Paged right to **Bank \(newBank / 8 + 1) (Tracks \(newBank + 1)–\(newBank + 8))**."
        }

        // Sends Focus Mode
        if lower.contains("enter sends") || lower.contains("sends focus") || lower == "sends mode" || lower.contains("show sends mode") {
            let targetCh = Self.findChannel(in: uad, text: lower)
            auditor.mcu?.toggleSendsFocusMode(targetCh: targetCh?.id)
            let nameTag = targetCh != nil ? " for **\(targetCh!.name)**" : ""
            return "🎛️ SSL UF8 entered **Sends Focus Mode**\(nameTag) (Strips 1–2: Aux 1–2, Strips 3–6: Cues 1–4, Strip 7: Output, Strip 8: Pan)."
        }

        if lower.contains("exit sends") {
            if auditor.mcu?.sendsFocusMode == true { auditor.mcu?.toggleSendsFocusMode() }
            return "🎛️ Exited Sends Focus Mode. Restored to Main Mix."
        }

        // Preamp Focus Mode
        if lower.contains("enter preamp") || lower.contains("preamp focus") || lower == "preamp mode" || lower.contains("show preamp mode") {
            let targetCh = Self.findChannel(in: uad, text: lower)
            auditor.mcu?.togglePreampFocusMode(targetCh: targetCh?.id)
            let nameTag = targetCh != nil ? " for **\(targetCh!.name)**" : ""
            return "🎙️ SSL UF8 entered **Preamp Focus Mode**\(nameTag) (Strip 1: Gain, Strip 2: 48V, Strip 3: Pad, Strip 4: Low-Cut, Strip 5: Phase Ø, Strip 8: Unison)."
        }

        if lower.contains("exit preamp") {
            if auditor.mcu?.preampFocusMode == true { auditor.mcu?.togglePreampFocusMode() }
            return "🎙️ Exited Preamp Focus Mode. Restored to Main Mix."
        }

        // Plugin Focus Mode
        if lower.contains("enter plugin") || lower.contains("plugin focus") || lower == "plugin mode" {
            let targetCh = Self.findChannel(in: uad, text: lower)
            auditor.mcu?.togglePluginFocusMode(targetCh: targetCh?.id)
            return "🔌 SSL UF8 entered **Plug-in Focus Mode**."
        }

        if lower.contains("exit plugin") {
            if auditor.mcu?.pluginFocusMode == true { auditor.mcu?.togglePluginFocusMode() }
            return "🔌 Exited Plug-in Focus Mode. Restored to Main Mix."
        }

        // Main Mix / FLIP
        if lower == "main mix" || lower == "return to main mix" || lower == "flip" || lower == "flip back" {
            auditor.mcu?.refreshMainMixSurface()
            return "🎛️ Restored SSL UF8 to **Main Mix**."
        }

        // Auto-Rough Mix
        if lower == "rough mix" || lower == "auto rough mix" || lower.contains("auto-rough mix") || lower.contains("balance all faders") || lower.contains("auto balance faders") {
            history.takeSnapshot(uad: uad, description: "One-Touch Auto-Rough Mix")
            let result = auditor.applyRoughMix()
            return "🎚️ **One-Touch Auto-Rough Mix Executed:**\n\(result)"
        }

        return nil
    }

    private func handleUADRecMonQuery(_ lower: String, uad: UADClient) -> String? {
        let isRec = lower.contains("uad rec") || lower.contains("record wet")
        let isMon = lower.contains("uad mon") || lower.contains("record dry")
        guard isRec || isMon else { return nil }

        guard let ch = Self.findChannel(in: uad, text: lower) else { return nil }

        history.takeSnapshot(uad: uad, description: "Set \(ch.name) to \(isRec ? "UAD REC" : "UAD MON")")
        uad.setRecordPreEffects(chId: ch.id, isMon: isMon)

        return isRec ?
            "🔴 **Track \(ch.id + 1) (\(ch.name))** set to **UAD REC** (Prints insert effects directly to DAW tracks)." :
            "🔵 **Track \(ch.id + 1) (\(ch.name))** set to **UAD MON** (Real-time DSP monitoring, records dry audio)."
    }

    // MARK: - Local UAD Console Telemetry Engine (Instant 0ms, Zero Network Latency)

    public static func isZeroInputQuery(_ text: String) -> Bool {
        let hasZero = text.contains("zero input") || text.contains("no input") || text.contains("without input") || text.contains("zero signal")
        let hasSilent = text.contains("silent") || text.contains("dead channel") || text.contains("dead input") || text.contains("dead track") || text.contains("inactive channel") || text.contains("inactive input") || text.contains("empty channel") || text.contains("empty track")
        let hasNoSignal = text.contains("no signal") || text.contains("without signal") || text.contains("no audio") || text.contains("without audio") || text.contains("no sound")
        return hasZero || hasSilent || hasNoSignal
    }

    private func handleZeroInputQuery(uad: UADClient) -> String {
        let sorted = uad.channels.values.sorted(by: { $0.id < $1.id })
        var silentChannels: [UADChannel] = []
        var activeChannels: [UADChannel] = []

        for ch in sorted {
            if ch.meterPeak <= -60.0 {
                silentChannels.append(ch)
            } else {
                activeChannels.append(ch)
            }
        }

        if silentChannels.isEmpty {
            return "🔊 All \(sorted.count) Apollo channels currently have active audio signals above -60 dBFS. No silent or dead inputs detected."
        }

        var lines: [String] = []
        lines.append("🔇 **Channels with Zero Input / Silent** (\(silentChannels.count) of \(sorted.count) tracks):")
        for ch in silentChannels {
            let peakStr = ch.meterPeak <= -75.0 ? "-oo dBFS" : String(format: "%.1f dBFS", ch.meterPeak)
            let typeTag = ch.chType == "aux" ? "[AUX]" : "[IN]"
            lines.append("• \(typeTag) **\(ch.name)** (Track \(ch.id + 1)): \(peakStr) — No signal")
        }

        if !activeChannels.isEmpty {
            lines.append("")
            lines.append("💡 **Active Signals (\(activeChannels.count))**: " + activeChannels.map { "\($0.name) (\(String(format: "%.1f", $0.meterPeak)) dBFS)" }.joined(separator: ", "))
        }

        return lines.joined(separator: "\n")
    }

    public static func isActiveSignalQuery(_ text: String) -> Bool {
        let hasActive = text.contains("active channel") || text.contains("active track") || text.contains("active signal")
        let hasSignal = (text.contains("with signal") || text.contains("have signal") || text.contains("has signal") ||
                         text.contains("receiving signal") || text.contains("receiving audio") || text.contains("signal present") ||
                         text.contains("who is playing") || text.contains("playing track") || text.contains("live signal") ||
                         text.contains("incoming signal") || text.contains("incoming audio") || text.contains("input signal") ||
                         text.contains("incoming") || text.contains("current signal") || text.contains("signal check") ||
                         text.contains("check signal") || (text.contains("signal") && (text.contains("analyze") || text.contains("check") || text.contains("current") || text.contains("show"))))
                        && !text.contains("no signal") && !text.contains("without signal") && !text.contains("zero input") && !text.contains("zero signal")
        return hasActive || hasSignal
    }

    private func handleActiveSignalQuery(uad: UADClient) -> String {
        let sorted = uad.channels.values.sorted(by: { $0.id < $1.id })
        let active = sorted.filter { $0.meterPeak > -60.0 }

        if active.isEmpty {
            return "🔇 No active audio signals detected across \(sorted.count) channels (all peak levels are below -60 dBFS)."
        }

        var lines: [String] = []
        lines.append("🔊 **Channels Receiving Signal** (\(active.count) of \(sorted.count) tracks):")
        for ch in active {
            let faderStr = ch.fader <= 0.001 ? "-oo dB" : String(format: "%.1f dB", ch.faderDb)
            let clipTag = (ch.meterClip || ch.meterPeak >= -0.1) ? " ⚠️ [CLIPPING]" : ""
            lines.append("• **\(ch.name)**: Peak \(String(format: "%.1f", ch.meterPeak)) dBFS | Fader \(faderStr)\(clipTag)")
        }
        return lines.joined(separator: "\n")
    }

    public static func isConsoleSummaryQuery(_ text: String) -> Bool {
        return text.contains("console summary") || text.contains("mixer summary") || text.contains("session summary") || text.contains("mixer overview") || text.contains("console overview") || text.contains("mixer status") || text.contains("console status") || text.contains("mix overview") || text == "show mixer" || text == "mix status"
    }

    private func handleConsoleSummaryQuery(uad: UADClient) -> String {
        let sorted = uad.channels.values.sorted(by: { $0.id < $1.id })
        let inputCount = sorted.filter { $0.chType != "aux" }.count
        let auxCount = sorted.filter { $0.chType == "aux" }.count
        let activeAudio = sorted.filter { $0.meterPeak > -60.0 }
        let silentAudio = sorted.filter { $0.meterPeak <= -60.0 }
        let muted = sorted.filter { $0.mute }
        let soloed = sorted.filter { $0.solo }
        let clipping = sorted.filter { $0.meterClip || $0.meterPeak >= -0.1 }

        var lines: [String] = []
        lines.append("📊 **Universal Audio Apollo Console Summary**:")
        lines.append("• **Hardware Layout**: \(sorted.count) total channels (\(inputCount) Analog/DSP Inputs, \(auxCount) Aux Buses)")
        lines.append("• **Audio Streams**: \(activeAudio.count) active signal streams, \(silentAudio.count) silent tracks")
        lines.append("• **Converter Headroom**: \(clipping.isEmpty ? "✅ Clean (0 clipping)" : "⚠️ \(clipping.count) channels clipping: \(clipping.map { $0.name }.joined(separator: ", "))")")
        lines.append("• **Mutes**: \(muted.isEmpty ? "None" : "\(muted.count) muted (\(muted.map { $0.name }.joined(separator: ", ")))")")
        lines.append("• **Solos**: \(soloed.isEmpty ? "None" : "\(soloed.count) soloed (\(soloed.map { $0.name }.joined(separator: ", ")))")")

        if !activeAudio.isEmpty {
            lines.append("")
            lines.append("🔊 **Hot Signals**: " + activeAudio.prefix(6).map { "\($0.name) (\(String(format: "%.1f", $0.meterPeak)) dBFS)" }.joined(separator: ", "))
        }

        return lines.joined(separator: "\n")
    }

    public static func isFullChannelListQuery(_ text: String) -> Bool {
        return text.contains("full list") || text.contains("all channel") || text.contains("channel list") || text.contains("channels list") || text.contains("list channel") || text.contains("list of channel") || text.contains("track list") || text.contains("all track") || text.contains("show channel") || text.contains("channel inventory") || text.contains("mixer inventory")
    }

    private func handleFullChannelListQuery(uad: UADClient) -> String {
        let sorted = uad.channels.values.sorted(by: { $0.id < $1.id })
        guard !sorted.isEmpty else {
            return "No channels currently discovered in Apollo Console."
        }

        var lines: [String] = []
        lines.append("🎛️ **Universal Audio Apollo Full Channel Inventory (\(sorted.count) Tracks)**:")
        lines.append("Complete mixer mapping across SSL UF8 physical 8-fader banking layers:")
        lines.append("")

        let bankCount = (sorted.count + 7) / 8
        for b in 0..<bankCount {
            let start = b * 8
            let end = min(start + 8, sorted.count)
            let bankChannels = Array(sorted[start..<end])

            lines.append("### ── Bank \(b + 1) (UF8 Physical Faders 1–8 • Tracks \(start + 1)–\(end)) ──")
            for (idx, ch) in bankChannels.enumerated() {
                let slotNum = start + idx + 1
                let faderStr = ch.fader <= 0.001 ? "-oo dB" : String(format: "%.1f dB", ch.faderDb)
                let panStr: String
                if abs(ch.pan) <= 0.05 {
                    panStr = "C"
                } else if ch.pan < 0 {
                    panStr = "L \(Int(abs(ch.pan) * 100))%"
                } else {
                    panStr = "R \(Int(ch.pan * 100))%"
                }

                var badges: [String] = []
                if ch.mute { badges.append("MUTED") }
                if ch.solo { badges.append("SOLO") }
                if ch.meterClip || ch.meterPeak >= -0.1 { badges.append("⚠️ CLIP") }
                let badgeStr = badges.isEmpty ? "" : " [\(badges.joined(separator: ", "))]"

                let peakStr = ch.meterPeak <= -75.0 ? "-oo dBFS (Silent)" : String(format: "%.1f dBFS", ch.meterPeak)
                let typeTag = ch.chType == "aux" ? "Aux" : "Input"

                lines.append("• **Track \(slotNum)**: `\(ch.name)` (\(typeTag)) | Fader: \(faderStr) | Pan: \(panStr) | Peak: \(peakStr)\(badgeStr)")
            }
            lines.append("")
        }

        lines.append("💡 *Tip: Use `< PAGE >` on your UF8 to jump between Bank 1, Bank 2, Bank 3, etc.*")
        return lines.joined(separator: "\n")
    }

    private func isMuteSoloStatusQuery(_ text: String) -> Bool {
        let isMute = (text.contains("which channel") || text.contains("which track") || text.contains("who is") || text.contains("status") || text.contains("show") || text.contains("list")) && (text.contains("mute") || text.contains("muted"))
        let isSolo = (text.contains("which channel") || text.contains("which track") || text.contains("who is") || text.contains("status") || text.contains("show") || text.contains("list")) && (text.contains("solo") || text.contains("soloed"))
        return isMute || isSolo
    }

    private func handleMuteSoloStatusQuery(lower: String, uad: UADClient) -> String {
        let sorted = uad.channels.values.sorted(by: { $0.id < $1.id })
        let isSoloCheck = lower.contains("solo")

        if isSoloCheck {
            let soloed = sorted.filter { $0.solo }
            if soloed.isEmpty {
                return "🎧 No channels are currently soloed."
            }
            return "🎧 **Soloed Channels (\(soloed.count))**: " + soloed.map { $0.name }.joined(separator: ", ")
        } else {
            let muted = sorted.filter { $0.mute }
            if muted.isEmpty {
                return "🔊 No channels are currently muted."
            }
            return "🔇 **Muted Channels (\(muted.count))**: " + muted.map { $0.name }.joined(separator: ", ")
        }
    }

    private func isFaderInspectionQuery(_ text: String) -> Bool {
        return (text.contains("fader level") || text.contains("fader position") || text.contains("show fader") || text.contains("list fader") || text.contains("what are the faders") || text.contains("check faders")) && !text.contains("-infinite") && !text.contains("set")
    }

    private func handleFaderInspectionQuery(uad: UADClient) -> String {
        let sorted = uad.channels.values.sorted(by: { $0.id < $1.id })
        var lines: [String] = []
        lines.append("🎚️ **Apollo Console Fader Levels** (\(sorted.count) channels):")
        for ch in sorted {
            let val = ch.fader <= 0.001 ? "-oo dB" : String(format: "%.1f dB", ch.faderDb)
            lines.append("• **\(ch.name)**: \(val)")
        }
        return lines.joined(separator: "\n")
    }

    private func isPanInspectionQuery(_ text: String) -> Bool {
        return (text.contains("pan position") || text.contains("pan status") || text.contains("show pan") || text.contains("list pan") || text.contains("what are the pans") || text.contains("panned track")) && !text.contains("set")
    }

    private func handlePanInspectionQuery(uad: UADClient) -> String {
        let sorted = uad.channels.values.sorted(by: { $0.id < $1.id })
        var nonCenter: [String] = []
        for ch in sorted {
            if abs(ch.pan) > 0.05 {
                let dir = ch.pan < 0 ? "L \(Int(abs(ch.pan) * 100))%" : "R \(Int(ch.pan * 100))%"
                nonCenter.append("• **\(ch.name)**: \(dir)")
            }
        }
        if nonCenter.isEmpty {
            return "⚖️ All \(sorted.count) Apollo channels are currently panned dead-center (C)."
        }
        return "⚖️ **Panned Channels (\(nonCenter.count) non-center)**:\n" + nonCenter.joined(separator: "\n")
    }

    // MARK: - Local SSL UF8 & UAD Hardware Guide (0ms Offline Reference)

    private func handleHardwareGuideQuery(_ lower: String) -> String? {
        // 1. Fader Reset / Unity / Floor
        if lower.contains("reset fader") || lower.contains("unity gain") || lower.contains("0 db") || lower.contains("zero db") || lower.contains("floor fader") || lower.contains("-oo db") || lower.contains("minus infinity") || lower.contains("fader gesture") || lower.contains("fader touch") {
            return """
            🎚️ **SSL UF8 Fader Gestures & Snap Controls**:
            • **0.0 dB Unity Gain Reset**: Press **AUTO + SEL** or **Double-Tap SEL** on any track to fly motorized fader to exact `0.0 dB`.
            • **-oo dB Floor Snap**: **Long-Press SEL (> 0.5s)** on any track to smoothly drop fader to `-oo dB` (Muted Floor).
            • **Capacitive Touch Interlock**: Touching any fader cap (Notes 104–111) releases the motor clutch instantly—Apollo automation will never fight your hand.
            • **Page Navigation**: **`< PAGE >`** jumps 8 channels (1–8 → 9–16 → 17–24 → 25–27). **`< BANK >`** nudges by 1 single track.
            """
        }

        // 2. CUE & Sends Focus Mode
        if lower.contains("sends mode") || lower.contains("send mode") || lower.contains("cue mix") || lower.contains("headphone mix") || lower.contains("cue sends") || lower.contains("aux sends") || lower.contains("sends on fader") || (lower.contains("send") && (lower.contains("how") || lower.contains("what") || lower.contains("guide") || lower.contains("use"))) {
            return """
            🎛️ **Channel CUE & Sends Focus Mode (`SEND` Button / Note 41)**:
            • **How to Enter**: Press **`SEND`** or **Double-Tap `SEL`** on an already selected track.
            • **8-Strip Fader Layout**:
              - **Strips 1–2**: **AUX 1 & AUX 2** Master Sends (Faders = Send level, Mutes = Bypass `BYP`, V-Pots = Send pan).
              - **Strips 3–6**: **CUE 1, CUE 2, CUE 3, CUE 4** Artist Headphone mixes (HP 1, HP 2, Line 3, Line 4).
              - **Strip 7**: Track Output Volume.
              - **Strip 8**: Track Master Pan.
            • **Channel Stepping**: Rotate the **Channel Wheel** or press **`< BANK >`** to step between tracks without leaving Sends mode.
            • **Exit**: Single-tap **`FLIP`** returns to Main Mix at your current bank. Double-tap **`FLIP`** snaps home to Channels 1–8.
            """
        }

        // 3. Preamp Focus Mode
        if lower.contains("preamp mode") || lower.contains("channel mode") || lower.contains("preamp focus") || lower.contains("+48v") || lower.contains("phantom power") || lower.contains("low cut") || lower.contains("phase invert") || (lower.contains("preamp") && (lower.contains("how") || lower.contains("control") || lower.contains("guide") || lower.contains("use"))) {
            return """
            🎙️ **Preamp Focus Mode (`CHANNEL` Button / Note 40)**:
            • **How to Enter**: Select an analog Apollo channel and press **`CHANNEL`**.
            • **8-Strip Inspector Layout**:
              - **Strip 1 (Preamp Gain)**: Motorized fader tracks gain (+10.0 to +65.0 dB); V-Pot trims ±1 dB; V-Pot push resets to +10 dB.
              - **Strip 2 (+48V Phantom Power)**: **Safety Double-Tap Interlock (<0.85s)** on Mute 2 or SEL 2 to engage (protects ribbon mics); single tap turns off.
              - **Strip 3 (-20 dB Pad)**: Mute 3 or SEL 3 toggles the analog input pad.
              - **Strip 4 (75 Hz Low-Cut)**: Mute 4 or SEL 4 engages Apollo's 75 Hz high-pass filter.
              - **Strip 5 (Phase Invert - Ø)**: Mute 5 or SEL 5 flips phase polarity.
              - **Strip 6 (Input Source)**: Cycles Mic vs. Line; auto-detects front Hi-Z jack lock.
              - **Strip 7 (Output & Pan)**: Channel volume fader and pan.
              - **Strip 8 (Unison Plugin)**: Mute 8 toggles Unison DSP modeling plugin power/bypass.
            • **Exit**: Press **`CHANNEL`** to return to Main Mix.
            """
        }

        // 4. Plug-in Inspector Mode
        if lower.contains("plugin mode") || lower.contains("plug-in mode") || lower.contains("insert mode") || lower.contains("tweak plugin") || lower.contains("dsp plugin") || (lower.contains("plugin") && (lower.contains("how") || lower.contains("guide") || lower.contains("use"))) {
            return """
            🔌 **Tactile Plug-in & Insert Inspector (`PLUG-IN` Button / Note 43)**:
            • **How to Enter**: Select a track and press **`PLUG-IN`**.
            • **Slot Selection via UF8 Number Keys (1–8)**:
              - **Key 1 (Slot 0)**: Unison preamp plugin.
              - **Keys 2–7 (Slots 1–6)**: Inserts 1 through 6.
              - **Key 8 (Slot 7)**: Toggles UAD REC (wet) vs UAD MON (dry).
            • **Strip 1 (Master Power & Bypass)**: Displays plugin name (`LA-2A`, `1176LN`); Fader 1, V-Pot 1, and Mute 1 toggle power (On/Off).
            • **Strips 2–8 (Tactile DSP Parameters)**: 7 continuous parameters per page on motorized faders & V-Pots. SEL 2–8 speaks sound-critical values.
            • **Paging**: Use **`< PAGE >`** to page through parameters while Strip 1 remains fixed as On/Off.
            """
        }

        // 5. FLIP Button & Home Snap
        if lower.contains("flip") || lower.contains("home button") || lower.contains("back button") {
            return """
            🔄 **Global `FLIP` Button Operation (`Note 50` / `0x32`)**:
            • **Single-Tap FLIP**: Exits any sub-mode (Sends Focus, Preamp Focus, Plugin Mode, or AI Mode) and returns to Main Mix at your **current bank position**.
            • **Double-Tap FLIP**: Master **Home Button**—exits all sub-modes and snaps the motorized fader bank straight to **Channels 1–8**.
            """
        }

        // 6. Monitor Volume & Emergency Mute
        if lower.contains("monitor volume") || lower.contains("jog wheel") || lower.contains("channel wheel") || lower.contains("rotary wheel") || lower.contains("monitor mute") || lower.contains("center circle") {
            return """
            🔊 **Master Monitor Volume & Hearing Protection**:
            • **Large Channel Rotary Wheel**: Trims Apollo Master Monitor volume by ±1.0 dB per tick (-96.0 dB to 0.0 dB).
            • **Center Circle Key (`Note 100`)**: The round button in the center of the 4-way arrows **instantly toggles Master Monitor Mute/Unmute**.
            • **Hearing Safety Guarantee**: Center Circle is permanently dedicated to monitor mute in **every mode**, including active AI sessions.
            """
        }

        // 7. Talkback & Master Aux Returns
        if lower.contains("talkback") || lower.contains("slate mic") || lower.contains("aux return") {
            return """
            🎙️ **Hardware Talkback & Master Aux Returns**:
            • **Channel 25 (Talkback Mic)**: Motorized fader controls Apollo slate mic gain; Mute 25 acts as the physical talkback switch.
            • **Channels 26 & 27 (Aux 1 & 2 Returns)**: Motorized faders and mutes control master stereo reverb and delay returns.
            """
        }

        // 8. SSL 360 & CoreMIDI Connection
        if lower.contains("ssl 360") || lower.contains("layer 3") || lower.contains("port 9") || lower.contains("midi port") || lower.contains("setup uf8") || lower.contains("connect uf8") {
            return """
            ⚙️ **SSL 360° Software & Hardware Configuration**:
            1. Open **SSL 360°** on your Mac.
            2. Select **UF8** tab → Choose **Layer 3** (leaves Layers 1 & 2 free for Pro Tools, Logic, etc.).
            3. Set DAW Profile to **Logic Pro** (MCU).
            4. Set MIDI Ports to **SSL V-MIDI Port 9** (In & Out).
            5. The bridge connects via CoreMIDI with < 0.85 ms latency and zero driver overhead.
            """
        }

        // 9. General Guide / Manual / Shortcuts / Help
        if lower.contains("uf8") || lower.contains("hardware") || lower.contains("shortcut") || lower.contains("manual") || lower.contains("guide") || lower == "help" || lower == "/help" {
            return """
            📖 **SSL UF8 & Universal Audio Apollo Hardware Reference Guide**:

            • **Fader Snap Controls**:
              - **AUTO + SEL** or **Double-Tap SEL**: Fly fader to exact `0.0 dB` Unity Gain.
              - **Long-Press SEL (> 0.5s)**: Pull fader to `-oo dB` floor.
              - **Capacitive Touch**: Motor clutch releases instantly when touched.

            • **Hardware Modes**:
              - **`CHANNEL`**: Preamp Focus Mode (Gain, +48V double-tap safety, Pad, 75Hz Low-Cut, Phase Ø, Mic/Line, Output, Unison).
              - **`SEND`** (or Double-Tap SEL): Cue/Sends Mode (AUX 1–2, CUE 1–4 headphone mixes, Output, Pan).
              - **`PLUG-IN`**: Tactile Insert Inspector (Keys 1–8 select slots; Strip 1 = Power; Strips 2–8 = 7 params/page).
              - **`FLIP`**: Single-tap returns to Main Mix; Double-tap snaps home to Channels 1–8.
              - **`FINE`**: Short-press = 3-step acoustic pre-flight inspection; Long-press = Open S&D Co-Producer chat.

            • **Monitoring & Safety**:
              - **Rotary Wheel**: Trims Apollo Master Monitor volume (±1.0 dB/tick).
              - **Center Circle (`Note 100`)**: Instant Master Monitor Mute/Unmute in all modes.
            """
        }

        return nil
    }

    // MARK: - Mixer Telemetry Context Generation for Local LLM

    public func generateMixerTelemetrySummaryForLLM(uad: UADClient, auditor: AIAudioAuditor) -> String {
        var lines: [String] = []
        lines.append("LIVE APOLLO CONSOLE MIXER TELEMETRY & STATUS:")
        lines.append("• Master Monitor: \(String(format: "%.1f", uad.monitorLevelDb)) dB, Muted: \(uad.monitorMute ? "YES" : "NO")")

        let sortedChannels = uad.channels.values.sorted { $0.id < $1.id }

        // 1. Overloaded / Clipping Channels (Peak >= -0.1 dBFS or meterClip)
        let overloaded = sortedChannels.filter { $0.meterPeak >= -0.1 || $0.meterClip }
        if !overloaded.isEmpty {
            let chList = overloaded.map { "Ch \($0.id + 1) [\($0.name)]: \(String(format: "%.1f", $0.meterPeak)) dBFS" }.joined(separator: ", ")
            lines.append("• ⚠️ OVERLOADED / CLIPPING TRACKS: \(chList)")
        } else {
            lines.append("• Headroom Status: Normal (No clipping detected, all channels < -0.1 dBFS)")
        }

        // 2. Silent / Zero-Input Channels (Peak <= -60.0 dBFS)
        let silent = sortedChannels.filter { $0.meterPeak <= -60.0 }
        if !silent.isEmpty {
            let chList = silent.map { "Ch \($0.id + 1) [\($0.name)] (\(String(format: "%.1f", $0.meterPeak)) dBFS)" }.joined(separator: ", ")
            lines.append("• 🔇 ZERO-INPUT / SILENT TRACKS (\(silent.count)): \(chList)")
        }

        // 3. Active Signal Streams (Peak > -60.0 dBFS)
        let active = sortedChannels.filter { $0.meterPeak > -60.0 }
        if !active.isEmpty {
            let chList = active.map { "Ch \($0.id + 1) [\($0.name)]: \(String(format: "%.1f", $0.meterPeak)) dBFS" }.joined(separator: ", ")
            lines.append("• 🔊 ACTIVE AUDIO STREAMS (\(active.count)): \(chList)")
        }

        // 4. Muted / Soloed Channels
        let muted = sortedChannels.filter { $0.mute }
        if !muted.isEmpty {
            lines.append("• Muted Tracks: " + muted.map { "Ch \($0.id + 1) [\($0.name)]" }.joined(separator: ", "))
        }
        let soloed = sortedChannels.filter { $0.solo }
        if !soloed.isEmpty {
            lines.append("• Soloed Tracks: " + soloed.map { "Ch \($0.id + 1) [\($0.name)]" }.joined(separator: ", "))
        }

        // 5. Channel Details (Fader, Pan, Preamp, Plugins)
        lines.append("• Channel Strips:")
        for ch in sortedChannels {
            var details: [String] = []
            details.append("Fader: \(String(format: "%.1f", ch.faderDb)) dB")
            let panStr = ch.pan == 0 ? "C" : (ch.pan < 0 ? "L\(Int(abs(ch.pan) * 100))" : "R\(Int(ch.pan * 100))")
            details.append("Pan: \(panStr)")
            if ch.mute { details.append("MUTED") }
            if ch.solo { details.append("SOLO") }
            details.append("Peak: \(String(format: "%.1f", ch.meterPeak)) dBFS")

            // Preamp
            if ch.preamp.hasPreamp {
                var preDetails: [String] = ["Gain: \(String(format: "%.1f", ch.preamp.gain)) dB"]
                if ch.preamp.phantom48V { preDetails.append("+48V ON") }
                if ch.preamp.lowCut { preDetails.append("75Hz Low Cut") }
                if ch.preamp.pad { preDetails.append("-20dB Pad") }
                if ch.preamp.phase { preDetails.append("Phase Invert") }
                details.append("Preamp: [\(preDetails.joined(separator: ", "))]")
            }

            // Unison & Inserts
            var plugNames: [String] = []
            if !ch.unisonEffect.name.isEmpty {
                plugNames.append("Unison: \(ch.unisonEffect.name) (\(ch.unisonEffect.power ? "Active" : "Bypassed"))")
            } else if !ch.preamp.unisonPluginName.isEmpty {
                plugNames.append("Unison: \(ch.preamp.unisonPluginName) (\(ch.preamp.unisonPower ? "Active" : "Bypassed"))")
            }
            for (idx, eff) in ch.effects.sorted(by: { $0.key < $1.key }) where !eff.name.isEmpty {
                plugNames.append("Ins \(idx + 1): \(eff.name) (\(eff.power ? "Active" : "Bypassed"))")
            }
            if !plugNames.isEmpty {
                details.append("Plugins: [\(plugNames.joined(separator: "; "))]")
            }

            lines.append("  - Ch \(ch.id + 1) (\(ch.name)): " + details.joined(separator: " | "))
        }

        // 6. Active Co-Producer Recommendations
        if !auditor.suggestions.isEmpty {
            lines.append("• Co-Producer Recommendations:")
            for s in auditor.suggestions {
                lines.append("  - \(s.channelName): \(s.issueTitle) — \(s.voiceDescription)")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Local LLM (Ollama / Llama 3.2) REST API Client

    public func queryLocalLLM(prompt: String, uad: UADClient, auditor: AIAudioAuditor, fallback: (() -> String)? = nil, completion: @escaping (String) -> Void) {
        OllamaServiceManager.shared.ensureOllamaRunning(endpoint: ollamaEndpoint) { [weak self] running in
            guard let self = self else { return }
            if !running {
                DispatchQueue.main.async {
                    if let fallbackText = fallback?() {
                        completion(fallbackText)
                    } else {
                        completion("""
                        ⚠️ **Local Llama 3.2 is Offline** (Could not connect to Ollama at \(self.ollamaEndpoint))

                        To activate Local Llama 3.2, start Ollama by running:
                        `ollama serve` (or launch `/opt/homebrew/bin/ollama serve`)

                        Expected model: `\(self.ollamaModel)`
                        Offline mixer commands, CUE sends, fader motor unity, preamp inspection, and tactile navigation remain 100% operational in 0ms!
                        """)
                    }
                }
                return
            }
            self.executeOllamaGenerate(prompt: prompt, uad: uad, auditor: auditor, fallback: fallback, completion: completion)
        }
    }

    public func executeOllamaGenerate(prompt: String, uad: UADClient, auditor: AIAudioAuditor, modelOverride: String? = nil, fallback: (() -> String)? = nil, completion: @escaping (String) -> Void) {
        let cleanEndpoint = ollamaEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "\(cleanEndpoint)/api/generate") else {
            if let fb = fallback?() {
                completion(fb)
            } else {
                completion("Invalid Ollama endpoint: \(ollamaEndpoint)")
            }
            return
        }

        let targetModel = modelOverride ?? ollamaModel

        let telemetrySummary = generateMixerTelemetrySummaryForLLM(uad: uad, auditor: auditor)

        let hardwareManualKnowledge = """
        OFFICIAL SSL UF8 & UNIVERSAL AUDIO APOLLO BRIDGE MANUAL & SPECIFICATION:
        1. HARDWARE ARCHITECTURE:
           - Controller: Solid State Logic (SSL) UF8 Advanced DAW Controller (8x motorized faders, scribble strips, V-Pots, rotary wheel).
           - Audio Engine: Universal Audio Apollo DSP Mixer (127.0.0.1:4710).
           - MIDI Layer: macOS CoreMIDI over SSL 360° Layer 3, Logic Pro MCU profile, SSL V-MIDI Port 9.
        2. TACTILE FADER GESTURES:
           - Unity Gain (0.0 dB): AUTO + SEL or Double-Tap SEL.
           - Minimum Floor (-oo dB): Long-Press SEL (> 0.5s).
           - Motor Interlock: Capacitive touch sense releases clutch instantly.
           - Banking: < PAGE > jumps 8 channels; < BANK > nudges 1 single track.
        3. CUE & SENDS FOCUS MODE (SEND Button / Note 41):
           - Strips 1-2: AUX 1 & 2 master sends; Strips 3-6: CUE 1-4 headphone mixes; Strip 7: Track output; Strip 8: Pan.
        4. PREAMP FOCUS MODE (CHANNEL Button / Note 40):
           - Preamp Gain, +48V double-tap safety, -20dB Pad, 75Hz Low-Cut, Phase Invert, Unison DSP bypass.
        5. PLUG-IN & INSERT INSPECTOR (PLUG-IN Button / Note 43):
           - Keys 1-8: Key 1 = Unison; Keys 2-7 = Inserts 1-6; Key 8 = REC vs MON.
        6. MONITORING & HEARING PROTECTION:
           - Master Monitor Volume: Rotary Wheel (±1 dB/tick). Emergency Mute: Center Circle Key (Note 100).
        7. TALKBACK & MASTER AUX:
           - Channel 25: Slate Talkback mic. Channels 26 & 27: Master AUX 1 & 2 returns.
        8. AI CO-PRODUCER (FINE Key / Note 70):
           - Short press: 3-step acoustic pre-flight inspection; Long press: Opens chat window.
        """

        let systemInstruction = """
        You are S&D Co-Producer, an expert AI audio engineer embedded inside the UA-MCU Bridge for SSL UF8 and Universal Audio Apollo interfaces, running on Local Llama 3.2.
        You have authoritative knowledge of the official hardware specifications, MIDI protocols, surface layouts, gestures, and operational manuals for both the SSL UF8 and UAD Apollo Console.
        When answering user questions:
        1. Understand the user's inquiry in depth using the live Apollo Console telemetry provided below.
        2. If the user asks about silent or zero-input channels, identify which channels are silent (peak ≤ -60 dBFS) and give concrete audio engineering advice (check cables, microphone phantom power +48V, preamp gain).
        3. If the user asks about clipping or overloaded channels, identify the clipping tracks (peak ≥ -0.1 dBFS) and give actionable gain staging advice.
        4. If the user asks about plug-ins, CUE sends, fader positions, or mutes/solos, reference the live channel configuration accurately and explain how to control them on the SSL UF8 hardware.
        5. Reference specific physical hardware controls: AUTO+SEL for 0.0 dB Unity Gain, Long-Press SEL for -oo dB floor, CHANNEL key for Preamp Focus (+48V, Low Cut, Pad, Phase, Gain), SEND key for Cue mixes, PLUG-IN key for DSP parameter pages, FLIP for returning home, and the Center Circle key for emergency Monitor Mute.
        6. Keep explanations clear, musically knowledgeable, structured, and immediately actionable.

        Reference Specification & Manual:
        \(hardwareManualKnowledge)

        \(telemetrySummary)
        """

        let payload: [String: Any] = [
            "model": targetModel,
            "prompt": prompt,
            "system": systemInstruction,
            "stream": false,
            "options": [
                "temperature": 0.7,
                "num_predict": 1024
            ]
        ]

        guard let httpBody = try? JSONSerialization.data(withJSONObject: payload) else {
            if let fb = fallback?() {
                completion(fb)
            } else {
                completion("Failed to serialize Local LLM request payload.")
            }
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = httpBody
        req.timeoutInterval = 75.0

        let session = URLSession(configuration: .default)
        let task = session.dataTask(with: req) { [weak self] data, response, error in
            guard let self = self else { return }
            self.queryLock.lock()
            let wasCancelled = self.isQueryCancelled
            self.activeTask = nil
            self.queryLock.unlock()

            if wasCancelled || (error as NSError?)?.code == NSURLErrorCancelled {
                DispatchQueue.main.async { completion("⏹ *Execution cancelled.*") }
                return
            }

            if let error = error {
                if let fb = fallback?() {
                    DispatchQueue.main.async { completion(fb) }
                } else {
                    DispatchQueue.main.async {
                        completion("Local LLM Error: \(error.localizedDescription)")
                    }
                }
                return
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                if let fb = fallback?() {
                    DispatchQueue.main.async { completion(fb) }
                } else {
                    DispatchQueue.main.async {
                        completion("Failed to parse response from Local LLM (Ollama).")
                    }
                }
                return
            }

            if let reply = json["response"] as? String, !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let formatted = "🧠 **AI Co-Producer Analysis (Local Llama 3.2):**\n\n" + reply.trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async {
                    completion(formatted)
                }
            } else if let err = json["error"] as? String {
                if err.lowercased().contains("not found") && modelOverride == nil {
                    // Try alternative model tag (e.g. if llama3.2 was requested, try llama3.2:3b, or vice-versa)
                    let fallbackTag = targetModel.contains(":") ? (targetModel.components(separatedBy: ":").first ?? targetModel) : "\(targetModel):3b"
                    if fallbackTag != targetModel {
                        self.executeOllamaGenerate(prompt: prompt, uad: uad, auditor: auditor, modelOverride: fallbackTag, fallback: fallback, completion: completion)
                        return
                    }
                }
                if let fb = fallback?() {
                    DispatchQueue.main.async { completion(fb) }
                } else {
                    DispatchQueue.main.async {
                        completion("Local LLM (Ollama) Error: \(err)")
                    }
                }
            } else {
                if let fb = fallback?() {
                    DispatchQueue.main.async { completion(fb) }
                } else {
                    DispatchQueue.main.async {
                        completion("Empty response received from Local LLM.")
                    }
                }
            }
        }

        queryLock.lock()
        if isQueryCancelled {
            queryLock.unlock()
            completion("⏹ *Execution cancelled.*")
            return
        }
        activeTask = task
        queryLock.unlock()
        task.resume()
    }

    // MARK: - Google Gemini REST API Client

    private func queryGeminiAPI(prompt: String, uad: UADClient, auditor: AIAudioAuditor, completion: @escaping (String) -> Void) {
        let cleanKey = geminiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else {
            completion("Gemini API key is not configured. Use 'Set Gemini Key' to enter your API key.")
            return
        }

        var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models/\(geminiModel):generateContent")
        components?.queryItems = [
            URLQueryItem(name: "key", value: cleanKey)
        ]

        guard let url = components?.url else {
            completion("Invalid Gemini API endpoint configuration.")
            return
        }

        let chSummary = uad.channels.values.sorted { $0.id < $1.id }.map {
            "Ch \($0.id + 1) (\($0.name)): fader \(String(format: "%.1f", $0.faderDb))dB, pan \($0.pan == 0 ? "C" : ($0.pan < 0 ? "L" : "R")), mute \($0.mute), solo \($0.solo), peak \(String(format: "%.1f", $0.meterPeak))dBFS"
        }.joined(separator: "\n")

        let hardwareManualKnowledge = """
        OFFICIAL SSL UF8 & UNIVERSAL AUDIO APOLLO BRIDGE MANUAL & SPECIFICATION:
        1. HARDWARE ARCHITECTURE:
           - Controller: Solid State Logic (SSL) UF8 Advanced DAW Controller (8x 100mm 14-bit motorized faders, 8x high-res LCD scribble strips, 8x push rotary V-Pots with 11-LED rings, large channel rotary wheel, 4-way arrow cluster with Center Circle button, mode buttons: CHANNEL, SEND, PLUG-IN, FLIP, FINE, AUTO).
           - Audio Engine: Universal Audio Apollo DSP Mixer (UAMixerEngine daemon listening on raw TCP socket 127.0.0.1:4710).
           - MIDI Layer: macOS CoreMIDI over SSL 360° Layer 3, Logic Pro MCU profile, SSL V-MIDI Port 9.
        2. TACTILE FADER GESTURES:
           - Unity Gain (0.0 dB): Press AUTO + SEL on any track, or double-tap SEL to fly fader to exact 0.0 dB.
           - Minimum Floor (-oo dB): Long-press SEL (> 0.5s) to smoothly pull fader to -oo dB.
           - Motor Interlock: Capacitive touch sense (Notes 104-111) releases motor clutch immediately so automation never fights the engineer's fingers.
           - Banking: < PAGE > jumps 8 channels (Tracks 1-8 -> 9-16 -> 17-24 -> 25-27). < BANK > nudges 1 single track.
        3. SCRIBBLE STRIP DISPLAYS & METERING:
           - Row 1 (Center Screen, SysEx offset 56): Channel name with 4 Hz marquee scrolling for names > 7 characters.
           - Row 2 (Lower Screen, SysEx offset 0): Live decibel level (e.g. -6.0 dB, 0.0 dB), status badges (MUTE, SOLO, BYP).
           - Metering: 16-segment LED VU ladder polling Apollo at 60 FPS (-60 dBFS to 0 dBFS) with red CLIP latch.
        4. CUE & SENDS FOCUS MODE (SEND Button / Note 41):
           - Trigger: Press SEND or double-tap SEL on an already selected track.
           - Fader Layout across 8 strips:
             * Strips 1-2: AUX 1 & AUX 2 master reverb/delay sends (faders=level, mute=bypass, V-Pot=send pan).
             * Strips 3-6: CUE 1, CUE 2, CUE 3, CUE 4 artist headphone cue mixes (HP 1, HP 2, Line 3, Line 4).
             * Strip 7: Track output volume.
             * Strip 8: Track master pan.
           - Channel Stepping: Rotate Jog Wheel or press < BANK > to step between tracks without leaving Sends mode.
           - Exit: Single-tap FLIP returns to Main Mix at current bank. Double-tap FLIP snaps to Channels 1-8.
        5. PREAMP FOCUS MODE (CHANNEL Button / Note 40):
           - Expands selected analog preamp across all 8 physical fader strips:
             * Strip 1: Preamp Gain (+10.0 to +65.0 dB on motorized fader; V-Pot trims +/-1 dB; V-Pot push resets to +10 dB).
             * Strip 2: +48V Phantom Power with Safety Double-Tap Interlock (<0.85s) to protect vintage & ribbon mics. Single tap to turn off.
             * Strip 3: -20 dB Pad toggle.
             * Strip 4: 75 Hz Analog Low-Cut High-Pass Filter toggle.
             * Strip 5: Phase Invert (Ø) polarity flip.
             * Strip 6: Input Source (Mic vs Line; auto-detects front Hi-Z jack lock).
             * Strip 7: Track Output Level & Pan.
             * Strip 8: Unison Analog Modeling DSP Plugin power/bypass (e.g. Neve 1073, UA 610, API Vision).
        6. PLUG-IN & INSERT INSPECTOR (PLUG-IN Button / Note 43):
           - Press PLUG-IN to inspect DSP plugins on the focused track.
           - Number Keys 1-8: Key 1 = Unison; Keys 2-7 = Inserts 1-6; Key 8 = UAD REC (wet) vs MON (dry) toggle.
           - Strip 1: Dedicated to Plug-in Power (On/Off). Displays plugin name (Row 1) and status (Row 2). Fader 1, V-Pot 1, and Mute 1 toggle power.
           - Strips 2-8: Map 7 DSP parameters per page. < PAGE > flips through parameter pages.
        7. MONITORING & HEARING PROTECTION:
           - Master Monitor Volume: Large channel rotary wheel trims Apollo Master Monitor by +/-1.0 dB per tick.
           - Emergency Monitor Mute: Center Circle Key (Note 100, middle of arrow cluster) is permanently dedicated to Master Monitor Mute/Unmute across all modes.
        8. TALKBACK & MASTER AUX RETURNS:
           - Channel 25: Slate Talkback mic (Fader = slate gain; Mute = tactile talkback toggle).
           - Channels 26 & 27: Master AUX 1 & 2 return levels and mutes.
        9. AI CO-PRODUCER (FINE Key / Note 70):
           - Short press: 3-step acoustic pre-flight inspection cycle.
           - Long press (>=600ms) or Cmd+Shift+A: Opens S&D Co-Producer chat window.
        """

        let systemInstruction = """
        You are S&D Co-Producer, the expert AI audio engineer embedded inside the UA-MCU Bridge for Solid State Logic UF8 and Universal Audio Apollo interfaces.
        You have encyclopedic, authoritative knowledge of the official hardware specifications, MIDI protocols, surface layouts, gestures, and operational manuals for both the SSL UF8 and UAD Apollo Console.
        When answering user questions:
        1. Always explain the exact physical hardware buttons, faders, V-Pots, LED tallies, and gestures required on the SSL UF8 surface.
        2. Reference specific hardware functions: e.g., AUTO+SEL for 0.0 dB Unity Gain, Long-Press SEL for -oo dB floor, CHANNEL key for Preamp Focus, SEND key for Cue mixes, PLUG-IN key for DSP parameter pages, FLIP for returning home, and the Center Circle key for emergency Monitor Mute.
        3. Provide professional, world-class audio engineering advice (gain staging, EQ carving, compression ratios, acoustic troubleshooting) tailored to Universal Audio analog modeling plugins (1176, LA-2A, Neve 1073, Pultec, etc.).
        4. Keep explanations clear, structured, and immediately actionable for tactile and screen-reader accessibility.

        Reference Specification & Manual:
        \(hardwareManualKnowledge)

        Current Apollo Mixer State:
        \(chSummary)
        """

        let payload: [String: Any] = [
            "system_instruction": [
                "parts": [["text": systemInstruction]]
            ],
            "contents": [
                ["parts": [["text": prompt]]]
            ],
            "generationConfig": [
                "maxOutputTokens": 8192,
                "temperature": 0.7
            ]
        ]

        guard let httpBody = try? JSONSerialization.data(withJSONObject: payload) else {
            completion("Failed to serialize request payload.")
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(cleanKey, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = httpBody
        req.timeoutInterval = 75.0

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 75.0
        sessionConfig.timeoutIntervalForResource = 90.0
        let session = URLSession(configuration: sessionConfig)

        let task = session.dataTask(with: req) { [weak self] data, resp, err in
            guard let self = self else { return }
            self.queryLock.lock()
            let wasCancelled = self.isQueryCancelled
            self.activeTask = nil
            self.queryLock.unlock()

            if wasCancelled || (err as NSError?)?.code == NSURLErrorCancelled {
                DispatchQueue.main.async {
                    completion("⏹ *Execution cancelled.*")
                }
                return
            }

            if let err = err {
                DispatchQueue.main.async {
                    if (err as NSError).code == NSURLErrorTimedOut {
                        completion("AI Connection Timed Out: Google's Gemini server took longer than 75 seconds to generate reasoning. Spikes in model demand are usually temporary. Please try again.")
                    } else {
                        completion("Gemini Connection Error: \(err.localizedDescription)")
                    }
                }
                return
            }

            if let httpResp = resp as? HTTPURLResponse, httpResp.statusCode == 503 {
                DispatchQueue.main.async {
                    completion("Gemini Service Busy (503): High demand spike on Google servers. Please try again in a few moments.")
                }
                return
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async {
                    completion("Failed to parse response from Gemini.")
                }
                return
            }

            if let candidates = json["candidates"] as? [[String: Any]],
               let first = candidates.first {
                let finishReason = first["finishReason"] as? String
                if let content = first["content"] as? [String: Any],
                   let parts = content["parts"] as? [[String: Any]] {
                    let texts = parts.compactMap { $0["text"] as? String }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    if !texts.isEmpty {
                        var combined = texts.joined(separator: "\n\n")
                        if finishReason == "MAX_TOKENS" || finishReason == "LENGTH" {
                            combined += "\n\n⚠️ *(Note: Response reached maximum token limit. Ask \"continue\" to proceed.)*"
                        }
                        DispatchQueue.main.async {
                            completion(combined)
                        }
                        return
                    }
                }
            }
            if let errorDict = json["error"] as? [String: Any],
               let message = errorDict["message"] as? String {
                DispatchQueue.main.async {
                    completion("Gemini API Error: \(message)")
                }
            } else {
                DispatchQueue.main.async {
                    completion("Received response from Gemini in unrecognized format.")
                }
            }
        }

        queryLock.lock()
        if isQueryCancelled {
            queryLock.unlock()
            completion("⏹ *Execution cancelled.*")
            return
        }
        activeTask = task
        queryLock.unlock()
        task.resume()
    }
}

// MARK: - Reusable Pasteable Text Field, Custom Field Editor & AIChatWindow

public class CustomFieldEditorTextView: NSTextView {
    public override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return menu
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            let chars = (event.charactersIgnoringModifiers ?? "").lowercased()
            if chars == "v" {
                self.paste(nil)
                return true
            } else if chars == "c" {
                self.copy(nil)
                return true
            } else if chars == "x" {
                self.cut(nil)
                return true
            } else if chars == "a" {
                self.selectAll(nil)
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

public class PasteableTextField: NSTextField {
    public override func cancelOperation(_ sender: Any?) {
        if let window = self.window, let delegate = window.delegate as? AIChatWindowController {
            delegate.cancelOperation(sender)
        } else {
            super.cancelOperation(sender)
        }
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return menu
    }

    @objc public func paste(_ sender: Any?) {
        if let editor = self.currentEditor() {
            editor.paste(sender)
        } else if let clip = NSPasteboard.general.string(forType: .string) {
            self.stringValue = clip.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    @objc public func copy(_ sender: Any?) {
        if let editor = self.currentEditor() {
            editor.copy(sender)
        } else if !self.stringValue.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(self.stringValue, forType: .string)
        }
    }

    @objc public func cut(_ sender: Any?) {
        if let editor = self.currentEditor() {
            editor.cut(sender)
        } else if !self.stringValue.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(self.stringValue, forType: .string)
            self.stringValue = ""
        }
    }

    @objc public override func selectAll(_ sender: Any?) {
        if let editor = self.currentEditor() {
            editor.selectAll(sender)
        } else {
            self.selectText(sender)
        }
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 { // Escape
            if let window = self.window, let delegate = window.delegate as? AIChatWindowController {
                delegate.cancelOperation(self)
                return true
            }
        }
        if event.modifierFlags.contains(.command) {
            let chars = (event.charactersIgnoringModifiers ?? "").lowercased()
            if chars == "v" {
                if let clip = NSPasteboard.general.string(forType: .string) {
                    let clean = clip.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let editor = self.currentEditor() {
                        editor.replaceCharacters(in: editor.selectedRange, with: clean)
                    } else {
                        self.stringValue = clean
                    }
                    return true
                }
            } else if chars == "c" {
                let textToCopy = (self.currentEditor()?.selectedRange.length ?? 0 > 0)
                    ? ((self.stringValue as NSString).substring(with: self.currentEditor()!.selectedRange))
                    : self.stringValue
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(textToCopy, forType: .string)
                return true
            } else if chars == "a" {
                self.currentEditor()?.selectAll(nil)
                return true
            } else if chars == "x" {
                if let editor = self.currentEditor() {
                    let sel = editor.selectedRange
                    if sel.length > 0 {
                        let cutStr = (self.stringValue as NSString).substring(with: sel)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(cutStr, forType: .string)
                        editor.replaceCharacters(in: sel, with: "")
                        return true
                    }
                }
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

public class AIChatWindow: NSWindow {
    public override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown && event.modifierFlags.contains(.command) {
            let chars = (event.charactersIgnoringModifiers ?? "").lowercased()
            if chars == "v" {
                if let responder = self.firstResponder as? NSTextView {
                    responder.paste(nil)
                    return
                } else if let field = self.firstResponder as? NSTextField {
                    if let clip = NSPasteboard.general.string(forType: .string) {
                        let clean = clip.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let editor = field.currentEditor() {
                            editor.replaceCharacters(in: editor.selectedRange, with: clean)
                        } else {
                            field.stringValue = clean
                        }
                        return
                    }
                }
            } else if chars == "c" {
                if let responder = self.firstResponder as? NSTextView {
                    responder.copy(nil)
                    return
                } else if let field = self.firstResponder as? NSTextField {
                    let textToCopy = (field.currentEditor()?.selectedRange.length ?? 0 > 0)
                        ? ((field.stringValue as NSString).substring(with: field.currentEditor()!.selectedRange))
                        : field.stringValue
                    if !textToCopy.isEmpty {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(textToCopy, forType: .string)
                    }
                    return
                }
            } else if chars == "x" {
                if let responder = self.firstResponder as? NSTextView {
                    responder.cut(nil)
                    return
                } else if let field = self.firstResponder as? NSTextField {
                    if let editor = field.currentEditor() {
                        let sel = editor.selectedRange
                        if sel.length > 0 {
                            let cutStr = (field.stringValue as NSString).substring(with: sel)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(cutStr, forType: .string)
                            editor.replaceCharacters(in: sel, with: "")
                            return
                        }
                    }
                }
            } else if chars == "a" {
                if let responder = self.firstResponder as? NSTextView {
                    responder.selectAll(nil)
                    return
                } else if let field = self.firstResponder as? NSTextField {
                    field.currentEditor()?.selectAll(nil)
                    return
                }
            } else if chars == "z" {
                if event.modifierFlags.contains(.shift) {
                    if let undoer = self.firstResponder?.undoManager, undoer.canRedo {
                        undoer.redo()
                        return
                    }
                } else {
                    if let undoer = self.firstResponder?.undoManager, undoer.canUndo {
                        undoer.undo()
                        return
                    }
                }
            }
        }
        super.sendEvent(event)
    }
}

public final class ApiKeyDialogAccessoryView: NSView {
    public let inputField: PasteableTextField
    public let pasteButton: NSButton
    public let clearButton: NSButton
    public let hintLabel: NSTextField

    public init(currentKey: String) {
        inputField = PasteableTextField(frame: NSRect(x: 0, y: 38, width: 440, height: 26))
        pasteButton = NSButton(title: "📋 Paste from Clipboard", target: nil, action: nil)
        clearButton = NSButton(title: "Clear", target: nil, action: nil)
        hintLabel = NSTextField(labelWithString: "Accepts all key formats: AIzaSy..., AQ..., Vertex AI & Google Cloud")
        super.init(frame: NSRect(x: 0, y: 0, width: 440, height: 70))

        inputField.stringValue = currentKey
        inputField.placeholderString = "Paste API key (AIzaSy... or AQ...)"
        inputField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        addSubview(inputField)

        pasteButton.bezelStyle = .roundRect
        pasteButton.frame = NSRect(x: 0, y: 6, width: 175, height: 24)
        pasteButton.target = self
        pasteButton.action = #selector(handlePaste)
        addSubview(pasteButton)

        clearButton.bezelStyle = .roundRect
        clearButton.frame = NSRect(x: 182, y: 6, width: 70, height: 24)
        clearButton.target = self
        clearButton.action = #selector(handleClear)
        addSubview(clearButton)

        hintLabel.font = NSFont.systemFont(ofSize: 10)
        hintLabel.textColor = NSColor.secondaryLabelColor
        hintLabel.frame = NSRect(x: 260, y: 6, width: 180, height: 24)
        addSubview(hintLabel)
    }

    public required init?(coder: NSCoder) { fatalError() }

    @objc private func handlePaste() {
        if let clip = NSPasteboard.general.string(forType: .string) {
            inputField.stringValue = clip.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    @objc private func handleClear() {
        inputField.stringValue = ""
    }
}

public final class OllamaConfigDialogAccessoryView: NSView {
    public let endpointField: PasteableTextField
    public let modelField: PasteableTextField
    public let statusLabel: NSTextField
    public let testButton: NSButton
    public let startButton: NSButton

    public init(endpoint: String, model: String) {
        endpointField = PasteableTextField(frame: NSRect(x: 0, y: 78, width: 440, height: 26))
        modelField = PasteableTextField(frame: NSRect(x: 0, y: 38, width: 440, height: 26))
        testButton = NSButton(title: "⚡ Test Endpoint", target: nil, action: nil)
        startButton = NSButton(title: "🚀 Start Ollama Service", target: nil, action: nil)
        statusLabel = NSTextField(labelWithString: "Status: Ready")
        super.init(frame: NSRect(x: 0, y: 0, width: 440, height: 110))

        endpointField.stringValue = endpoint
        endpointField.placeholderString = "http://127.0.0.1:11434"
        endpointField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        addSubview(endpointField)

        modelField.stringValue = model
        modelField.placeholderString = "llama3.2 or llama3.2:3b"
        modelField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        addSubview(modelField)

        testButton.bezelStyle = .roundRect
        testButton.frame = NSRect(x: 0, y: 6, width: 130, height: 24)
        testButton.target = self
        testButton.action = #selector(handleTest)
        addSubview(testButton)

        startButton.bezelStyle = .roundRect
        startButton.frame = NSRect(x: 138, y: 6, width: 160, height: 24)
        startButton.target = self
        startButton.action = #selector(handleStart)
        addSubview(startButton)

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = NSColor.secondaryLabelColor
        statusLabel.frame = NSRect(x: 306, y: 6, width: 134, height: 24)
        addSubview(statusLabel)
    }

    public required init?(coder: NSCoder) { fatalError() }

    @objc private func handleTest() {
        statusLabel.stringValue = "Testing..."
        let ep = endpointField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        OllamaServiceManager.shared.isOllamaRunning(endpoint: ep) { [weak self] running in
            DispatchQueue.main.async {
                self?.statusLabel.stringValue = running ? "● Online" : "○ Offline"
                self?.statusLabel.textColor = running ? NSColor.systemGreen : NSColor.systemRed
            }
        }
    }

    @objc private func handleStart() {
        statusLabel.stringValue = "Starting..."
        let ep = endpointField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        OllamaServiceManager.shared.ensureOllamaRunning(endpoint: ep) { [weak self] running in
            DispatchQueue.main.async {
                self?.statusLabel.stringValue = running ? "● Online (Started)" : "○ Failed to start"
                self?.statusLabel.textColor = running ? NSColor.systemGreen : NSColor.systemRed
            }
        }
    }
}

// ==============================================================================
// MARK: - AI Prompt Examples & Super-Detailed Help Page Catalog
// ==============================================================================

public struct AIPromptExample: Identifiable, Equatable {
    public enum Category: String, CaseIterable {
        case telemetry = "Mixer Telemetry"
        case listening = "Acoustic Listening"
        case cueSends = "CUE Sends & Monitoring"
        case plugins = "UAD Plugins & Inserts"
        case hardware = "UF8 Hardware Surface"
        case faders = "Motorized Faders & Mix"
        case preamp = "Analog Preamp & Unison"
        case history = "History & Snapshots"

        public var icon: String {
            switch self {
            case .telemetry: return "📊"
            case .listening: return "⏱️"
            case .cueSends: return "🎧"
            case .plugins: return "🔌"
            case .hardware: return "🎛️"
            case .faders: return "🎚️"
            case .preamp: return "🎙️"
            case .history: return "↩️"
            }
        }
    }

    public let id: String
    public let category: Category
    public let title: String
    public let prompt: String
    public let description: String
    public let hardwareEffect: String
    public let isHighlighted: Bool

    public init(
        id: String,
        category: Category,
        title: String,
        prompt: String,
        description: String,
        hardwareEffect: String,
        isHighlighted: Bool = false
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.prompt = prompt
        self.description = description
        self.hardwareEffect = hardwareEffect
        self.isHighlighted = isHighlighted
    }
}

public struct AIPromptCatalog {
    public static let all: [AIPromptExample] = [
        // 1. Mixer Telemetry
        AIPromptExample(
            id: "tel-full-list",
            category: .telemetry,
            title: "Full Channel Inventory",
            prompt: "Full list pls",
            description: "Audits all 32 Apollo mixer channels across all 8-fader UF8 banks, detailing channel names, physical inputs (Mic/Line/Hi-Z), fader levels in dB, mutes, solos, and stereo panning.",
            hardwareEffect: "Queries Apollo DSP state with 0ms latency; preserves tactile fader positions without disturbance.",
            isHighlighted: true
        ),
        AIPromptExample(
            id: "tel-overload",
            category: .telemetry,
            title: "Converter Overload Scan",
            prompt: "Tell me channels in Overloaded",
            description: "Scans all 32 channels for 0 dBFS converter clipping, peak headroom violations, and active clip counter flags.",
            hardwareEffect: "Reports peak dBFS levels. Triggers visual warning on UF8 scribble strip if audio clips converter."
        ),
        AIPromptExample(
            id: "tel-zero-input",
            category: .telemetry,
            title: "Silent / Dead Input Detection",
            prompt: "Which channels have zero input?",
            description: "Instant scan for open or silent converter inputs with signal below -96 dBFS, identifying unplugged mics or inactive hardware sends.",
            hardwareEffect: "Identifies unplugged physical inputs for fast patching and session verification."
        ),
        AIPromptExample(
            id: "tel-active-signal",
            category: .telemetry,
            title: "Active Audio Stream Scan",
            prompt: "Which channels have signal?",
            description: "Detects all tracks currently passing live audio, ranking them by peak dBFS volume for quick monitoring.",
            hardwareEffect: "Zero-latency readout of active converter streams across all 32 channels."
        ),
        AIPromptExample(
            id: "tel-mute-solo",
            category: .telemetry,
            title: "Mute & Solo Status Audit",
            prompt: "Show mute and solo status",
            description: "Inspects which tracks have MUTE or SOLO engaged across the entire 32-channel console.",
            hardwareEffect: "Correlates directly with UF8 physical illuminated MUTE and SOLO switches."
        ),
        AIPromptExample(
            id: "tel-summary",
            category: .telemetry,
            title: "Console Session Summary",
            prompt: "Console summary",
            description: "Provides a birds-eye overview of the entire Apollo session: active channels, gain staging headroom, monitor volume, and DSP health.",
            hardwareEffect: "Summarizes mixer state without altering tactile fader or encoder positions."
        ),
        AIPromptExample(
            id: "tel-fader-levels",
            category: .telemetry,
            title: "Fader Levels Inspection",
            prompt: "Show fader levels",
            description: "Reports volume fader levels in decibels for all 32 channels, noting unity gain offsets and muted tracks.",
            hardwareEffect: "Reflects physical position of all 8 UF8 motorized touch faders."
        ),

        // 2. Acoustic Listening
        AIPromptExample(
            id: "list-10s-audit",
            category: .listening,
            title: "10-Second Telemetry Audit",
            prompt: "listening 10 secs and analyze incoming signals",
            description: "Captures 10 seconds of high-resolution peak telemetry across all 32 channels, computes dynamic range, detects clipping spikes, and saves a markdown report.",
            hardwareEffect: "Flashes RECORD/FINE indicator on UF8 during capture; rings tactile bell upon completion.",
            isHighlighted: true
        ),
        AIPromptExample(
            id: "list-5s-headroom",
            category: .listening,
            title: "5-Second Headroom Check",
            prompt: "listening 5 secs and check headroom",
            description: "Monitors active performance for 5 seconds to evaluate transient peak headroom relative to -18 dBFS nominal target.",
            hardwareEffect: "Samples DSP converter levels for 5000ms with live countdown."
        ),
        AIPromptExample(
            id: "list-audit-mix",
            category: .listening,
            title: "Mix Pre-Flight Inspection",
            prompt: "Audit mix",
            description: "Runs AI Audio Auditor across all channels, checking for crest factor imbalances, converter overloads, and stereo phase issues.",
            hardwareEffect: "Compiles audit suggestions; VoiceAnnouncer reads out pre-flight summary."
        ),
        AIPromptExample(
            id: "list-dynamic-range",
            category: .listening,
            title: "Dynamic Range Analysis",
            prompt: "listening 8 secs and evaluate dynamic range",
            description: "Measures crest factor and micro-dynamics across active stems to recommend compression ratio targets.",
            hardwareEffect: "High-resolution telemetry capture without audio interruption."
        ),

        // 3. CUE Sends & Monitoring
        AIPromptExample(
            id: "cue-matrix",
            category: .cueSends,
            title: "Matrix CUE Overview",
            prompt: "Show CUE sends",
            description: "Displays a complete matrix of all 4 Apollo CUE headphone buses (HP1, HP2, Line 3-4, Line 7-8) and Aux 1-2 reverb/delay returns.",
            hardwareEffect: "Mirrors Apollo Console CUE matrix without changing mix levels.",
            isHighlighted: true
        ),
        AIPromptExample(
            id: "cue-hp1-status",
            category: .cueSends,
            title: "Headphone CUE 1 Status",
            prompt: "Show CUE 1 sends",
            description: "Lists all audio channels actively sending signal to Artist Headphone CUE 1, including send levels (in dB) and pre/post fader status.",
            hardwareEffect: "Zero-latency readout of performer monitor feed."
        ),
        AIPromptExample(
            id: "cue-vocal-inspect",
            category: .cueSends,
            title: "Vocal Monitor CUE Inspection",
            prompt: "CUE sends for Vocal",
            description: "Inspects send levels for the Vocal channel across all 4 CUE buses and Aux returns.",
            hardwareEffect: "Verifies artist monitor balance before recording takes."
        ),
        AIPromptExample(
            id: "cue-set-unity",
            category: .cueSends,
            title: "Direct CUE Level Setting",
            prompt: "Set CUE 1 on Track 1 to 0 dB",
            description: "Snaps the CUE 1 send fader on Track 1 to unity gain (0.0 dB) for direct artist monitoring.",
            hardwareEffect: "Instantly updates Apollo Console CUE 1 send pot for Track 1."
        ),
        AIPromptExample(
            id: "cue-mute-c2",
            category: .cueSends,
            title: "Mute Performer Cue Feed",
            prompt: "Mute C2 level for System out",
            description: "Quickly mutes or zeroes the CUE 2 feed to prevent unwanted headphone bleed during sensitive vocal takes.",
            hardwareEffect: "Engages CUE 2 mute relay on Apollo hardware."
        ),

        // 4. UAD Plugins & Inserts
        AIPromptExample(
            id: "plug-inventory",
            category: .plugins,
            title: "Full DSP Plugin Inventory",
            prompt: "Show plugins",
            description: "Enumerates all 32 Apollo channels, listing active UAD-2 DSP plugins, insert slots (1–4), and bypass states.",
            hardwareEffect: "Queries Console plug-in architecture with 0ms latency.",
            isHighlighted: true
        ),
        AIPromptExample(
            id: "plug-track1",
            category: .plugins,
            title: "Channel Insert Inspection",
            prompt: "Plugins on Track 1",
            description: "Inspects loaded plug-ins on Track 1 (e.g., Neve 1073, 1176LN, LA-2A, Pultec EQP-1A), detailing slot numbers and bypass status.",
            hardwareEffect: "Prepares track parameters for tactile UF8 V-Pot control."
        ),
        AIPromptExample(
            id: "plug-unison",
            category: .plugins,
            title: "Unison Preamp Modeling Audit",
            prompt: "Show Unison plugins",
            description: "Identifies which analog preamp channels are running Unison preamp emulations with physical impedance switching.",
            hardwareEffect: "Reports physical hardware impedance re-matching relays."
        ),
        AIPromptExample(
            id: "plug-bypassed",
            category: .plugins,
            title: "Bypassed Plugin Detection",
            prompt: "Which plugins are bypassed?",
            description: "Finds all inserted UAD plugins currently bypassed or disabled across the session.",
            hardwareEffect: "Helps recover DSP resources and pinpoint inactive processors."
        ),
        AIPromptExample(
            id: "plug-toggle-bypass",
            category: .plugins,
            title: "Instant Insert Bypass",
            prompt: "Bypass plugin on Track 1",
            description: "Toggles bypass on the first active insert slot of Track 1 for A/B critical listening.",
            hardwareEffect: "Instantly updates Apollo DSP plugin bypass relay."
        ),
        AIPromptExample(
            id: "plug-bypass-all",
            category: .plugins,
            title: "Global Plugin Bypass",
            prompt: "Bypass all plugins",
            description: "Bypasses all inserted plugins and Unison models across all 32 Apollo channels for instant clean dry mix comparison.",
            hardwareEffect: "Disables all active DSP plugin power relays across the console."
        ),
        AIPromptExample(
            id: "plug-enable-all",
            category: .plugins,
            title: "Global Plugin Enable",
            prompt: "Enable all plugins",
            description: "Re-engages all inserted plugins and Unison models across the entire Apollo console.",
            hardwareEffect: "Enables all DSP plugin power relays across all channels."
        ),
        AIPromptExample(
            id: "plug-param-setting",
            category: .plugins,
            title: "Direct Plugin Parameter Tweak",
            prompt: "Set ratio to 4:1 on vocal",
            description: "Directly adjusts compression ratio, attack, release, or peak reduction on inserted plugins without touching a mouse.",
            hardwareEffect: "Dispatches parameter value directly to Apollo DSP and refreshes UF8 LCD scribble strips."
        ),

        // 5. UF8 Hardware Surface
        AIPromptExample(
            id: "hw-preamp-mode",
            category: .hardware,
            title: "Preamp Focus Mode Guide",
            prompt: "How does Preamp Mode work on UF8?",
            description: "Explains how the SSL UF8 8-fader surface transforms into an analog preamp controller: Gain on Strip 1, +48V on Strip 2, Pad on Strip 3, Low-Cut on Strip 4, Phase on Strip 5.",
            hardwareEffect: "Full documentation of the CHANNEL button hardware workflow.",
            isHighlighted: true
        ),
        AIPromptExample(
            id: "hw-sends-mode",
            category: .hardware,
            title: "Sends Focus Mode Guide",
            prompt: "Show Sends Focus Mode guide",
            description: "Walks through how the SEND button maps Aux 1/2 and CUE 1–4 across the 8 motorized faders for tactile headphone mixing.",
            hardwareEffect: "Documents SEND key layout and Channel Wheel track stepping."
        ),
        AIPromptExample(
            id: "hw-plugin-mode",
            category: .hardware,
            title: "Tactile Plug-in Inspector Guide",
            prompt: "Show Plugin Mode guide",
            description: "Describes using the PLUG-IN button and UF8 Number keys 1–8 to inspect and tweak DSP parameters using motorized faders and rotary encoders.",
            hardwareEffect: "Documents PLUG-IN key hardware mapping."
        ),
        AIPromptExample(
            id: "hw-bank1",
            category: .hardware,
            title: "Physical Bank Navigation",
            prompt: "Bank 1",
            description: "Navigates the SSL UF8 to Bank 1 (Channels 1–8), moving motorized faders to reflect tracks 1 through 8.",
            hardwareEffect: "Faders snap to current Bank 1 positions; scribble strips update."
        ),
        AIPromptExample(
            id: "hw-main-mix",
            category: .hardware,
            title: "Return to Main Mix",
            prompt: "Main mix",
            description: "Exits any active focus mode (Sends, Preamp, Plugin) and returns the UF8 to the standard 32-channel mixer layout.",
            hardwareEffect: "Motorized faders and V-Pots return to channel volume and pan."
        ),

        // 6. Motorized Faders & Mix
        AIPromptExample(
            id: "fad-unity-reset",
            category: .faders,
            title: "0 dB Unity Gain Reset",
            prompt: "How do I reset faders to 0 dB unity on UF8?",
            description: "Instructions on using AUTO+SEL or Double-Tap SEL on any fader to snap motorized touch faders to exact 0.0 dB unity gain.",
            hardwareEffect: "Details motorized touch interlock and snap mechanics.",
            isHighlighted: true
        ),
        AIPromptExample(
            id: "fad-set-infinity",
            category: .faders,
            title: "Zero All Channels (-oo dB Floor)",
            prompt: "Set -infinite dB for all channels",
            description: "Smoothly pulls all 32 motorized faders down to minus infinity (-144 dB), completely muting the console floor for safety.",
            hardwareEffect: "Motorized faders physically glide to bottom stops with smooth deceleration."
        ),
        AIPromptExample(
            id: "fad-set-track1",
            category: .faders,
            title: "Single Track Fader Set",
            prompt: "Set track 1 to 0 dB",
            description: "Commands motorized fader on Channel 1 to glide to 0.0 dB unity gain.",
            hardwareEffect: "Fader 1 servo moves to 0 dB position and updates Apollo Console."
        ),
        AIPromptExample(
            id: "fad-vocal-trim",
            category: .faders,
            title: "Vocal Level Trimming",
            prompt: "Fader vocal to -6 dB",
            description: "Sets the Vocal track fader to -6.0 dB, providing optimal headroom for master summing.",
            hardwareEffect: "Vocal fader glides to -6.0 dB on both Apollo and UF8."
        ),
        AIPromptExample(
            id: "fad-rough-mix",
            category: .faders,
            title: "One-Touch Rough Mix",
            prompt: "Rough mix",
            description: "Applies an intelligent gain-staged rough balance across all active channels based on measured peak signal levels.",
            hardwareEffect: "All motorized faders dynamically move into a balanced rough mix."
        ),

        // 7. Analog Preamp & Unison
        AIPromptExample(
            id: "pre-48v",
            category: .preamp,
            title: "+48V Phantom Power Safety",
            prompt: "Turn on 48V on track 1",
            description: "Engages 48V phantom power on Track 1's analog preamp with double-confirmation safety logic to protect vintage ribbon mics.",
            hardwareEffect: "Clicks physical Apollo preamp 48V relay; illuminates UF8 Mute 2 LED.",
            isHighlighted: true
        ),
        AIPromptExample(
            id: "pre-lowcut",
            category: .preamp,
            title: "75 Hz Low-Cut High-Pass Filter",
            prompt: "Low cut on vocal",
            description: "Engages the analog 75 Hz 12 dB/octave high-pass filter on the Vocal channel to eliminate mic stand rumble and HVAC noise.",
            hardwareEffect: "Engages Apollo analog high-pass filter relay."
        ),
        AIPromptExample(
            id: "pre-phase-flip",
            category: .preamp,
            title: "Phase Invert Polarity Flip",
            prompt: "Invert phase SD-Bottom",
            description: "Flips 180° polarity on Snare Bottom to achieve phase alignment with Snare Top.",
            hardwareEffect: "Flips analog phase circuit; illuminates scribble strip Ø indicator."
        ),
        AIPromptExample(
            id: "pre-gain-set",
            category: .preamp,
            title: "Preamp Gain Target",
            prompt: "Set track 1 gain to +45 dB",
            description: "Adjusts analog preamp gain to +45.0 dB for optimal dynamic microphone level.",
            hardwareEffect: "Steps digitally controlled analog preamp resistor ladder."
        ),

        // 8. History & Snapshots
        AIPromptExample(
            id: "hist-undo",
            category: .history,
            title: "Mixer Undo (-1 Step)",
            prompt: "Undo",
            description: "Reverts the last console change (fader move, mute, solo, preamp switch) back to its previous state.",
            hardwareEffect: "Motorized faders physically fly back to their prior positions.",
            isHighlighted: true
        ),
        AIPromptExample(
            id: "hist-redo",
            category: .history,
            title: "Mixer Redo",
            prompt: "Redo",
            description: "Re-applies the most recently undone mixer modification.",
            hardwareEffect: "Faders and switches re-apply the forward state change."
        ),
        AIPromptExample(
            id: "hist-stepback",
            category: .history,
            title: "Revert to Previous Step",
            prompt: "Go back to -1 step back history",
            description: "Natural language command to undo the immediate prior mixer adjustment.",
            hardwareEffect: "Restores previous snapshot across all 32 channels."
        )
    ]

    public static var highlighted: [AIPromptExample] {
        return all.filter { $0.isHighlighted }
    }

    public static func byCategory(_ category: AIPromptExample.Category) -> [AIPromptExample] {
        return all.filter { $0.category == category }
    }

    public static func search(query: String, category: AIPromptExample.Category? = nil) -> [AIPromptExample] {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all.filter { example in
            if let cat = category, example.category != cat {
                return false
            }
            if cleanQuery.isEmpty {
                return true
            }
            return example.title.lowercased().contains(cleanQuery) ||
                   example.prompt.lowercased().contains(cleanQuery) ||
                   example.description.lowercased().contains(cleanQuery) ||
                   example.hardwareEffect.lowercased().contains(cleanQuery) ||
                   example.category.rawValue.lowercased().contains(cleanQuery)
        }
    }

    public static func generateChatHelpSummary() -> String {
        var lines: [String] = []
        lines.append("🤖 **S&D Co-Producer • Complete Prompt Examples & Command Guide**")
        lines.append("Here is the categorized guide of natural language commands. Click **'📖 Prompt Guide'** in the top bar to browse the interactive Help Page with 1-click execution!")
        lines.append("")

        for cat in AIPromptExample.Category.allCases {
            let items = byCategory(cat)
            lines.append("### \(cat.icon) \(cat.rawValue) (\(items.count) Examples)")
            for item in items {
                lines.append("• **`\(item.prompt)`** — *\(item.title)*: \(item.description) *(Hardware: \(item.hardwareEffect))*")
            }
            lines.append("")
        }

        lines.append("💡 **Pro-Tip**: Tap any prompt chip below or click **'📖 All Examples ↗'** to open the full Help window!")
        return lines.joined(separator: "\n")
    }

    public static func computeContextualSuggestions(query: String, reply: String) -> [(label: String, prompt: String)] {
        let lowerQ = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerR = reply.lowercased()

        // 1. Overload / Clipping query
        if AIChatEngine.isOverloadQuery(lowerQ) || lowerQ.contains("clipping") || lowerQ.contains("overload") || lowerQ.contains("clip") {
            if lowerR.contains("clipping") || lowerR.contains("overloaded") || lowerR.contains("exceeded") || lowerR.contains("⚠️") || lowerR.contains("0.0 dbfs") {
                return [
                    ("🎚️ Zero All Faders (-oo)", "Set -infinite dB for all channels"),
                    ("🎙️ Preamp Focus Guide", "How does Preamp Mode work on UF8?"),
                    ("⏱️ Re-listen 5s & Verify", "listening 5 secs and check headroom"),
                    ("↩️ Undo Mixer Change", "Undo"),
                    ("🔇 Silent Channels", "Which channels have zero input?"),
                    ("📊 Console Summary", "Console summary")
                ]
            } else {
                return [
                    ("⏱️ Listen 10s for Peaks", "listening 10 secs and analyze incoming signals"),
                    ("🎧 Check CUE Sends", "Show CUE sends"),
                    ("🔌 Inspect Plugins", "Show plugins"),
                    ("📋 Full Channel List", "Full list pls"),
                    ("📊 Console Summary", "Console summary"),
                    ("🎚️ 0 dB Unity Reset", "How do I reset faders to 0 dB unity on UF8?")
                ]
            }
        }

        // 2. Zero Input / Silent Channels query
        if AIChatEngine.isZeroInputQuery(lowerQ) || lowerQ.contains("silent") || lowerQ.contains("dead input") {
            return [
                ("⚡ Check Overloaded Tracks", "Tell me channels in Overloaded"),
                ("🎙️ Turn on 48V on Track 1", "Turn on 48V on track 1"),
                ("🎙️ Preamp Focus Guide", "How does Preamp Mode work on UF8?"),
                ("📋 Full Channel List", "Full list pls"),
                ("⏱️ Listen 10s & Test Inputs", "listening 10 secs and analyze incoming signals"),
                ("📊 Console Summary", "Console summary")
            ]
        }

        // 3. Timed Listening & Acoustic Audit (must be evaluated before active signals because queries like 'listening 10 secs and analyze incoming signals' contain 'signals')
        if lowerQ.contains("listen") || lowerQ.contains("audit") || lowerQ.contains("pre-flight") || AIChatEngine.parseTimedListeningIntent(lowerQ) != nil {
            return [
                ("⚡ Overloaded Tracks", "Tell me channels in Overloaded"),
                ("🔇 Silent Channels", "Which channels have zero input?"),
                ("🎚️ One-Touch Rough Mix", "Rough mix"),
                ("🎧 Check CUE Sends", "Show CUE sends"),
                ("⏱️ Re-listen 10s", "listening 10 secs and analyze incoming signals"),
                ("📋 Full Channel List", "Full list pls")
            ]
        }

        // 4. Full Channel List / Console Summary / Active Streams
        if AIChatEngine.isFullChannelListQuery(lowerQ) || AIChatEngine.isConsoleSummaryQuery(lowerQ) || AIChatEngine.isActiveSignalQuery(lowerQ) {
            return [
                ("⚡ Overloaded Tracks", "Tell me channels in Overloaded"),
                ("🔇 Silent Channels", "Which channels have zero input?"),
                ("🎧 CUE Sends Matrix", "Show CUE sends"),
                ("🔌 DSP Plugins", "Show plugins"),
                ("🎚️ 0 dB Unity Reset", "How do I reset faders to 0 dB unity on UF8?"),
                ("⏱️ Listen 10s & Analyze", "listening 10 secs and analyze incoming signals")
            ]
        }

        // 5. CUE Sends & Monitoring
        if AIChatEngine.isCueQuery(lowerQ) || lowerQ.contains("cue") || lowerQ.contains("headphone") || lowerQ.contains("aux send") {
            return [
                ("🎧 CUE 1 Sends", "Show CUE 1 sends"),
                ("🎧 CUE 2 Sends", "Show CUE 2 sends"),
                ("🎛️ Sends Focus Mode Guide", "Show Sends Focus Mode guide"),
                ("🎚️ Set CUE 1 Track 1 to 0 dB", "Set CUE 1 on Track 1 to 0 dB"),
                ("🔇 Mute CUE 2 Output", "Mute C2 level for System out"),
                ("📋 Full Channel List", "Full list pls")
            ]
        }

        // 6. UAD Plugins & Inserts
        if AIChatEngine.isPluginQuery(lowerQ) || lowerQ.contains("plugin") || lowerQ.contains("insert") || lowerQ.contains("unison") {
            return [
                ("🔌 Show Unison Preamps", "Show Unison plugins"),
                ("🔌 Bypassed Plugins", "Which plugins are bypassed?"),
                ("🔌 Plugins on Track 1", "Plugins on Track 1"),
                ("🎛️ Tactile Plug-in Guide", "Show Plugin Mode guide"),
                ("⚡ Check Overloaded Tracks", "Tell me channels in Overloaded"),
                ("📊 Console Summary", "Console summary")
            ]
        }

        // 7. Preamp & Analog Controls
        if lowerQ.contains("preamp") || lowerQ.contains("48v") || lowerQ.contains("phantom") || lowerQ.contains("low cut") || lowerQ.contains("phase") || lowerQ.contains("gain") {
            return [
                ("🎙️ Preamp Focus Guide", "How does Preamp Mode work on UF8?"),
                ("⚡ 48V on Track 1", "Turn on 48V on track 1"),
                ("🔉 75 Hz Low Cut on Vocal", "Low cut on vocal"),
                ("🔄 Invert Phase SD-Bottom", "Invert phase SD-Bottom"),
                ("🎛️ Return to Main Mix", "Main mix"),
                ("⏱️ Listen 10s & Test Mic", "listening 10 secs and analyze incoming signals")
            ]
        }

        // 8. Motorized Faders / Volume / Pan / Snap
        if lowerQ.contains("fader") || lowerQ.contains("volume") || lowerQ.contains("unity") || lowerQ.contains("0 db") || lowerQ.contains("pan") || lowerQ.contains("rough mix") || AIChatEngine.isSetAllInfinityQuery(lowerQ) {
            return [
                ("↩️ Undo Mixer Change", "Undo"),
                ("🎚️ 0 dB Unity Gesture Guide", "How do I reset faders to 0 dB unity on UF8?"),
                ("🎚️ One-Touch Rough Mix", "Rough mix"),
                ("🎚️ Set -oo dB All Channels", "Set -infinite dB for all channels"),
                ("📊 Console Summary", "Console summary"),
                ("⚡ Check Overloaded Tracks", "Tell me channels in Overloaded")
            ]
        }

        // 9. Undo / Redo / History
        if AIChatEngine.isUndoQuery(lowerQ) || AIChatEngine.isRedoQuery(lowerQ) || lowerQ.contains("history") {
            return [
                ("↩️ Undo Again", "Undo"),
                ("🔁 Redo Forward", "Redo"),
                ("📊 Console Summary", "Console summary"),
                ("🎚️ 0 dB Unity Reset", "How do I reset faders to 0 dB unity on UF8?"),
                ("📋 Full Channel List", "Full list pls"),
                ("⏱️ Listen 10s & Verify", "listening 10 secs and analyze incoming signals")
            ]
        }

        // 10. Default / Fallback suggestions
        return [
            ("⏱️ Listen 10s & Analyze", "listening 10 secs and analyze incoming signals"),
            ("📋 Full list pls", "Full list pls"),
            ("⚡ Overloaded tracks", "Tell me channels in Overloaded"),
            ("🎧 CUE Sends", "Show CUE sends"),
            ("🔌 Plugins", "Show plugins"),
            ("🎚️ 0 dB Unity", "How do I reset faders to 0 dB unity on UF8?"),
            ("🎙️ Preamp Mode", "How does Preamp Mode work on UF8?"),
            ("📊 Console Summary", "Console summary")
        ]
    }
}

// MARK: - Dedicated Prompt Examples Help Page Window Controller

public final class AIPromptHelpWindowController: NSWindowController, NSSearchFieldDelegate {
    public static let shared = AIPromptHelpWindowController()

    private var currentCategory: AIPromptExample.Category? = nil
    private var searchQuery: String = ""
    private var searchField: NSSearchField!
    private var categorySegmented: NSSegmentedControl!
    private var canvasView: FlippedCanvasView!
    private var scrollView: NSScrollView!
    private var countLabel: NSTextField!

    public var onSelectPrompt: ((String) -> Void)?

    public init() {
        let win = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 780, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "S&D Co-Producer • Prompt Examples & Command Guide"
        win.minSize = NSSize(width: 660, height: 500)
        win.backgroundColor = NSColor(red: 0.085, green: 0.09, blue: 0.105, alpha: 1.0)
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        super.init(window: win)
        setupUI()
    }

    public required init?(coder: NSCoder) { fatalError() }

    public func showHelp(relativeTo parentWindow: NSWindow? = nil, onSelectPrompt: ((String) -> Void)? = nil) {
        self.onSelectPrompt = onSelectPrompt
        guard let win = self.window else { return }

        // Guarantee help window level matches or exceeds chat window (.floating) so it never gets hidden behind
        let parentLevelRaw = parentWindow?.level.rawValue ?? NSWindow.Level.floating.rawValue
        let targetLevelRaw = max(parentLevelRaw, NSWindow.Level.floating.rawValue)
        win.level = NSWindow.Level(targetLevelRaw)

        let screen = parentWindow?.screen ?? win.screen ?? NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        if let parent = parentWindow {
            let parentFrame = parent.frame
            let helpW = win.frame.width
            let helpH = win.frame.height

            // Position directly to the LEFT of the chat window with a 12pt margin
            var targetX = parentFrame.minX - helpW - 12
            // Align tops with the chat window
            var targetY = parentFrame.maxY - helpH

            // Boundary protection: If targetX falls off the left screen edge, check if right side fits
            if targetX < visibleFrame.minX + 12 {
                if parentFrame.maxX + helpW + 12 <= visibleFrame.maxX {
                    targetX = parentFrame.maxX + 12
                } else {
                    targetX = visibleFrame.minX + 12
                }
            }

            // Clamp Y within visible screen bounds
            targetY = max(visibleFrame.minY + 16, min(targetY, visibleFrame.maxY - helpH - 6))
            win.setFrameOrigin(NSPoint(x: targetX, y: targetY))
        } else {
            let x = max(visibleFrame.minX + 24, visibleFrame.maxX - win.frame.width - 720)
            let y = visibleFrame.maxY - win.frame.height - 24
            win.setFrameOrigin(NSPoint(x: x, y: max(visibleFrame.minY + 16, y)))
        }

        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
        if let parent = parentWindow {
            win.order(.above, relativeTo: parent.windowNumber)
        }
        renderCards()
    }

    private func setupUI() {
        guard let win = window, let contentView = win.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor(red: 0.085, green: 0.09, blue: 0.105, alpha: 1.0).cgColor

        // Top Header
        let headerH: CGFloat = 110
        let headerView = NSView(frame: NSRect(x: 0, y: win.frame.height - headerH, width: win.frame.width, height: headerH))
        headerView.autoresizingMask = [.width, .minYMargin]
        contentView.addSubview(headerView)

        let sparkle = NSTextField(labelWithString: "✦")
        sparkle.font = NSFont.systemFont(ofSize: 22, weight: .bold)
        sparkle.textColor = NSColor(red: 0.45, green: 0.65, blue: 1.0, alpha: 1.0)
        sparkle.frame = NSRect(x: 24, y: headerH - 38, width: 26, height: 26)
        headerView.addSubview(sparkle)

        let titleLabel = NSTextField(labelWithString: "S&D Co-Producer • Prompt Examples & Command Guide")
        titleLabel.font = NSFont.boldSystemFont(ofSize: 16)
        titleLabel.textColor = NSColor.white
        titleLabel.frame = NSRect(x: 54, y: headerH - 36, width: 580, height: 22)
        headerView.addSubview(titleLabel)

        let subtitleLabel = NSTextField(labelWithString: "Super-detailed catalog of 38+ offline 0ms telemetry commands & acoustic reasoning prompts.")
        subtitleLabel.font = NSFont.systemFont(ofSize: 12)
        subtitleLabel.textColor = NSColor(white: 0.60, alpha: 1.0)
        subtitleLabel.frame = NSRect(x: 54, y: headerH - 58, width: 620, height: 18)
        headerView.addSubview(subtitleLabel)

        // Search Field
        searchField = NSSearchField(frame: NSRect(x: 24, y: 14, width: 240, height: 28))
        searchField.placeholderString = "Search commands..."
        searchField.target = self
        searchField.action = #selector(handleSearchChanged(_:))
        searchField.delegate = self
        headerView.addSubview(searchField)

        // Category Segmented Control
        let categories = ["All (\(AIPromptCatalog.all.count))"] + AIPromptExample.Category.allCases.map { "\($0.icon) \($0.rawValue.replacingOccurrences(of: " & Monitoring", with: "").replacingOccurrences(of: " & Inserts", with: "").replacingOccurrences(of: " & Unison", with: "").replacingOccurrences(of: " & Snapshots", with: "").replacingOccurrences(of: " & Mix", with: ""))" }
        categorySegmented = NSSegmentedControl(labels: categories, trackingMode: .selectOne, target: self, action: #selector(handleCategorySelected(_:)))
        categorySegmented.selectedSegment = 0
        categorySegmented.segmentStyle = .roundRect
        categorySegmented.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        categorySegmented.frame = NSRect(x: 274, y: 14, width: win.frame.width - 298, height: 28)
        categorySegmented.autoresizingMask = [.width]
        headerView.addSubview(categorySegmented)

        let div = NSBox(frame: NSRect(x: 0, y: 0, width: win.frame.width, height: 1))
        div.boxType = .separator
        div.autoresizingMask = [.width]
        headerView.addSubview(div)

        // Bottom Footer Bar
        let footerH: CGFloat = 46
        let footerView = NSView(frame: NSRect(x: 0, y: 0, width: win.frame.width, height: footerH))
        footerView.autoresizingMask = [.width, .maxYMargin]
        footerView.wantsLayer = true
        footerView.layer?.backgroundColor = NSColor(red: 0.10, green: 0.105, blue: 0.125, alpha: 1.0).cgColor
        contentView.addSubview(footerView)

        let footerDiv = NSBox(frame: NSRect(x: 0, y: footerH - 1, width: win.frame.width, height: 1))
        footerDiv.boxType = .separator
        footerDiv.autoresizingMask = [.width]
        footerView.addSubview(footerDiv)

        countLabel = NSTextField(labelWithString: "Showing \(AIPromptCatalog.all.count) prompt examples")
        countLabel.font = NSFont.systemFont(ofSize: 12)
        countLabel.textColor = NSColor(white: 0.65, alpha: 1.0)
        countLabel.frame = NSRect(x: 24, y: 13, width: 350, height: 20)
        footerView.addSubview(countLabel)

        let doneBtn = NSButton(title: "Done (Esc)", target: self, action: #selector(handleDone))
        doneBtn.bezelStyle = .roundRect
        doneBtn.font = NSFont.boldSystemFont(ofSize: 12)
        doneBtn.frame = NSRect(x: win.frame.width - 110, y: 10, width: 90, height: 26)
        doneBtn.autoresizingMask = [.minXMargin]
        footerView.addSubview(doneBtn)

        // Middle Scroll View & Canvas
        let scrollY = footerH
        let scrollH = win.frame.height - headerH - footerH
        scrollView = NSScrollView(frame: NSRect(x: 0, y: scrollY, width: win.frame.width, height: scrollH))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        canvasView = FlippedCanvasView(frame: NSRect(x: 0, y: 0, width: scrollView.bounds.width, height: scrollView.bounds.height))
        canvasView.wantsLayer = true
        canvasView.layer?.backgroundColor = NSColor(red: 0.085, green: 0.09, blue: 0.105, alpha: 1.0).cgColor
        scrollView.documentView = canvasView
        contentView.addSubview(scrollView)

        renderCards()
    }

    @objc private func handleSearchChanged(_ sender: NSSearchField) {
        searchQuery = sender.stringValue
        renderCards()
    }

    public func controlTextDidChange(_ obj: Notification) {
        if let field = obj.object as? NSSearchField {
            searchQuery = field.stringValue
            renderCards()
        }
    }

    @objc private func handleCategorySelected(_ sender: NSSegmentedControl) {
        let idx = sender.selectedSegment
        if idx == 0 {
            currentCategory = nil
        } else {
            let cases = AIPromptExample.Category.allCases
            let catIndex = idx - 1
            if catIndex >= 0 && catIndex < cases.count {
                currentCategory = cases[catIndex]
            }
        }
        renderCards()
    }

    @objc private func handleDone() {
        self.window?.close()
    }

    public func renderCards() {
        guard let canvas = canvasView, let scroll = scrollView else { return }
        canvas.subviews.forEach { $0.removeFromSuperview() }

        let items = AIPromptCatalog.search(query: searchQuery, category: currentCategory)
        countLabel.stringValue = "Showing \(items.count) of \(AIPromptCatalog.all.count) prompt examples"

        let canvasWidth = scroll.contentSize.width > 0 ? scroll.contentSize.width : scroll.bounds.width
        let cardW = max(300, canvasWidth - 48)
        var currentY: CGFloat = 16

        for item in items {
            let card = createPromptCard(example: item, width: cardW, startY: currentY)
            canvas.addSubview(card)
            currentY += card.bounds.height + 14
        }

        let totalHeight = max(currentY + 20, scroll.bounds.height)
        canvas.frame = NSRect(x: 0, y: 0, width: canvasWidth, height: totalHeight)
    }

    private func createPromptCard(example: AIPromptExample, width: CGFloat, startY: CGFloat) -> NSView {
        let card = FlippedCanvasView(frame: NSRect(x: 24, y: startY, width: width, height: 162))
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(red: 0.12, green: 0.125, blue: 0.145, alpha: 1.0).cgColor
        card.layer?.cornerRadius = 13
        card.layer?.borderWidth = 1.0
        card.layer?.borderColor = NSColor(red: 0.22, green: 0.24, blue: 0.28, alpha: 1.0).cgColor

        // 1. Top Bar: Category Pill + Title + Action Buttons
        let catBadge = NSTextField(labelWithString: " \(example.category.icon) \(example.category.rawValue) ")
        catBadge.font = NSFont.boldSystemFont(ofSize: 10.5)
        catBadge.textColor = NSColor(red: 0.60, green: 0.82, blue: 1.0, alpha: 1.0)
        catBadge.wantsLayer = true
        catBadge.layer?.backgroundColor = NSColor(red: 0.15, green: 0.22, blue: 0.35, alpha: 0.7).cgColor
        catBadge.layer?.cornerRadius = 8
        catBadge.layer?.borderWidth = 0.8
        catBadge.layer?.borderColor = NSColor(red: 0.25, green: 0.45, blue: 0.80, alpha: 0.6).cgColor
        let catTextW = (catBadge.stringValue as NSString).size(withAttributes: [.font: catBadge.font ?? NSFont.systemFont(ofSize: 10.5)]).width
        catBadge.frame = NSRect(x: 16, y: 12, width: ceil(catTextW) + 14, height: 20)
        card.addSubview(catBadge)

        let titleLabel = NSTextField(labelWithString: example.title)
        titleLabel.font = NSFont.boldSystemFont(ofSize: 14)
        titleLabel.textColor = NSColor.white
        let titleX = catBadge.frame.maxX + 10
        titleLabel.frame = NSRect(x: titleX, y: 12, width: max(80, width - titleX - 180), height: 20)
        card.addSubview(titleLabel)

        // [▶ Run Now] Button
        let runBtn = NSButton(title: "▶ Run Now", target: self, action: #selector(handleRunPromptClicked(_:)))
        runBtn.bezelStyle = .roundRect
        runBtn.font = NSFont.boldSystemFont(ofSize: 11)
        runBtn.contentTintColor = NSColor(red: 0.45, green: 0.75, blue: 1.0, alpha: 1.0)
        runBtn.frame = NSRect(x: width - 180, y: 10, width: 88, height: 24)
        runBtn.identifier = NSUserInterfaceItemIdentifier(rawValue: example.prompt)
        card.addSubview(runBtn)

        // [❐ Copy] Button
        let copyBtn = NSButton(title: "❐ Copy", target: self, action: #selector(handleCopyPromptClicked(_:)))
        copyBtn.bezelStyle = .roundRect
        copyBtn.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        copyBtn.frame = NSRect(x: width - 86, y: 10, width: 70, height: 24)
        copyBtn.identifier = NSUserInterfaceItemIdentifier(rawValue: example.prompt)
        card.addSubview(copyBtn)

        // 2. Prompt Pill Capsule (Monospace)
        let promptContainer = FlippedCanvasView(frame: NSRect(x: 16, y: 38, width: width - 32, height: 26))
        promptContainer.wantsLayer = true
        promptContainer.layer?.backgroundColor = NSColor(red: 0.08, green: 0.085, blue: 0.10, alpha: 1.0).cgColor
        promptContainer.layer?.cornerRadius = 6
        promptContainer.layer?.borderWidth = 0.8
        promptContainer.layer?.borderColor = NSColor(red: 0.20, green: 0.22, blue: 0.27, alpha: 1.0).cgColor

        let promptPrompt = NSTextField(labelWithString: "> \(example.prompt)")
        promptPrompt.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        promptPrompt.textColor = NSColor(red: 0.55, green: 0.85, blue: 0.55, alpha: 1.0)
        promptPrompt.frame = NSRect(x: 8, y: 4, width: width - 48, height: 18)
        promptContainer.addSubview(promptPrompt)
        card.addSubview(promptContainer)

        // 3. Description Label
        let descLabel = NSTextField(labelWithString: example.description)
        descLabel.font = NSFont.systemFont(ofSize: 12)
        descLabel.textColor = NSColor(white: 0.75, alpha: 1.0)
        descLabel.frame = NSRect(x: 16, y: 68, width: width - 32, height: 38)
        descLabel.maximumNumberOfLines = 2
        descLabel.cell?.wraps = true
        card.addSubview(descLabel)

        // 4. Hardware Response Callout Box
        let hwContainer = FlippedCanvasView(frame: NSRect(x: 16, y: 110, width: width - 32, height: 38))
        hwContainer.wantsLayer = true
        hwContainer.layer?.backgroundColor = NSColor(red: 0.09, green: 0.12, blue: 0.16, alpha: 0.95).cgColor
        hwContainer.layer?.cornerRadius = 6
        hwContainer.layer?.borderWidth = 0.8
        hwContainer.layer?.borderColor = NSColor(red: 0.18, green: 0.28, blue: 0.42, alpha: 0.7).cgColor

        let hwLabel = NSTextField(labelWithString: "⚡ Hardware Effect: \(example.hardwareEffect)")
        hwLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        hwLabel.textColor = NSColor(red: 0.65, green: 0.82, blue: 1.0, alpha: 1.0)
        hwLabel.frame = NSRect(x: 8, y: 5, width: width - 48, height: 28)
        hwLabel.maximumNumberOfLines = 2
        hwLabel.cell?.wraps = true
        hwContainer.addSubview(hwLabel)
        card.addSubview(hwContainer)

        return card
    }

    @objc private func handleRunPromptClicked(_ sender: NSButton) {
        guard let prompt = sender.identifier?.rawValue else { return }
        self.window?.close()
        if let onSelect = onSelectPrompt {
            onSelect(prompt)
        } else if let chatController = AIChatWindowController.current {
            chatController.window?.makeKeyAndOrderFront(nil)
            chatController.executePrompt(prompt)
        }
    }

    @objc private func handleCopyPromptClicked(_ sender: NSButton) {
        guard let prompt = sender.identifier?.rawValue else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        sender.title = "✓ Copied!"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            sender.title = "❐ Copy"
        }
    }
}

public final class ApiKeyDialogHelper {
    public static func present(title: String, currentKey: String, window: NSWindow?, onSave: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Enter or paste your Google Gemini API key to enable acoustic reasoning.\nSupports Google AI Studio (AIzaSy...), Vertex / GCP tokens (AQ...), and all valid key formats without length or prefix restrictions."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let accessory = ApiKeyDialogAccessoryView(currentKey: currentKey)
        alert.accessoryView = accessory

        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = accessory.inputField

        let res = alert.runModal()
        if res == .alertFirstButtonReturn {
            let key = accessory.inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            onSave(key)
        }
    }
}

public final class OllamaConfigDialogHelper {
    public static func present(
        title: String = "Configure Local LLM (Ollama)",
        currentEndpoint: String,
        currentModel: String,
        window: NSWindow?,
        onSave: @escaping (_ endpoint: String, _ model: String) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Configure Local LLM via Ollama server.\nDefault endpoint: http://127.0.0.1:11434, Recommended model: llama3.2."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let accessory = OllamaConfigDialogAccessoryView(endpoint: currentEndpoint, model: currentModel)
        alert.accessoryView = accessory

        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = accessory.endpointField

        let res = alert.runModal()
        if res == .alertFirstButtonReturn {
            let ep = accessory.endpointField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let mod = accessory.modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            onSave(ep.isEmpty ? "http://127.0.0.1:11434" : ep, mod.isEmpty ? "llama3.2" : mod)
        }
    }
}

// MARK: - Native AppKit Gemini-Style Web UI Implementation

public final class FlippedCanvasView: NSView {
    public override var isFlipped: Bool { return true }
}

public final class HeroCardButton: NSButton {
    public override var isFlipped: Bool { return true }
    public let iconLabel: NSTextField
    public let titleLabel: NSTextField
    public let subtitleLabel: NSTextField

    public init(frame: NSRect, icon: String, title: String, subtitle: String) {
        iconLabel = NSTextField(labelWithString: icon)
        titleLabel = NSTextField(labelWithString: title)
        subtitleLabel = NSTextField(labelWithString: subtitle)
        super.init(frame: frame)

        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor(red: 0.12, green: 0.125, blue: 0.14, alpha: 1.0).cgColor
        self.layer?.cornerRadius = 14
        self.layer?.borderWidth = 1.0
        self.layer?.borderColor = NSColor(red: 0.22, green: 0.23, blue: 0.26, alpha: 1.0).cgColor
        self.title = ""
        self.isBordered = false

        iconLabel.font = NSFont.systemFont(ofSize: 18)
        iconLabel.frame = NSRect(x: 14, y: 12, width: 26, height: 22)
        addSubview(iconLabel)

        titleLabel.font = NSFont.boldSystemFont(ofSize: 13)
        titleLabel.textColor = NSColor(white: 0.95, alpha: 1.0)
        titleLabel.frame = NSRect(x: 44, y: 13, width: frame.width - 56, height: 20)
        addSubview(titleLabel)

        subtitleLabel.font = NSFont.systemFont(ofSize: 11)
        subtitleLabel.textColor = NSColor(white: 0.60, alpha: 1.0)
        subtitleLabel.frame = NSRect(x: 14, y: 36, width: frame.width - 28, height: 32)
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.cell?.wraps = true
        addSubview(subtitleLabel)
    }

    public required init?(coder: NSCoder) { fatalError() }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil))
    }

    public override func mouseEntered(with event: NSEvent) {
        self.layer?.backgroundColor = NSColor(red: 0.16, green: 0.17, blue: 0.20, alpha: 1.0).cgColor
        self.layer?.borderColor = NSColor(red: 0.35, green: 0.55, blue: 0.95, alpha: 0.8).cgColor
    }

    public override func mouseExited(with event: NSEvent) {
        self.layer?.backgroundColor = NSColor(red: 0.12, green: 0.125, blue: 0.14, alpha: 1.0).cgColor
        self.layer?.borderColor = NSColor(red: 0.22, green: 0.23, blue: 0.26, alpha: 1.0).cgColor
    }
}

final class PromptChipButton: NSButton {
    override var isFlipped: Bool { return true }
    let promptValue: String

    init(title: String, prompt: String) {
        self.promptValue = prompt
        super.init(frame: .zero)
        self.title = title
        self.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        self.bezelStyle = .inline
        self.isBordered = false
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor(red: 0.16, green: 0.17, blue: 0.21, alpha: 1.0).cgColor
        self.layer?.cornerRadius = 13
        self.layer?.borderWidth = 1.0
        self.layer?.borderColor = NSColor(red: 0.26, green: 0.28, blue: 0.33, alpha: 1.0).cgColor
        self.contentTintColor = NSColor(white: 0.92, alpha: 1.0)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        self.layer?.backgroundColor = NSColor(red: 0.20, green: 0.25, blue: 0.35, alpha: 1.0).cgColor
        self.layer?.borderColor = NSColor(red: 0.40, green: 0.65, blue: 1.0, alpha: 0.9).cgColor
        self.contentTintColor = NSColor.white
    }

    override func mouseExited(with event: NSEvent) {
        self.layer?.backgroundColor = NSColor(red: 0.16, green: 0.17, blue: 0.21, alpha: 1.0).cgColor
        self.layer?.borderColor = NSColor(red: 0.26, green: 0.28, blue: 0.33, alpha: 1.0).cgColor
        self.contentTintColor = NSColor(white: 0.92, alpha: 1.0)
    }
}

public final class AIChatWindowController: NSWindowController, NSTextFieldDelegate, NSWindowDelegate {
    public static var current: AIChatWindowController?

    private var uad: UADClient!
    private var auditor: AIAudioAuditor!

    public struct ChatMessage {
        public enum Sender {
            case user
            case gemini
            case system
        }
        public let id = UUID()
        public let sender: Sender
        public let text: String
        public let timestamp: Date

        public init(sender: Sender, text: String, timestamp: Date = Date()) {
            self.sender = sender
            self.text = text
            self.timestamp = timestamp
        }
    }

    public var messages: [ChatMessage] = []
    public private(set) var isExecuting: Bool = false

    private var rootContainer: NSView!
    private var headerBar: NSView!
    private var scrollView: NSScrollView!
    public private(set) var canvasView: FlippedCanvasView!
    private var heroView: NSView?
    private var promptCapsule: NSView!
    public private(set) var inputField: PasteableTextField!
    private var sendButton: NSButton!
    private var spinner: NSProgressIndicator!
    private var disclaimerLabel: NSTextField!
    private weak var thinkingStatusLabel: NSTextField?
    private var currentThinkingText: String = "✦ S&D Co-Producer is thinking..."
    private var customFieldEditor: CustomFieldEditorTextView?
    private var modelBadge: NSTextField!

    /// Closure provider to obtain the screen frame of the app's Mac status bar item
    public static var statusItemFrameProvider: (() -> NSRect?)?

    /// Positions the chat window directly beneath the Mac status bar item icon
    public func positionNearStatusBar() {
        guard let win = self.window else { return }
        let winSize = win.frame.size
        let screen = win.screen ?? NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var originX: CGFloat = visibleFrame.maxX - winSize.width - 20
        var originY: CGFloat = visibleFrame.maxY - winSize.height - 6

        if let provider = AIChatWindowController.statusItemFrameProvider,
           let buttonRect = provider() {
            // Anchor directly below status bar item button, centered horizontally on button
            let targetX = buttonRect.midX - (winSize.width / 2.0)
            originX = min(max(visibleFrame.minX + 16, targetX), visibleFrame.maxX - winSize.width - 16)
            originY = buttonRect.minY - winSize.height - 6
        }

        win.setFrameOrigin(NSPoint(x: originX, y: max(visibleFrame.minY + 16, originY)))
    }

    public static func show(uad: UADClient, auditor: AIAudioAuditor) {
        let present = {
            let controller: AIChatWindowController
            var isNewlyCreated = false
            if let existing = current, let win = existing.window, win.isVisible {
                controller = existing
            } else if let existing = current {
                controller = existing
            } else {
                controller = AIChatWindowController(uad: uad, auditor: auditor)
                current = controller
                isNewlyCreated = true
            }
            controller.window?.level = .floating
            if isNewlyCreated || !(controller.window?.isVisible ?? false) {
                controller.positionNearStatusBar()
            }
            controller.window?.orderFrontRegardless()
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            controller.updateModelBadge()
            if let field = controller.inputField {
                controller.window?.makeFirstResponder(field)
                field.selectText(nil)
            }
        }

        if Thread.isMainThread {
            present()
        } else {
            DispatchQueue.main.async {
                present()
            }
        }
    }

    public convenience init(uad: UADClient, auditor: AIAudioAuditor) {
        let window = AIChatWindow(
            contentRect: NSRect(x: 100, y: 100, width: 680, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "S&D Co-Producer"
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.095, alpha: 1.0)
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 520, height: 560)
        window.level = .floating

        self.init(window: window)
        self.uad = uad
        self.auditor = auditor
        window.delegate = self
        positionNearStatusBar()
        setupUI()
    }

    public func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        if customFieldEditor == nil {
            let editor = CustomFieldEditorTextView()
            editor.isFieldEditor = true
            customFieldEditor = editor
        }
        return customFieldEditor
    }

    private func setupUI() {
        guard let window = self.window, let contentView = window.contentView else { return }

        rootContainer = NSView(frame: contentView.bounds)
        rootContainer.autoresizingMask = [.width, .height]
        contentView.addSubview(rootContainer)

        // 1. Top Header Bar (S&D Co-Producer Brand + Model Badge + Actions)
        headerBar = NSView(frame: NSRect(x: 0, y: rootContainer.bounds.height - 54, width: rootContainer.bounds.width, height: 54))
        headerBar.autoresizingMask = [.width, .minYMargin]
        headerBar.wantsLayer = true
        headerBar.layer?.backgroundColor = NSColor(red: 0.09, green: 0.095, blue: 0.11, alpha: 0.95).cgColor
        rootContainer.addSubview(headerBar)

        let sparkleIcon = NSTextField(labelWithString: "✦")
        sparkleIcon.font = NSFont.systemFont(ofSize: 20, weight: .bold)
        sparkleIcon.textColor = NSColor(red: 0.45, green: 0.65, blue: 1.0, alpha: 1.0)
        sparkleIcon.frame = NSRect(x: 20, y: 14, width: 24, height: 26)
        headerBar.addSubview(sparkleIcon)

        let brandTitle = NSTextField(labelWithString: "S&D Co-Producer")
        brandTitle.font = NSFont.systemFont(ofSize: 16, weight: .bold)
        brandTitle.textColor = NSColor.white
        brandTitle.frame = NSRect(x: 48, y: 16, width: 145, height: 22)
        headerBar.addSubview(brandTitle)

        // Model Badge Pill
        modelBadge = NSTextField(labelWithString: "Auto • Live")
        modelBadge.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        modelBadge.textColor = NSColor(red: 0.55, green: 0.82, blue: 1.0, alpha: 1.0)
        modelBadge.wantsLayer = true
        modelBadge.layer?.backgroundColor = NSColor(red: 0.15, green: 0.22, blue: 0.35, alpha: 0.7).cgColor
        modelBadge.layer?.cornerRadius = 10
        modelBadge.layer?.borderWidth = 0.8
        modelBadge.layer?.borderColor = NSColor(red: 0.25, green: 0.45, blue: 0.80, alpha: 0.6).cgColor
        modelBadge.alignment = .center
        modelBadge.frame = NSRect(x: 200, y: 16, width: 155, height: 20)
        headerBar.addSubview(modelBadge)
        updateModelBadge()

        // Prompt Guide Button
        let promptGuideBtn = NSButton(title: "📖 Prompt Guide", target: self, action: #selector(handleShowPromptHelp))
        promptGuideBtn.bezelStyle = .roundRect
        promptGuideBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        promptGuideBtn.frame = NSRect(x: headerBar.bounds.width - 346, y: 14, width: 120, height: 26)
        promptGuideBtn.autoresizingMask = [.minXMargin]
        headerBar.addSubview(promptGuideBtn)

        // New Chat Button
        let newChatBtn = NSButton(title: "+ New Chat", target: self, action: #selector(handleNewChat))
        newChatBtn.bezelStyle = .roundRect
        newChatBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        newChatBtn.frame = NSRect(x: headerBar.bounds.width - 220, y: 14, width: 98, height: 26)
        newChatBtn.autoresizingMask = [.minXMargin]
        headerBar.addSubview(newChatBtn)

        // Provider & Settings Button
        let providerBtn = NSButton(title: "⚙️ Provider", target: self, action: #selector(handleOpenProviderMenu(_:)))
        providerBtn.bezelStyle = .roundRect
        providerBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        providerBtn.frame = NSRect(x: headerBar.bounds.width - 116, y: 14, width: 96, height: 26)
        providerBtn.autoresizingMask = [.minXMargin]
        headerBar.addSubview(providerBtn)

        let divider = NSBox(frame: NSRect(x: 0, y: 0, width: headerBar.bounds.width, height: 1))
        divider.boxType = .separator
        divider.autoresizingMask = [.width]
        headerBar.addSubview(divider)

        // 2. Chat Transcript Scroll View
        scrollView = NSScrollView(frame: NSRect(x: 0, y: 92, width: rootContainer.bounds.width, height: rootContainer.bounds.height - 146))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        canvasView = FlippedCanvasView(frame: NSRect(x: 0, y: 0, width: scrollView.bounds.width, height: scrollView.bounds.height))
        canvasView.wantsLayer = true
        canvasView.layer?.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.095, alpha: 1.0).cgColor
        scrollView.documentView = canvasView
        rootContainer.addSubview(scrollView)

        // 3. Floating Gemini Prompt Capsule
        setupPromptCapsule()

        // 4. Notification Observer for Prompt Help
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowPromptHelp),
            name: NSNotification.Name("ShowAIPromptHelpNotification"),
            object: nil
        )

        // 5. Initial Canvas Render
        renderCanvas()
    }

    private func setupPromptCapsule() {
        let capsuleHeight: CGFloat = 52
        promptCapsule = NSView(frame: NSRect(x: 24, y: 30, width: rootContainer.bounds.width - 48, height: capsuleHeight))
        promptCapsule.autoresizingMask = [.width, .maxYMargin]
        promptCapsule.wantsLayer = true
        promptCapsule.layer?.backgroundColor = NSColor(red: 0.12, green: 0.125, blue: 0.145, alpha: 1.0).cgColor
        promptCapsule.layer?.cornerRadius = capsuleHeight / 2.0
        promptCapsule.layer?.borderWidth = 1.0
        promptCapsule.layer?.borderColor = NSColor(red: 0.24, green: 0.25, blue: 0.28, alpha: 1.0).cgColor
        promptCapsule.layer?.shadowColor = NSColor.black.cgColor
        promptCapsule.layer?.shadowOpacity = 0.35
        promptCapsule.layer?.shadowOffset = CGSize(width: 0, height: -2)
        promptCapsule.layer?.shadowRadius = 8
        rootContainer.addSubview(promptCapsule)

        // Mixer Icon / Tool Indicator
        let toolIcon = NSTextField(labelWithString: "🎛️")
        toolIcon.font = NSFont.systemFont(ofSize: 18)
        toolIcon.frame = NSRect(x: 16, y: 14, width: 26, height: 24)
        promptCapsule.addSubview(toolIcon)

        // Input Text Field
        inputField = PasteableTextField(frame: NSRect(x: 48, y: 13, width: promptCapsule.bounds.width - 106, height: 26))
        inputField.autoresizingMask = [.width]
        inputField.placeholderString = "Ask S&D Co-Producer or enter mixer command (e.g. mute C2 for System out)..."
        inputField.font = NSFont.systemFont(ofSize: 13.5)
        inputField.textColor = NSColor(white: 0.95, alpha: 1.0)
        inputField.isBordered = false
        inputField.drawsBackground = false
        inputField.focusRingType = .none
        inputField.delegate = self
        inputField.target = self
        inputField.action = #selector(handleSend)
        promptCapsule.addSubview(inputField)

        // Circular Blue Send Button (Gemini Style)
        let sendBtnSize: CGFloat = 34
        sendButton = NSButton(frame: NSRect(x: promptCapsule.bounds.width - 42, y: 9, width: sendBtnSize, height: sendBtnSize))
        sendButton.autoresizingMask = [.minXMargin]
        sendButton.wantsLayer = true
        sendButton.layer?.backgroundColor = NSColor(red: 0.10, green: 0.45, blue: 0.91, alpha: 1.0).cgColor
        sendButton.layer?.cornerRadius = sendBtnSize / 2.0
        sendButton.title = "↑"
        sendButton.font = NSFont.systemFont(ofSize: 18, weight: .bold)
        sendButton.contentTintColor = NSColor.white
        sendButton.isBordered = false
        sendButton.target = self
        sendButton.action = #selector(handleSend)
        sendButton.toolTip = "Send prompt (Return)"
        promptCapsule.addSubview(sendButton)

        // Activity Spinner
        spinner = NSProgressIndicator(frame: NSRect(x: promptCapsule.bounds.width - 76, y: 16, width: 20, height: 20))
        spinner.style = .spinning
        spinner.isDisplayedWhenStopped = false
        spinner.autoresizingMask = [.minXMargin]
        promptCapsule.addSubview(spinner)

        // Signature Disclaimer
        disclaimerLabel = NSTextField(labelWithString: "S&D Co-Producer • Powered by Gemini 3.8 Flash • Verify Apollo console telemetry")
        disclaimerLabel.font = NSFont.systemFont(ofSize: 10.5)
        disclaimerLabel.textColor = NSColor(white: 0.50, alpha: 1.0)
        disclaimerLabel.alignment = .center
        disclaimerLabel.frame = NSRect(x: 24, y: 8, width: rootContainer.bounds.width - 48, height: 16)
        disclaimerLabel.autoresizingMask = [.width, .maxYMargin]
        rootContainer.addSubview(disclaimerLabel)
    }

    public func windowDidResize(_ notification: Notification) {
        rootContainer?.layoutSubtreeIfNeeded()
        scrollView?.layoutSubtreeIfNeeded()
        renderCanvas()
    }

    // MARK: - Gemini Canvas & Message Rendering

    public func renderCanvas() {
        guard let canvas = canvasView, let scroll = scrollView else { return }
        rootContainer?.layoutSubtreeIfNeeded()
        scroll.layoutSubtreeIfNeeded()
        canvas.subviews.forEach { $0.removeFromSuperview() }

        let canvasWidth = scroll.contentSize.width > 0 ? scroll.contentSize.width : scroll.bounds.width

        if messages.isEmpty {
            // Render Gemini Hero Greeting & Suggestion Cards
            let hero = createHeroView(width: canvasWidth)
            canvas.addSubview(hero)
            let totalHeight = max(hero.bounds.height + 40, scroll.bounds.height)
            canvas.frame = NSRect(x: 0, y: 0, width: canvasWidth, height: totalHeight)
            return
        }

        var currentY: CGFloat = 16
        for msg in messages {
            if msg.sender == .user {
                // User Bubble (Right-aligned dark cobalt capsule with timestamp)
                let bubble = createUserBubble(msg: msg, canvasWidth: canvasWidth, startY: currentY)
                canvas.addSubview(bubble)
                currentY += bubble.bounds.height + 12
            } else {
                // Gemini Response (Left-aligned, full width with Sparkle logo)
                let card = createGeminiCard(msg: msg, canvasWidth: canvasWidth, startY: currentY)
                canvas.addSubview(card)
                currentY += card.bounds.height + 8
            }
        }

        if isExecuting {
            let thinkingCard = createThinkingCard(canvasWidth: canvasWidth, startY: currentY)
            canvas.addSubview(thinkingCard)
            currentY += thinkingCard.bounds.height + 12
        } else {
            let lastUserMsg = messages.last(where: { $0.sender == .user })?.text ?? ""
            let lastAiMsg = messages.last(where: { $0.sender != .user })?.text ?? ""
            let suggestionsCard = createPromptSuggestionsCard(
                canvasWidth: canvasWidth,
                startY: currentY,
                lastQuery: lastUserMsg,
                lastReply: lastAiMsg
            )
            canvas.addSubview(suggestionsCard)
            currentY += suggestionsCard.bounds.height + 14
        }

        let totalHeight = max(currentY + 20, scroll.bounds.height)
        canvas.frame = NSRect(x: 0, y: 0, width: canvasWidth, height: totalHeight)
        scroll.documentView?.scroll(NSPoint(x: 0, y: totalHeight))
    }

    private func createHeroView(width: CGFloat) -> NSView {
        let cardGridWidth = min(width - 48, 620)
        let cardStartX = (width - cardGridWidth) / 2.0
        let cardW = (cardGridWidth - 14) / 2.0
        let cardH: CGFloat = 82

        let highlightedItems = AIPromptCatalog.highlighted
        let numRows = (highlightedItems.count + 1) / 2
        let bannerH: CGFloat = 40
        let totalHeroH: CGFloat = 175 + bannerH + CGFloat(numRows) * (cardH + 12) + 40
        let hero = FlippedCanvasView(frame: NSRect(x: 0, y: 10, width: width, height: totalHeroH))
        hero.autoresizingMask = [.width]

        // Sparkle Gradient Logo
        let sparkle = NSTextField(labelWithString: "✦")
        sparkle.font = NSFont.systemFont(ofSize: 34, weight: .bold)
        sparkle.textColor = NSColor(red: 0.45, green: 0.65, blue: 1.0, alpha: 1.0)
        sparkle.alignment = .center
        sparkle.frame = NSRect(x: (width - 60) / 2.0, y: 10, width: 60, height: 40)
        sparkle.autoresizingMask = [.minXMargin, .maxXMargin]
        hero.addSubview(sparkle)

        // Large Greeting
        let titleLabel = NSTextField(labelWithString: "S&D Co-Producer")
        titleLabel.font = NSFont.systemFont(ofSize: 26, weight: .bold)
        titleLabel.textColor = NSColor(white: 0.95, alpha: 1.0)
        titleLabel.alignment = .center
        titleLabel.frame = NSRect(x: 20, y: 52, width: width - 40, height: 32)
        titleLabel.autoresizingMask = [.width]
        hero.addSubview(titleLabel)

        let subtitleLabel = NSTextField(labelWithString: "How can I assist your Universal Audio Apollo mix today?")
        subtitleLabel.font = NSFont.systemFont(ofSize: 13.5)
        subtitleLabel.textColor = NSColor(white: 0.60, alpha: 1.0)
        subtitleLabel.alignment = .center
        subtitleLabel.frame = NSRect(x: 20, y: 84, width: width - 40, height: 22)
        subtitleLabel.autoresizingMask = [.width]
        hero.addSubview(subtitleLabel)

        // Banner: Full Prompt Examples Help Page
        let banner = NSButton(frame: NSRect(x: cardStartX, y: 114, width: cardGridWidth, height: bannerH))
        banner.bezelStyle = .regularSquare
        banner.isBordered = false
        banner.wantsLayer = true
        banner.layer?.backgroundColor = NSColor(red: 0.12, green: 0.16, blue: 0.25, alpha: 1.0).cgColor
        banner.layer?.cornerRadius = 12
        banner.layer?.borderWidth = 1.0
        banner.layer?.borderColor = NSColor(red: 0.28, green: 0.45, blue: 0.82, alpha: 0.8).cgColor
        banner.title = "📖  Browse Full Help Page of Prompt Examples (38+ Commands Across 8 Categories)  ➔"
        banner.font = NSFont.boldSystemFont(ofSize: 12)
        banner.contentTintColor = NSColor(red: 0.70, green: 0.85, blue: 1.0, alpha: 1.0)
        banner.target = self
        banner.action = #selector(handleShowPromptHelp)
        hero.addSubview(banner)

        // Section: Highlighted Prompt Examples by Category
        let sectionHeaderY: CGFloat = 164
        let sectionHeader = NSTextField(labelWithString: "💡 Highlighted Prompt Examples by Category")
        sectionHeader.font = NSFont.boldSystemFont(ofSize: 13)
        sectionHeader.textColor = NSColor(red: 0.55, green: 0.78, blue: 1.0, alpha: 1.0)
        sectionHeader.frame = NSRect(x: cardStartX, y: sectionHeaderY, width: cardGridWidth, height: 20)
        hero.addSubview(sectionHeader)

        let sectionSub = NSTextField(labelWithString: "Tap any highlighted card below to execute immediately across Apollo telemetry and UF8 controls:")
        sectionSub.font = NSFont.systemFont(ofSize: 11)
        sectionSub.textColor = NSColor(white: 0.50, alpha: 1.0)
        sectionSub.frame = NSRect(x: cardStartX, y: sectionHeaderY + 20, width: cardGridWidth, height: 18)
        hero.addSubview(sectionSub)

        let startGridY: CGFloat = sectionHeaderY + 44
        for (idx, item) in highlightedItems.enumerated() {
            let col = idx % 2
            let row = idx / 2
            let x = cardStartX + CGFloat(col) * (cardW + 14)
            let y = startGridY + CGFloat(row) * (cardH + 12)

            let btn = HeroCardButton(
                frame: NSRect(x: x, y: y, width: cardW, height: cardH),
                icon: item.category.icon,
                title: item.title,
                subtitle: "\(item.category.rawValue) • \(item.description)"
            )
            btn.target = self
            btn.action = #selector(handleCardPrompt(_:))
            btn.identifier = NSUserInterfaceItemIdentifier(rawValue: item.prompt)
            hero.addSubview(btn)
        }

        let footerY = startGridY + CGFloat(numRows) * (cardH + 12) + 6
        let footerLink = NSButton(title: "Looking for more commands? Open Full Help Page of Prompt Examples ↗", target: self, action: #selector(handleShowPromptHelp))
        footerLink.bezelStyle = .inline
        footerLink.isBordered = false
        footerLink.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        footerLink.contentTintColor = NSColor(red: 0.55, green: 0.75, blue: 1.0, alpha: 1.0)
        footerLink.frame = NSRect(x: cardStartX, y: footerY, width: cardGridWidth, height: 22)
        hero.addSubview(footerLink)

        return hero
    }

    private func createThinkingCard(canvasWidth: CGFloat, startY: CGFloat) -> NSView {
        let cardW = canvasWidth - 48
        let card = FlippedCanvasView(frame: NSRect(x: 24, y: startY, width: cardW, height: 46))
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(red: 0.11, green: 0.13, blue: 0.17, alpha: 0.95).cgColor
        card.layer?.cornerRadius = 12
        card.layer?.borderWidth = 1.0
        card.layer?.borderColor = NSColor(red: 0.25, green: 0.40, blue: 0.70, alpha: 0.7).cgColor

        let spin = NSProgressIndicator(frame: NSRect(x: 16, y: 13, width: 20, height: 20))
        spin.style = .spinning
        spin.startAnimation(nil)
        card.addSubview(spin)

        let label = NSTextField(labelWithString: currentThinkingText)
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = NSColor(red: 0.65, green: 0.82, blue: 1.0, alpha: 1.0)
        label.frame = NSRect(x: 44, y: 13, width: max(100, cardW - 160), height: 20)
        card.addSubview(label)
        self.thinkingStatusLabel = label

        let cancelBtn = NSButton(title: "Cancel (Esc)", target: self, action: #selector(cancelExecution))
        cancelBtn.bezelStyle = .roundRect
        cancelBtn.font = NSFont.boldSystemFont(ofSize: 11)
        cancelBtn.contentTintColor = NSColor(red: 1.0, green: 0.45, blue: 0.45, alpha: 1.0)
        cancelBtn.frame = NSRect(x: cardW - 110, y: 10, width: 96, height: 26)
        card.addSubview(cancelBtn)

        return card
    }

    private func createPromptSuggestionsCard(canvasWidth: CGFloat, startY: CGFloat, lastQuery: String = "", lastReply: String = "") -> NSView {
        let cardW = canvasWidth - 48
        let card = FlippedCanvasView(frame: NSRect(x: 24, y: startY, width: cardW, height: 110))
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(red: 0.11, green: 0.115, blue: 0.135, alpha: 0.95).cgColor
        card.layer?.cornerRadius = 14
        card.layer?.borderWidth = 1.0
        card.layer?.borderColor = NSColor(red: 0.22, green: 0.24, blue: 0.28, alpha: 1.0).cgColor

        // Header
        let iconLabel = NSTextField(labelWithString: "💡")
        iconLabel.font = NSFont.systemFont(ofSize: 14)
        iconLabel.frame = NSRect(x: 16, y: 10, width: 20, height: 18)
        card.addSubview(iconLabel)

        let isContextual = !lastQuery.isEmpty
        let titleLabel = NSTextField(labelWithString: isContextual ? "Related Prompt Suggestions" : "Prompt Suggestions")
        titleLabel.font = NSFont.boldSystemFont(ofSize: 12.5)
        titleLabel.textColor = NSColor(red: 0.65, green: 0.82, blue: 1.0, alpha: 1.0)
        let titleW: CGFloat = isContextual ? 190 : 160
        titleLabel.frame = NSRect(x: 38, y: 10, width: titleW, height: 18)
        card.addSubview(titleLabel)

        let hintText = isContextual
            ? "Tailored next actions for '\(lastQuery.prefix(25))':"
            : "Click to query Apollo telemetry or hardware guides:"
        let hintLabel = NSTextField(labelWithString: hintText)
        hintLabel.font = NSFont.systemFont(ofSize: 11)
        hintLabel.textColor = NSColor(white: 0.55, alpha: 1.0)
        let hintX = 38 + titleW + 8
        hintLabel.frame = NSRect(x: hintX, y: 11, width: max(80, cardW - hintX - 130), height: 16)
        card.addSubview(hintLabel)

        // Link to full Help page
        let helpLinkBtn = NSButton(title: "📖 All Examples ↗", target: self, action: #selector(handleShowPromptHelp))
        helpLinkBtn.bezelStyle = .inline
        helpLinkBtn.font = NSFont.boldSystemFont(ofSize: 11)
        helpLinkBtn.contentTintColor = NSColor(red: 0.55, green: 0.78, blue: 1.0, alpha: 1.0)
        helpLinkBtn.isBordered = false
        helpLinkBtn.frame = NSRect(x: cardW - 130, y: 8, width: 116, height: 22)
        card.addSubview(helpLinkBtn)

        // Dynamically compute suggestions based on last executed query and response
        let suggestions = AIPromptCatalog.computeContextualSuggestions(query: lastQuery, reply: lastReply)

        var currentX: CGFloat = 16
        var currentChipY: CGFloat = 34
        let chipHeight: CGFloat = 28
        let chipSpacing: CGFloat = 8
        let rowSpacing: CGFloat = 8

        for item in suggestions {
            let chip = PromptChipButton(title: item.label, prompt: item.prompt)
            chip.target = self
            chip.action = #selector(handleChipClicked(_:))
            let textWidth = (item.label as NSString).size(withAttributes: [.font: chip.font ?? NSFont.systemFont(ofSize: 11.5)]).width
            let chipWidth = ceil(textWidth) + 26

            if currentX + chipWidth > cardW - 16 && currentX > 16 {
                currentX = 16
                currentChipY += (chipHeight + rowSpacing)
            }

            chip.frame = NSRect(x: currentX, y: currentChipY, width: chipWidth, height: chipHeight)
            card.addSubview(chip)
            currentX += chipWidth + chipSpacing
        }

        let totalH = currentChipY + chipHeight + 11
        card.frame = NSRect(x: 24, y: startY, width: cardW, height: totalH)
        return card
    }

    @objc private func handleChipClicked(_ sender: PromptChipButton) {
        executePrompt(sender.promptValue)
    }

    @objc private func handleCardPrompt(_ sender: NSButton) {
        guard let prompt = sender.identifier?.rawValue else { return }
        executePrompt(prompt)
    }

    public static func formatRelativeTime(from date: Date, relativeTo now: Date = Date()) -> String {
        let interval = max(0, now.timeIntervalSince(date))
        if interval < 60 {
            return "Just now"
        } else if interval < 3600 {
            let mins = max(1, Int(interval / 60))
            return "\(mins)m ago"
        } else if interval < 86400 {
            let hours = max(1, Int(interval / 3600))
            return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
        } else if interval < 604800 {
            let days = max(1, Int(interval / 86400))
            return days == 1 ? "1 day ago" : "\(days) days ago"
        } else {
            return DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .none)
        }
    }

    private func createPromptActionButton(
        symbolName: String,
        fallbackText: String,
        toolTip: String,
        action: Selector,
        textPayload: String
    ) -> NSButton {
        let btn = NSButton()
        btn.isBordered = false
        btn.bezelStyle = .regularSquare
        btn.wantsLayer = true
        btn.layer?.backgroundColor = NSColor.clear.cgColor
        btn.toolTip = toolTip
        btn.target = self
        btn.action = action
        btn.identifier = NSUserInterfaceItemIdentifier(rawValue: textPayload)

        if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: toolTip) {
            let config = NSImage.SymbolConfiguration(pointSize: 11.5, weight: .regular)
            btn.image = symbol.withSymbolConfiguration(config)
            btn.imagePosition = .imageOnly
            btn.title = ""
        } else {
            btn.title = fallbackText
            btn.font = NSFont.systemFont(ofSize: 11.5)
        }
        btn.contentTintColor = NSColor(white: 0.65, alpha: 1.0)
        return btn
    }

    @objc public func handleCopyPrompt(_ sender: NSButton) {
        guard let text = sender.identifier?.rawValue else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        let originalImage = sender.image
        let originalTitle = sender.title

        if let checkImg = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied") {
            let config = NSImage.SymbolConfiguration(pointSize: 11.5, weight: .bold)
            sender.image = checkImg.withSymbolConfiguration(config)
            sender.title = ""
        } else {
            sender.image = nil
            sender.title = "✓"
        }
        sender.contentTintColor = NSColor(red: 0.35, green: 0.85, blue: 0.45, alpha: 1.0)
        sender.toolTip = "Copied to clipboard"

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            sender.image = originalImage
            sender.title = originalTitle
            sender.contentTintColor = NSColor(white: 0.65, alpha: 1.0)
            sender.toolTip = "Copy prompt"
        }
    }

    @objc public func handleEditPrompt(_ sender: NSButton) {
        guard let text = sender.identifier?.rawValue else { return }
        inputField.stringValue = text
        window?.makeFirstResponder(inputField)
        if let editor = inputField.currentEditor() {
            editor.selectedRange = NSRange(location: text.count, length: 0)
        }
    }

    @objc public func handleRerunPrompt(_ sender: NSButton) {
        guard let text = sender.identifier?.rawValue else { return }
        executePrompt(text)
    }

    public func createUserBubble(msg: ChatMessage, canvasWidth: CGFloat, startY: CGFloat) -> NSView {
        let maxTextW = min(max(canvasWidth * 0.72, 280), 540)
        let font = NSFont.systemFont(ofSize: 13.5, weight: .regular)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 3.5
        paragraphStyle.lineBreakMode = .byWordWrapping

        let trimmedText = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attrText = NSAttributedString(string: trimmedText, attributes: [
            .font: font,
            .foregroundColor: NSColor(white: 0.98, alpha: 1.0),
            .paragraphStyle: paragraphStyle
        ])

        let textStorage = NSTextStorage(attributedString: attrText)
        let textContainer = NSTextContainer(containerSize: NSSize(width: maxTextW, height: CGFloat.greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false

        let layout = NSLayoutManager()
        layout.addTextContainer(textContainer)
        textStorage.addLayoutManager(layout)
        layout.glyphRange(for: textContainer)
        let usedRect = layout.usedRect(for: textContainer)

        let contentW = ceil(usedRect.width) + 8
        let padH: CGFloat = 16
        let padV: CGFloat = 11

        let minBubbleW: CGFloat = 190
        let bubbleW = max(contentW + (padH * 2), minBubbleW)
        let textW = bubbleW - (padH * 2)
        let textH = max(ceil(usedRect.height) + 4, 22)
        let bubbleH = textH + (padV * 2)

        let optionsH: CGFloat = 22
        let optionsSpacing: CGFloat = 6
        let totalH = bubbleH + optionsSpacing + optionsH

        let containerX = canvasWidth - bubbleW - 24
        let container = FlippedCanvasView(frame: NSRect(x: containerX, y: startY, width: bubbleW, height: totalH))

        // 1. Bottom Options Row (aligned under the bubble to the right)
        let optionsRow = FlippedCanvasView(frame: NSRect(x: 0, y: bubbleH + optionsSpacing, width: bubbleW, height: optionsH))

        let btnSize: CGFloat = 20
        let btnSpacing: CGFloat = 6

        // Copy Button (rightmost)
        let copyBtn = createPromptActionButton(
            symbolName: "doc.on.doc",
            fallbackText: "⧉",
            toolTip: "Copy prompt",
            action: #selector(handleCopyPrompt(_:)),
            textPayload: trimmedText
        )
        copyBtn.frame = NSRect(x: bubbleW - btnSize, y: 1, width: btnSize, height: btnSize)
        optionsRow.addSubview(copyBtn)

        // Edit Button (middle)
        let editBtn = createPromptActionButton(
            symbolName: "pencil",
            fallbackText: "✎",
            toolTip: "Edit prompt",
            action: #selector(handleEditPrompt(_:)),
            textPayload: trimmedText
        )
        editBtn.frame = NSRect(x: copyBtn.frame.minX - btnSize - btnSpacing, y: 1, width: btnSize, height: btnSize)
        optionsRow.addSubview(editBtn)

        // Rerun Button (left of edit)
        let rerunBtn = createPromptActionButton(
            symbolName: "arrow.clockwise",
            fallbackText: "↺",
            toolTip: "Rerun prompt",
            action: #selector(handleRerunPrompt(_:)),
            textPayload: trimmedText
        )
        rerunBtn.frame = NSRect(x: editBtn.frame.minX - btnSize - btnSpacing, y: 1, width: btnSize, height: btnSize)
        optionsRow.addSubview(rerunBtn)

        // Relative Timestamp (e.g. "8 hours ago", "Just now")
        let relTimeStr = AIChatWindowController.formatRelativeTime(from: msg.timestamp)
        let timeLabelW: CGFloat = 85
        let timeLabelX = max(0, rerunBtn.frame.minX - timeLabelW - 8)
        let timeLabel = NSTextField(labelWithString: relTimeStr)
        timeLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = NSColor(white: 0.52, alpha: 1.0)
        timeLabel.alignment = .right
        timeLabel.frame = NSRect(x: timeLabelX, y: 2, width: timeLabelW, height: 16)
        let exactTimeStr = DateFormatter.localizedString(from: msg.timestamp, dateStyle: .medium, timeStyle: .short)
        timeLabel.toolTip = "Sent at \(exactTimeStr)"
        optionsRow.addSubview(timeLabel)

        container.addSubview(optionsRow)

        // 2. Prompt Capsule Bubble
        let bubble = FlippedCanvasView(frame: NSRect(x: 0, y: 0, width: bubbleW, height: bubbleH))
        bubble.wantsLayer = true
        bubble.layer?.backgroundColor = NSColor(red: 0.15, green: 0.155, blue: 0.175, alpha: 0.95).cgColor
        bubble.layer?.cornerRadius = 14
        bubble.layer?.borderWidth = 1.0
        bubble.layer?.borderColor = NSColor(white: 0.28, alpha: 0.5).cgColor
        bubble.layer?.shadowColor = NSColor.black.cgColor
        bubble.layer?.shadowOpacity = 0.20
        bubble.layer?.shadowOffset = CGSize(width: 0, height: -2)
        bubble.layer?.shadowRadius = 4
        bubble.toolTip = "User Prompt"

        // Selectable Rich Text View (Zero clipping, native line spacing)
        let textView = NSTextView(frame: NSRect(x: padH, y: padV, width: textW, height: textH))
        textView.textStorage?.setAttributedString(attrText)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        bubble.addSubview(textView)

        container.addSubview(bubble)

        return container
    }

    public func createGeminiCard(msg: ChatMessage, canvasWidth: CGFloat, startY: CGFloat) -> NSView {
        let cardW = canvasWidth - 48
        let textW = cardW - 38

        let trimmedText = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let formattedText = formatGeminiMarkdown(trimmedText)

        let card = FlippedCanvasView(frame: NSRect(x: 24, y: startY, width: cardW, height: 100))

        // Sparkle Avatar
        let sparkle = NSTextField(labelWithString: "✦")
        sparkle.font = NSFont.systemFont(ofSize: 18, weight: .bold)
        sparkle.textColor = NSColor(red: 0.45, green: 0.65, blue: 1.0, alpha: 1.0)
        sparkle.frame = NSRect(x: 2, y: 12, width: 22, height: 22)
        card.addSubview(sparkle)

        // Header Label
        let timeStr = DateFormatter.localizedString(from: msg.timestamp, dateStyle: .none, timeStyle: .short)
        let senderTitle = (msg.sender == .system) ? "System" : "S&D Co-Producer"
        let headerLabel = NSTextField(labelWithString: "\(senderTitle) • \(timeStr)")
        headerLabel.font = NSFont.boldSystemFont(ofSize: 12.5)
        headerLabel.textColor = NSColor(red: 0.70, green: 0.75, blue: 0.85, alpha: 1.0)
        headerLabel.frame = NSRect(x: 28, y: 14, width: min(cardW - 40, 320), height: 18)
        card.addSubview(headerLabel)

        // Body TextView (Selectable, rich formatting)
        let textView = NSTextView(frame: NSRect(x: 28, y: 38, width: textW, height: 10000))
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = .zero
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textStorage?.setAttributedString(formattedText)

        // Measure actual rendered glyph geometry directly from the instantiated NSTextView
        var textH: CGFloat = 22
        if let lm = textView.layoutManager, let tc = textView.textContainer {
            let glyphRange = lm.glyphRange(for: tc)
            let used = lm.usedRect(for: tc)
            if glyphRange.length > 0 {
                let lastGlyph = glyphRange.location + glyphRange.length - 1
                let lastGlyphRect = lm.boundingRect(forGlyphRange: NSRange(location: lastGlyph, length: 1), in: tc)
                textH = max(ceil(lastGlyphRect.maxY), ceil(used.height), 22)
            } else {
                textH = max(ceil(used.height), 22)
            }
        }
        textView.frame = NSRect(x: 28, y: 38, width: textW, height: textH)
        card.addSubview(textView)

        // Action Bar Row (Copy, Share, Thumbs Up, Thumbs Down, More Menu)
        let actionRowY = textView.frame.origin.y + textH + 8
        let btnSize: CGFloat = 28
        let btnSpacing: CGFloat = 8
        var actionX: CGFloat = 28

        // 1. Copy Button (Icon only: doc.on.doc, no text)
        let copyBtn = createActionButton(
            symbolName: "doc.on.doc",
            fallbackText: "❐",
            toolTip: "Copy response",
            action: #selector(handleCopyMessage(_:)),
            textPayload: trimmedText
        )
        copyBtn.frame = NSRect(x: actionX, y: actionRowY, width: btnSize, height: btnSize)
        card.addSubview(copyBtn)
        actionX += btnSize + btnSpacing

        // 2. Share Button (square.and.arrow.up)
        let shareBtn = createActionButton(
            symbolName: "square.and.arrow.up",
            fallbackText: "↗",
            toolTip: "Share response",
            action: #selector(handleShareMessage(_:)),
            textPayload: trimmedText
        )
        shareBtn.frame = NSRect(x: actionX, y: actionRowY, width: btnSize, height: btnSize)
        card.addSubview(shareBtn)
        actionX += btnSize + btnSpacing

        // 3. Thumbs Up Button (hand.thumbsup)
        let thumbsUpBtn = createActionButton(
            symbolName: "hand.thumbsup",
            fallbackText: "👍",
            toolTip: "Good response",
            action: #selector(handleThumbsUp(_:)),
            textPayload: trimmedText
        )
        thumbsUpBtn.frame = NSRect(x: actionX, y: actionRowY, width: btnSize, height: btnSize)
        card.addSubview(thumbsUpBtn)
        actionX += btnSize + btnSpacing

        // 4. Thumbs Down Button (hand.thumbsdown)
        let thumbsDownBtn = createActionButton(
            symbolName: "hand.thumbsdown",
            fallbackText: "👎",
            toolTip: "Bad response",
            action: #selector(handleThumbsDown(_:)),
            textPayload: trimmedText
        )
        thumbsDownBtn.frame = NSRect(x: actionX, y: actionRowY, width: btnSize, height: btnSize)
        card.addSubview(thumbsDownBtn)
        actionX += btnSize + btnSpacing

        // 5. More Menu Button (⋮ vertical ellipsis)
        let moreBtn = createActionButton(
            symbolName: "ellipsis",
            fallbackText: "⋮",
            toolTip: "More actions",
            action: #selector(handleMoreMenu(_:)),
            textPayload: trimmedText
        )
        moreBtn.frame = NSRect(x: actionX, y: actionRowY, width: btnSize, height: btnSize)
        card.addSubview(moreBtn)

        let cardH = actionRowY + btnSize + 4
        card.frame = NSRect(x: 24, y: startY, width: cardW, height: cardH)

        return card
    }

    private func createActionButton(
        symbolName: String,
        fallbackText: String,
        toolTip: String,
        action: Selector,
        textPayload: String
    ) -> NSButton {
        let btn = NSButton()
        btn.isBordered = false
        btn.bezelStyle = .regularSquare
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 14
        btn.layer?.backgroundColor = NSColor(white: 0.18, alpha: 0.55).cgColor
        btn.toolTip = toolTip
        btn.target = self
        btn.action = action
        btn.identifier = NSUserInterfaceItemIdentifier(rawValue: textPayload)

        if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: toolTip) {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            btn.image = symbol.withSymbolConfiguration(config)
            btn.imagePosition = .imageOnly
            btn.title = ""
        } else {
            btn.title = fallbackText
            btn.font = NSFont.systemFont(ofSize: 13)
        }
        btn.contentTintColor = NSColor(white: 0.75, alpha: 1.0)
        return btn
    }

    @objc private func handleCopyMessage(_ sender: NSButton) {
        guard let text = sender.identifier?.rawValue else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        let originalImage = sender.image
        let originalTitle = sender.title

        if let checkImg = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied") {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .bold)
            sender.image = checkImg.withSymbolConfiguration(config)
            sender.title = ""
        } else {
            sender.image = nil
            sender.title = "✓"
        }
        sender.contentTintColor = NSColor(red: 0.35, green: 0.85, blue: 0.45, alpha: 1.0)
        sender.toolTip = "Copied to clipboard"

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            sender.image = originalImage
            sender.title = originalTitle
            sender.contentTintColor = NSColor(white: 0.75, alpha: 1.0)
            sender.toolTip = "Copy response"
        }
    }

    @objc private func handleShareMessage(_ sender: NSButton) {
        guard let text = sender.identifier?.rawValue else { return }
        let picker = NSSharingServicePicker(items: [text])
        picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    @objc private func handleThumbsUp(_ sender: NSButton) {
        sender.contentTintColor = NSColor(red: 0.35, green: 0.85, blue: 0.45, alpha: 1.0)
        sender.toolTip = "Helpful response"
    }

    @objc private func handleThumbsDown(_ sender: NSButton) {
        sender.contentTintColor = NSColor(red: 1.0, green: 0.45, blue: 0.45, alpha: 1.0)
        sender.toolTip = "Needs improvement"
    }

    @objc private func handleMoreMenu(_ sender: NSButton) {
        guard let text = sender.identifier?.rawValue else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false

        // 1. Export to Docs
        let docsItem = NSMenuItem(title: "Export to Docs", action: #selector(handleExportToDocs(_:)), keyEquivalent: "")
        if let img = NSImage(systemSymbolName: "doc.text", accessibilityDescription: "Docs") {
            docsItem.image = img
        } else {
            docsItem.title = "📄  Export to Docs"
        }
        docsItem.target = self
        docsItem.representedObject = text
        menu.addItem(docsItem)

        // 2. Draft in Gmail
        let gmailItem = NSMenuItem(title: "Draft in Gmail", action: #selector(handleDraftInGmail(_:)), keyEquivalent: "")
        if let img = NSImage(systemSymbolName: "envelope", accessibilityDescription: "Gmail") {
            gmailItem.image = img
        } else {
            gmailItem.title = "✉️  Draft in Gmail"
        }
        gmailItem.target = self
        gmailItem.representedObject = text
        menu.addItem(gmailItem)

        menu.addItem(NSMenuItem.separator())

        // 3. About this response
        let aboutItem = NSMenuItem(title: "About this response", action: #selector(handleAboutThisResponse(_:)), keyEquivalent: "")
        if let img = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "About") {
            aboutItem.image = img
        } else {
            aboutItem.title = "ℹ️  About this response"
        }
        aboutItem.target = self
        aboutItem.representedObject = text
        menu.addItem(aboutItem)

        let loc = NSPoint(x: 0, y: sender.bounds.height + 4)
        menu.popUp(positioning: nil, at: loc, in: sender)
    }

    @objc private func handleExportToDocs(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        if let docsURL = URL(string: "https://docs.new") {
            NSWorkspace.shared.open(docsURL)
        }
        VoiceAnnouncer.shared.speak("Exporting to Google Docs. Response copied to clipboard.")
    }

    @objc private func handleDraftInGmail(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        var components = URLComponents(string: "https://mail.google.com/mail/")!
        components.queryItems = [
            URLQueryItem(name: "view", value: "cm"),
            URLQueryItem(name: "fs", value: "1"),
            URLQueryItem(name: "su", value: "S&D Co-Producer Audio Report"),
            URLQueryItem(name: "body", value: text)
        ]
        if let mailURL = components.url {
            NSWorkspace.shared.open(mailURL)
        }
        VoiceAnnouncer.shared.speak("Drafting report in Gmail.")
    }

    @objc private func handleAboutThisResponse(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "About S&D Co-Producer Response"
        alert.informativeText = """
        • Grounding: Grounded by official SSL UF8 & Universal Audio Apollo hardware manuals and acoustic mixing guidelines.
        • Mixer Telemetry: Live 32-channel converter peak levels, preamp relays, and gain staging margins.
        • Tactile Surface: Controls SSL UF8 motorized faders, scribble strip HUD, and Unison preamp hardware.
        • Privacy & Speed: Direct commands run 100% locally with 0ms latency; reasoning powered by Google Gemini 3.8 Flash.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        if let win = self.window {
            alert.beginSheetModal(for: win, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    private func formatGeminiMarkdown(_ raw: String) -> NSAttributedString {
        let baseFont = NSFont.systemFont(ofSize: 13.5)
        let boldFont = NSFont.boldSystemFont(ofSize: 13.5)
        let italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
        let codeFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        let textColor = NSColor(white: 0.92, alpha: 1.0)
        let codeBg = NSColor(white: 0.18, alpha: 1.0)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 3.5
        paragraphStyle.paragraphSpacing = 5.0

        let attributed = NSMutableAttributedString()
        let cleanRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = cleanRaw.components(separatedBy: "\n")

        for (index, line) in lines.enumerated() {
            let isHeader = line.hasPrefix("### ") || line.hasPrefix("## ") || line.hasPrefix("# ")
            let cleanLine = isHeader
                ? line.replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
                : line

            let lineAttr = NSMutableAttributedString(
                string: cleanLine + (index < lines.count - 1 ? "\n" : ""),
                attributes: [
                    .font: isHeader ? NSFont.boldSystemFont(ofSize: 15) : baseFont,
                    .foregroundColor: isHeader ? NSColor(red: 0.45, green: 0.70, blue: 1.0, alpha: 1.0) : textColor,
                    .paragraphStyle: paragraphStyle
                ]
            )

            // Parse bold **text**
            let boldPattern = "\\*\\*(.*?)\\*\\*"
            if let regex = try? NSRegularExpression(pattern: boldPattern) {
                let matches = regex.matches(in: lineAttr.string, range: NSRange(location: 0, length: lineAttr.length))
                for match in matches.reversed() {
                    let innerRange = match.range(at: 1)
                    let fullRange = match.range(at: 0)
                    let boldWord = (lineAttr.string as NSString).substring(with: innerRange)
                    let replacement = NSAttributedString(string: boldWord, attributes: [
                        .font: boldFont,
                        .foregroundColor: NSColor.white,
                        .paragraphStyle: paragraphStyle
                    ])
                    lineAttr.replaceCharacters(in: fullRange, with: replacement)
                }
            }

            // Parse *italic* (single asterisk, not bold)
            let italicPattern = "(?<!\\*)\\*(?!\\*)(.*?)(?<!\\*)\\*(?!\\*)"
            if let regex = try? NSRegularExpression(pattern: italicPattern) {
                let matches = regex.matches(in: lineAttr.string, range: NSRange(location: 0, length: lineAttr.length))
                for match in matches.reversed() {
                    let innerRange = match.range(at: 1)
                    let fullRange = match.range(at: 0)
                    let italicWord = (lineAttr.string as NSString).substring(with: innerRange)
                    let replacement = NSAttributedString(string: italicWord, attributes: [
                        .font: italicFont,
                        .foregroundColor: NSColor(white: 0.90, alpha: 1.0),
                        .paragraphStyle: paragraphStyle
                    ])
                    lineAttr.replaceCharacters(in: fullRange, with: replacement)
                }
            }

            // Parse `code`
            let codePattern = "`(.*?)`"
            if let regex = try? NSRegularExpression(pattern: codePattern) {
                let matches = regex.matches(in: lineAttr.string, range: NSRange(location: 0, length: lineAttr.length))
                for match in matches.reversed() {
                    let innerRange = match.range(at: 1)
                    let fullRange = match.range(at: 0)
                    let codeWord = (lineAttr.string as NSString).substring(with: innerRange)
                    let replacement = NSAttributedString(string: " \(codeWord) ", attributes: [
                        .font: codeFont,
                        .foregroundColor: NSColor(red: 0.55, green: 0.85, blue: 1.0, alpha: 1.0),
                        .backgroundColor: codeBg,
                        .paragraphStyle: paragraphStyle
                    ])
                    lineAttr.replaceCharacters(in: fullRange, with: replacement)
                }
            }

            attributed.append(lineAttr)
        }

        return attributed
    }

    // MARK: - Actions & Query Flow

    @objc private func handleSend() {
        if isExecuting {
            cancelExecution()
            return
        }
        let q = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        executePrompt(q)
    }

    public func executePrompt(_ q: String) {
        guard !isExecuting else { return }
        currentThinkingText = "✦ S&D Co-Producer is thinking..."
        inputField.stringValue = ""

        messages.append(ChatMessage(sender: .user, text: q, timestamp: Date()))
        isExecuting = true
        renderCanvas()

        updateSendButtonForExecutingState(true)
        spinner.startAnimation(nil)

        AIChatEngine.shared.processQuery(query: q, uad: uad, auditor: auditor, progress: { [weak self] status in
            DispatchQueue.main.async {
                guard let self = self, self.isExecuting else { return }
                self.currentThinkingText = status
                self.thinkingStatusLabel?.stringValue = status
            }
        }) { [weak self] reply in
            guard let self = self else { return }
            guard self.isExecuting else { return }
            self.isExecuting = false
            self.updateSendButtonForExecutingState(false)
            self.spinner.stopAnimation(nil)
            self.messages.append(ChatMessage(sender: .gemini, text: reply, timestamp: Date()))
            self.renderCanvas()
        }
    }

    @objc public func cancelExecution() {
        guard isExecuting else { return }
        AIChatEngine.shared.cancelCurrentQuery()
        isExecuting = false
        updateSendButtonForExecutingState(false)
        spinner.stopAnimation(nil)
        messages.append(ChatMessage(sender: .system, text: "⏹ *Execution cancelled.*", timestamp: Date()))
        renderCanvas()
    }

    private func updateSendButtonForExecutingState(_ executing: Bool) {
        if executing {
            sendButton.title = "■"
            sendButton.font = NSFont.boldSystemFont(ofSize: 13)
            sendButton.layer?.backgroundColor = NSColor(red: 0.85, green: 0.24, blue: 0.24, alpha: 1.0).cgColor
            sendButton.toolTip = "Cancel execution (Esc)"
        } else {
            sendButton.title = "↑"
            sendButton.font = NSFont.systemFont(ofSize: 18, weight: .bold)
            sendButton.layer?.backgroundColor = NSColor(red: 0.10, green: 0.45, blue: 0.91, alpha: 1.0).cgColor
            sendButton.toolTip = "Send prompt (Return)"
        }
    }

    @objc private func handleNewChat() {
        if isExecuting {
            cancelExecution()
        }
        messages.removeAll()
        renderCanvas()
        inputField.stringValue = ""
    }

    public func updateModelBadge() {
        guard let badge = modelBadge else { return }
        let provider = AIChatEngine.shared.aiProvider.lowercased()
        switch provider {
        case "local":
            badge.stringValue = "Llama 3.2 • Apollo Live"
            badge.textColor = NSColor(red: 0.40, green: 0.95, blue: 0.65, alpha: 1.0)
            badge.layer?.borderColor = NSColor(red: 0.20, green: 0.80, blue: 0.45, alpha: 0.6).cgColor
            badge.layer?.backgroundColor = NSColor(red: 0.10, green: 0.25, blue: 0.16, alpha: 0.7).cgColor
        case "gemini":
            badge.stringValue = "3.8 Flash • Apollo Live"
            badge.textColor = NSColor(red: 0.55, green: 0.82, blue: 1.0, alpha: 1.0)
            badge.layer?.borderColor = NSColor(red: 0.25, green: 0.45, blue: 0.80, alpha: 0.6).cgColor
            badge.layer?.backgroundColor = NSColor(red: 0.15, green: 0.22, blue: 0.35, alpha: 0.7).cgColor
        default: // auto
            badge.stringValue = "Auto (Llama 3.2) • Live"
            badge.textColor = NSColor(red: 0.95, green: 0.80, blue: 0.40, alpha: 1.0)
            badge.layer?.borderColor = NSColor(red: 0.80, green: 0.60, blue: 0.20, alpha: 0.6).cgColor
            badge.layer?.backgroundColor = NSColor(red: 0.30, green: 0.22, blue: 0.10, alpha: 0.7).cgColor
        }
    }

    @objc private func handleOpenProviderMenu(_ sender: NSButton) {
        let menu = NSMenu(title: "AI Provider & Settings")

        let autoItem = NSMenuItem(title: "Auto (Local Llama 3.2 if available, else Gemini)", action: #selector(handleSelectProviderMode(_:)), keyEquivalent: "")
        autoItem.target = self
        autoItem.representedObject = "auto"
        autoItem.state = (AIChatEngine.shared.aiProvider == "auto") ? .on : .off
        menu.addItem(autoItem)

        let localItem = NSMenuItem(title: "Local LLM Only (Ollama - Llama 3.2 - Default)", action: #selector(handleSelectProviderMode(_:)), keyEquivalent: "")
        localItem.target = self
        localItem.representedObject = "local"
        localItem.state = (AIChatEngine.shared.aiProvider == "local") ? .on : .off
        menu.addItem(localItem)

        let geminiItem = NSMenuItem(title: "Google Gemini Cloud (API Key)", action: #selector(handleSelectProviderMode(_:)), keyEquivalent: "")
        geminiItem.target = self
        geminiItem.representedObject = "gemini"
        geminiItem.state = (AIChatEngine.shared.aiProvider == "gemini") ? .on : .off
        menu.addItem(geminiItem)

        menu.addItem(NSMenuItem.separator())

        let configOllamaItem = NSMenuItem(title: "Configure Local LLM Endpoint (Ollama)...", action: #selector(handleConfigureOllama), keyEquivalent: "")
        configOllamaItem.target = self
        menu.addItem(configOllamaItem)

        let configGeminiItem = NSMenuItem(title: "Configure Google Gemini API Key...", action: #selector(handleSetApiKey), keyEquivalent: "")
        configGeminiItem.target = self
        menu.addItem(configGeminiItem)

        let startOllamaItem = NSMenuItem(title: "Start / Check Local Ollama Service", action: #selector(handleStartOllamaService), keyEquivalent: "")
        startOllamaItem.target = self
        menu.addItem(startOllamaItem)

        let location = NSPoint(x: 0, y: sender.bounds.height + 4)
        menu.popUp(positioning: nil, at: location, in: sender)
    }

    @objc private func handleSelectProviderMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        AIChatEngine.shared.aiProvider = mode
        UserDefaults.standard.set(mode, forKey: "UAMCUAIProvider")
        updateModelBadge()
        let desc = mode == "local" ? "Local LLM Only (Ollama - Llama 3.2)" : (mode == "gemini" ? "Google Gemini Cloud API" : "Auto Mode (Local Llama 3.2 preferred)")
        messages.append(ChatMessage(sender: .system, text: "AI Provider switched to: \(desc)", timestamp: Date()))
        renderCanvas()
    }

    @objc private func handleConfigureOllama() {
        OllamaConfigDialogHelper.present(
            currentEndpoint: AIChatEngine.shared.ollamaEndpoint,
            currentModel: AIChatEngine.shared.ollamaModel,
            window: self.window
        ) { [weak self] ep, mod in
            guard let self = self else { return }
            AIChatEngine.shared.ollamaEndpoint = ep
            AIChatEngine.shared.ollamaModel = mod
            UserDefaults.standard.set(ep, forKey: "UAMCUOllamaEndpoint")
            UserDefaults.standard.set(mod, forKey: "UAMCUOllamaModel")
            self.updateModelBadge()
            self.messages.append(ChatMessage(sender: .system, text: "Local LLM configured: \(mod) at \(ep)", timestamp: Date()))
            self.renderCanvas()
        }
    }

    @objc private func handleStartOllamaService() {
        self.messages.append(ChatMessage(sender: .system, text: "Checking / starting Local Ollama service in background...", timestamp: Date()))
        self.renderCanvas()
        OllamaServiceManager.shared.ensureOllamaRunning(endpoint: AIChatEngine.shared.ollamaEndpoint) { [weak self] running in
            DispatchQueue.main.async {
                let msg = running ? "● Local Ollama is online and ready!" : "○ Local Ollama could not be reached. Ensure Ollama is installed."
                self?.messages.append(ChatMessage(sender: .system, text: msg, timestamp: Date()))
                self?.renderCanvas()
            }
        }
    }

    @objc private func handleSetApiKey() {
        ApiKeyDialogHelper.present(
            title: "Configure Google Gemini API Key",
            currentKey: AIChatEngine.shared.geminiApiKey,
            window: self.window
        ) { [weak self] newKey in
            guard let self = self else { return }
            AIChatEngine.shared.geminiApiKey = newKey
            UserDefaults.standard.set(newKey, forKey: "UAMCUGeminiApiKey")
            let statusText = newKey.isEmpty
                ? "Gemini API key cleared (Offline mixer commands active)."
                : "Gemini API key saved (\(newKey.prefix(6))...)! Full Gemini 3.8 Flash acoustic reasoning enabled."
            self.messages.append(ChatMessage(sender: .system, text: statusText, timestamp: Date()))
            self.renderCanvas()
        }
    }

    @objc public func handleShowPromptHelp() {
        AIPromptHelpWindowController.shared.showHelp(relativeTo: self.window, onSelectPrompt: { [weak self] prompt in
            self?.executePrompt(prompt)
        })
    }

    public override func cancelOperation(_ sender: Any?) {
        if isExecuting {
            cancelExecution()
        } else {
            self.window?.close()
        }
    }

    public func windowWillClose(_ notification: Notification) {
        if isExecuting {
            cancelExecution()
        }
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name("ShowAIPromptHelpNotification"), object: nil)
        AIChatWindowController.current = nil
    }
}
