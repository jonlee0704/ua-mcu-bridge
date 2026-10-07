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

/// Represents a single diagnostic finding and action recommendation by the AI Studio Co-Producer.
public struct AISuggestion {
    public let id: String
    public let channelId: Int
    public let channelName: String
    public let issueTitle: String
    public let voiceDescription: String
    public let lcdBanner: String
    public var isApplied: Bool = false
    public var isSkipped: Bool = false
    public let applyAction: (() -> String)?

    public init(id: String, channelId: Int, channelName: String, issueTitle: String, voiceDescription: String, lcdBanner: String, applyAction: (() -> String)? = nil) {
        self.id = id
        self.channelId = channelId
        self.channelName = channelName
        self.issueTitle = issueTitle
        self.voiceDescription = voiceDescription
        self.lcdBanner = lcdBanner
        self.applyAction = applyAction
    }
}

/// Interactive AI Studio Co-Producer and Pre-Flight Audio Inspector.
/// Triggered via the FINE key (Note 70) and navigated via the 4-way arrow cluster (Up/Down/Left/Right).
public final class AIAudioAuditor {
    public enum State {
        case idle
        case listening
        case analyzing
        case consulting
        case completed
    }

    public weak var mcu: MCUEngine?
    public unowned let uad: UADClient
    public unowned let voice: VoiceAnnouncer

    public private(set) var isActive: Bool = false
    public private(set) var state: State = .idle
    public private(set) var suggestions: [AISuggestion] = []
    public private(set) var currentIndex: Int = 0

    // Telemetry recorded during the listening window
    private var recordedPeaks: [Int: Double] = [:]
    private var recordedClips: [Int: Bool] = [:]
    private var listenTimer: DispatchSourceTimer?
    private let lock = NSLock()

    public init(uadClient: UADClient, voice: VoiceAnnouncer = .shared) {
        self.uad = uadClient
        self.voice = voice
    }

    // MARK: - Session Lifecycle

    /// Main entry point when user presses the FINE button (Note 83 / Note 70).
    /// The cycle of FINE(AI) button is:
    /// 1) Start AI listening -> 2) Stop listening -> 3) Exit AI mode.
    public func handleFineButton() {
        switch state {
        case .idle:
            // 1) Start AI listening
            startListening()
        case .listening:
            // 2) Stop listening
            stopListening()
        case .analyzing:
            break
        case .consulting, .completed:
            // 3) Exit AI mode
            exitSession()
        }
    }

    /// 1) Start AI listening: begins continuous listening across 32 channels until user stops.
    public func startListening() {
        lock.lock()
        listenTimer?.cancel()
        listenTimer = nil
        isActive = true
        state = .listening
        suggestions.removeAll()
        recordedPeaks.removeAll()
        recordedClips.removeAll()
        currentIndex = 0
        lock.unlock()

        bridgeLog("[AI Auditor] Started AI listening across 32 channels. Waiting for user to press FINE to stop...")
        mcu?.sendMIDI([0x90, 83, 0x7F]) // Illuminate FINE key (Note 83)
        mcu?.sendMIDI([0x90, 70, 0x7F])
        mcu?.showTempHUD(text: ">>> GEMINI AI [ALPHA]: LISTENING (PRESS FINE TO STOP) <<<", duration: 6.0)
        voice.speak("AI Co-Producer listening across 32 channels. Play your mix, then press Fine to stop listening.")
    }

    /// 2) Stop listening: halts accumulation, analyzes audio, generates report, and presents findings.
    public func stopListening() {
        guard state == .listening else { return }
        lock.lock()
        state = .analyzing
        lock.unlock()

        bridgeLog("[AI Auditor] Stopped listening. Analyzing recorded mixer telemetry...")
        mcu?.showTempHUD(text: ">>> ANALYZING MIXER STATE & GAIN STAGING <<<", duration: 1.5)
        voice.speak("Stopped listening. Analyzing mix...")

        finishListeningAndAnalyze()
    }

    /// Starts or restarts the AI Studio session directly in listening mode.
    public func startSession() {
        startListening()
    }

    /// 3) Exit AI mode: exits the session cleanly and returns surface to Main Mix.
    public func exitSession() {
        lock.lock()
        listenTimer?.cancel()
        listenTimer = nil
        isActive = false
        state = .idle
        lock.unlock()

        bridgeLog("[AI Auditor] Exited AI Studio session.")
        mcu?.sendMIDI([0x90, 83, 0x00]) // Turn off FINE key LED (Note 83)
        mcu?.sendMIDI([0x90, 70, 0x00])
        mcu?.showTempHUD(text: ">>> EXITED AI MODE [ALPHA] <<<", duration: 1.2)
        voice.speak("Exited AI Alpha session. Main mix.")
        mcu?.refreshMainMixSurface()
    }

    // MARK: - Telemetry Collection

    /// Accumulates live meter updates from the Apollo engine while listening is active.
    public func recordTelemetry(chId: Int, peakDb: Double, isClip: Bool) {
        guard isActive, state == .listening else { return }
        lock.lock()
        let currentPeak = recordedPeaks[chId] ?? -144.0
        if peakDb > currentPeak {
            recordedPeaks[chId] = peakDb
        }
        if isClip {
            recordedClips[chId] = true
        }
        lock.unlock()
    }

    // MARK: - Analysis & Rule Engine

    private func finishListeningAndAnalyze() {
        lock.lock()
        state = .analyzing
        lock.unlock()

        bridgeLog("[AI Auditor] Analyzing recorded mixer telemetry...")
        mcu?.showTempHUD(text: ">>> ANALYZING MIXER STATE & GAIN STAGING <<<", duration: 1.5)

        // Evaluate rules across active channels
        var findings: [AISuggestion] = []

        let allChannels = uad.channels.values.sorted(by: { $0.id < $1.id })
        var maxSessionPeak: Double = -144.0
        for ch in allChannels {
            let p = recordedPeaks[ch.id] ?? ch.meterPeak
            if p > maxSessionPeak { maxSessionPeak = p }
        }

        // =========================================================================
        // STEP 2: ONE-TOUCH MOTORIZED FADER AUTO-ROUGH MIX
        // Analyzes musical roles & incoming peak energies, then aligns all faders
        // =========================================================================
        let activeChannels = allChannels.filter { (recordedPeaks[$0.id] ?? $0.meterPeak) > -50.0 }
        if activeChannels.count >= 2 {
            let roughMixSuggestion = AISuggestion(
                id: "auto_rough_mix",
                channelId: -1,
                channelName: "Rough Mix",
                issueTitle: "One-Touch Auto-Rough Mix",
                voiceDescription: "I analyzed \(activeChannels.count) active tracks in your session. Would you like me to auto-balance all motorized faders into a clean rough mix with vocal in front, rhythm section locked, and 6 d B master headroom?",
                lcdBanner: "[AUTO-ROUGH MIX] BALANCE ALL FADERS? ▲YES ▼NO",
                applyAction: { [weak self] in
                    guard let self = self else { return "" }
                    for ch in allChannels {
                        let pk = self.recordedPeaks[ch.id] ?? ch.meterPeak
                        let lower = ch.name.lowercased()
                        if pk < -60.0 {
                            // Dead / Inactive track -> Pull fader to floor (-144 dB)
                            let tap = UADCurve.dbToTapered(-144.0)
                            self.uad.setFader(chId: ch.id, tapered: tap)
                            continue
                        }
                        // Musical role target peak levels (dBFS)
                        let targetAudiblePeak: Double
                        if lower.contains("vox") || lower.contains("vocal") || lower.contains("lead") || lower.contains("mic") {
                            targetAudiblePeak = -12.0 // Lead Vocal right in front
                        } else if lower.contains("kd") || lower.contains("kick") || lower.contains("bd") {
                            targetAudiblePeak = -14.0 // Kick anchor
                        } else if lower.contains("sd") || lower.contains("snare") {
                            targetAudiblePeak = -15.0 // Snare backbeat
                        } else if lower.contains("bass") || lower.contains("ampeg") {
                            targetAudiblePeak = -16.0 // Bass foundation
                        } else if lower.contains("t1") || lower.contains("t2") || lower.contains("t3") || lower.contains("tom") {
                            targetAudiblePeak = -18.0 // Toms
                        } else if lower.contains("oh") || lower.contains("cymbal") || lower.contains("hat") {
                            targetAudiblePeak = -20.0 // Cymbals air
                        } else if lower.contains("qc") || lower.contains("guitar") || lower.contains("gtr") || lower.contains("juno") || lower.contains("keys") {
                            targetAudiblePeak = -17.0 // Guitars / Synths
                        } else if ch.chType == "aux" {
                            targetAudiblePeak = -18.0 // FX returns
                        } else {
                            targetAudiblePeak = -16.0
                        }
                        let deltaDb = targetAudiblePeak - pk
                        let newFaderDb = max(-144.0, min(6.0, ch.faderDb + deltaDb))
                        let tap = UADCurve.dbToTapered(newFaderDb)
                        self.uad.setFader(chId: ch.id, tapered: tap)
                    }
                    // Immediately refresh physical motorized faders on active UF8 bank
                    if let m = self.mcu {
                        for slot in 0..<8 {
                            let chId = m.bankOffset + slot
                            if let ch = self.uad.channels[chId] {
                                m.sendFaderPosition(slot: slot, normVal: ch.fader)
                            }
                        }
                    }
                    return "Balanced all motorized faders into a clean rough mix."
                }
            )
            findings.append(roughMixSuggestion)
        }

        // =========================================================================
        // STEP 1A: MULTI-MIC PHASE RELATIONSHIP & POLARITY INVERT (Ø)
        // Checks paired acoustic mics (Snare Top/Bottom, Kick In/Out) for cancellation
        // =========================================================================
        let snareTop = allChannels.first { ch in
            let l = ch.name.lowercased()
            return (l == "sd" || l.starts(with: "sd ") || l.contains("snare")) &&
                   !l.contains("bottom") && !l.contains("btm") && !l.contains("bot") && !l.contains("under")
        }
        let snareBtm = allChannels.first { ch in
            let l = ch.name.lowercased()
            return l.contains("sd-bottom") || l.contains("sd-btm") || l.contains("snare-b") ||
                   l.contains("snare bottom") || l.contains("snare_btm") || l.contains("sd_btm") ||
                   (l.contains("bottom") && (l.contains("sd") || l.contains("snare")))
        }
        if let top = snareTop, let btm = snareBtm {
            let topPeak = recordedPeaks[top.id] ?? top.meterPeak
            let btmPeak = recordedPeaks[btm.id] ?? btm.meterPeak
            if topPeak > -45.0 && btmPeak > -45.0 && btm.preamp.hasPreamp && !btm.preamp.phase {
                let phaseSuggestion = AISuggestion(
                    id: "phase_snare_\(btm.id)",
                    channelId: btm.id,
                    channelName: btm.name,
                    issueTitle: "Snare Phase Cancellation",
                    voiceDescription: "Snare Bottom on \(btm.name) is in normal polarity with Snare Top, causing low-mid phase cancellation. Would you like me to invert the phase on \(btm.name)?",
                    lcdBanner: "[\(btm.name.uppercased())] PHASE CANCEL: INVERT Ø? ▲YES ▼NO",
                    applyAction: { [weak self] in
                        guard let self = self else { return "" }
                        self.uad.setPreampPhase(chId: btm.id, inverted: true)
                        return "Inverted phase polarity on \(btm.name)."
                    }
                )
                findings.append(phaseSuggestion)
            }
        }

        let kickIn = allChannels.first { ch in
            let l = ch.name.lowercased()
            return (l == "kd" || l.starts(with: "kd ") || l.contains("kick in") || l.contains("kick-in") || l.contains("kd-in")) && !l.contains("out")
        }
        let kickOut = allChannels.first { ch in
            let l = ch.name.lowercased()
            return l.contains("kd-out") || l.contains("kd_out") || l.contains("kick out") || l.contains("kick-out")
        }
        if let kin = kickIn, let kout = kickOut {
            let kinPeak = recordedPeaks[kin.id] ?? kin.meterPeak
            let koutPeak = recordedPeaks[kout.id] ?? kout.meterPeak
            if kinPeak > -45.0 && koutPeak > -45.0 && kout.preamp.hasPreamp && !kout.preamp.phase {
                let phaseSuggestion = AISuggestion(
                    id: "phase_kick_\(kout.id)",
                    channelId: kout.id,
                    channelName: kout.name,
                    issueTitle: "Kick Dual-Mic Phase Alignment",
                    voiceDescription: "Kick In and Kick Out dual mics are both active. Inverting phase on \(kout.name) can align low-end punch. Would you like me to invert Kick Out phase?",
                    lcdBanner: "[\(kout.name.uppercased())] KICK DUAL-MIC: INVERT Ø? ▲YES ▼NO",
                    applyAction: { [weak self] in
                        guard let self = self else { return "" }
                        self.uad.setPreampPhase(chId: kout.id, inverted: true)
                        return "Inverted phase polarity on \(kout.name)."
                    }
                )
                findings.append(phaseSuggestion)
            }
        }

        // =========================================================================
        // STEP 1B: KICK & BASS LOW-END COLLISION RESOLVER
        // Detects competing sub energy and tucks bass to create a clear kick pocket
        // =========================================================================
        let kickPrimary = allChannels.first { ch in
            let l = ch.name.lowercased()
            return (l == "kd" || l.contains("kick") || l.contains("bd")) && ch.chType != "aux"
        }
        let bassPrimary = allChannels.first { ch in
            let l = ch.name.lowercased()
            return (l.contains("bass") || l.contains("ampeg") || l.contains("sub")) && ch.chType != "aux"
        }
        if let kch = kickPrimary, let bch = bassPrimary {
            let kPeak = recordedPeaks[kch.id] ?? kch.meterPeak
            let bPeak = recordedPeaks[bch.id] ?? bch.meterPeak
            if kPeak > -28.0 && bPeak > -28.0 {
                let collisionSuggestion = AISuggestion(
                    id: "collision_\(bch.id)",
                    channelId: bch.id,
                    channelName: bch.name,
                    issueTitle: "Kick & Bass Low-End Masking",
                    voiceDescription: "Kick drum on \(kch.name) and Bass on \(bch.name) are competing for sub headroom. Would you like me to tuck \(bch.name) down by 3 d B so the kick cuts through clearly?",
                    lcdBanner: "[\(bch.name.uppercased())] KICK/BASS MASK: TUCK BASS -3dB? ▲YES ▼NO",
                    applyAction: { [weak self] in
                        guard let self = self else { return "" }
                        let currentDb = bch.faderDb
                        let targetDb = max(-144.0, currentDb - 3.0)
                        let tap = UADCurve.dbToTapered(targetDb)
                        self.uad.setFader(chId: bch.id, tapered: tap)
                        if let m = self.mcu {
                            let slot = bch.id - m.bankOffset
                            if slot >= 0 && slot < 8 {
                                m.sendFaderPosition(slot: slot, normVal: tap)
                            }
                        }
                        return "Tucked \(bch.name) down by 3 d B for clean sub clarity."
                    }
                )
                findings.append(collisionSuggestion)
            }
        }

        for ch in allChannels {
            let chId = ch.id
            let chName = ch.name
            let peak = recordedPeaks[chId] ?? ch.meterPeak
            let clipped = (recordedClips[chId] == true) || ch.meterClip || peak >= -0.1

            // Rule 1: DIGITAL OVERLOAD / CLIPPING (Sound-Critical)
            if clipped {
                let currentGain = ch.preamp.gain
                let isPreamp = ch.preamp.hasPreamp
                // Best practice target: -14.0 dBFS peak (leaving 14 dB of converter headroom)
                let targetHeadroomPeak = -14.0
                let trimDb = max(6.0, round(peak - targetHeadroomPeak))
                let suggestion = AISuggestion(
                    id: "clip_\(chId)",
                    channelId: chId,
                    channelName: chName,
                    issueTitle: "Clipping / Overload",
                    voiceDescription: "Channel \(chId + 1), \(chName), is clipping at \(String(format: "%.1f", peak)) d B. Best practice recommends 14 d B of headroom, targeting minus 14 d B F S. Would you like me to auto-trim gain down by \(Int(trimDb)) d B to clear clipping and protect your converters?",
                    lcdBanner: "[CH \(chId + 1)] CLIP: TRIM -\(Int(trimDb))dB (14dB HEADROOM)? ▲YES ▼NO",
                    applyAction: { [weak self] in
                        guard let self = self else { return "" }
                        // Clear hardware and software clip states
                        ch.meterClip = false
                        self.recordedClips[chId] = false
                        if isPreamp {
                            let targetGain = max(10.0, currentGain - trimDb)
                            self.uad.setPreampGain(chId: chId, gainDb: targetGain)
                            if let m = self.mcu {
                                let slot = chId - m.bankOffset
                                if slot >= 0 && slot < 8 {
                                    m.sendMeterLevel(slot: slot, db: targetHeadroomPeak, isClip: false)
                                }
                            }
                            return "Cleared clipping on \(chName) and trimmed preamp gain down by \(Int(trimDb)) d B to \(Int(targetGain)) d B."
                        } else {
                            let targetFaderDb = max(-144.0, ch.faderDb - trimDb)
                            let tap = UADCurve.dbToTapered(targetFaderDb)
                            self.uad.setFader(chId: chId, tapered: tap)
                            if let m = self.mcu {
                                let slot = chId - m.bankOffset
                                if slot >= 0 && slot < 8 {
                                    m.sendFaderPosition(slot: slot, normVal: tap)
                                    m.sendMeterLevel(slot: slot, db: targetHeadroomPeak, isClip: false)
                                }
                            }
                            return "Cleared clipping on \(chName) and trimmed fader down by \(Int(trimDb)) d B."
                        }
                    }
                )
                findings.append(suggestion)
                continue
            }

            // Rule 1B: DANGEROUSLY HOT SIGNAL / INADEQUATE HEADROOM (Exceeds -3.0 dBFS with no clip yet)
            if peak > -3.0 && !clipped && !ch.mute {
                let currentGain = ch.preamp.gain
                let isPreamp = ch.preamp.hasPreamp
                let trimDb = max(3.0, round(peak - (-14.0)))
                let currentHeadroom = max(0.0, -peak)
                let suggestion = AISuggestion(
                    id: "hot_\(chId)",
                    channelId: chId,
                    channelName: chName,
                    issueTitle: "Hot Signal (Low Headroom)",
                    voiceDescription: "Channel \(chId + 1), \(chName), is peaking hot at \(String(format: "%.1f", peak)) d B with only \(String(format: "%.1f", currentHeadroom)) d B of headroom. Best practice recommends 12 to 14 d B of headroom. Would you like me to trim gain down by \(Int(trimDb)) d B to reach the minus 14 d B sweet spot?",
                    lcdBanner: "[CH \(chId + 1)] HOT (\(String(format: "%.1f", peak))dB): TRIM -\(Int(trimDb))dB? ▲YES ▼NO",
                    applyAction: { [weak self] in
                        guard let self = self else { return "" }
                        if isPreamp {
                            let targetGain = max(10.0, currentGain - trimDb)
                            self.uad.setPreampGain(chId: chId, gainDb: targetGain)
                            return "Trimmed \(chName) preamp gain down by \(Int(trimDb)) d B for 14 d B clean headroom."
                        } else {
                            let targetFaderDb = max(-144.0, ch.faderDb - trimDb)
                            let tap = UADCurve.dbToTapered(targetFaderDb)
                            self.uad.setFader(chId: chId, tapered: tap)
                            if let m = self.mcu {
                                let slot = chId - m.bankOffset
                                if slot >= 0 && slot < 8 {
                                    m.sendFaderPosition(slot: slot, normVal: tap)
                                }
                            }
                            return "Trimmed \(chName) fader down by \(Int(trimDb)) d B for 14 d B clean headroom."
                        }
                    }
                )
                findings.append(suggestion)
                continue
            }

            // Rule 2: MUTED CHANNEL WITH ACTIVE AUDIO
            if peak > -35.0 && ch.mute {
                let suggestion = AISuggestion(
                    id: "muted_signal_\(chId)",
                    channelId: chId,
                    channelName: chName,
                    issueTitle: "Muted Channel with Signal",
                    voiceDescription: "Channel \(chId + 1), \(chName), is receiving signal at \(String(format: "%.1f", peak)) d B, but is currently muted. Would you like me to unmute it?",
                    lcdBanner: "[CH \(chId + 1)] MUTED: UNMUTE TRACK? ▲YES ▼NO",
                    applyAction: { [weak self] in
                        guard let self = self else { return "" }
                        self.uad.setMute(chId: chId, mute: false)
                        return "Unmuted \(chName)."
                    }
                )
                findings.append(suggestion)
            }

            // Rule 3: LOW-END RUMBLE (Vocal / Acoustic Track without High-Pass Filter)
            let lowerName = chName.lowercased()
            let isVocalOrAcoustic = lowerName.contains("vox") || lowerName.contains("vocal") || lowerName.contains("lead") || lowerName.contains("mic") || lowerName.contains("acoust")
            if isVocalOrAcoustic && ch.preamp.hasPreamp && !ch.preamp.lowCut && peak > -55.0 {
                let suggestion = AISuggestion(
                    id: "lowcut_\(chId)",
                    channelId: chId,
                    channelName: chName,
                    issueTitle: "Low Rumble / Mud",
                    voiceDescription: "On \(chName), sub-frequency rumble can cloud the mix. Would you like me to engage the Apollo 75 Hertz low-cut filter to clean up the low end?",
                    lcdBanner: "[CH \(chId + 1)] ENGAGE 75Hz LOW-CUT? ▲YES ▼NO",
                    applyAction: { [weak self] in
                        guard let self = self else { return "" }
                        self.uad.setPreampLowCut(chId: chId, on: true)
                        return "Engaged 75 Hertz low-cut filter on \(chName)."
                    }
                )
                findings.append(suggestion)
            }

            // Rule 4: DEAD / UNCONNECTED INPUT (While session has audio)
            if maxSessionPeak > -30.0 && ch.preamp.hasPreamp && peak < -75.0 && !ch.mute {
                let suggestion = AISuggestion(
                    id: "dead_\(chId)",
                    channelId: chId,
                    channelName: chName,
                    issueTitle: "Zero Signal Detected",
                    voiceDescription: "Channel \(chId + 1), \(chName), has zero detected signal. Double-check your microphone cable and verify 48 volt phantom power if using a condenser mic.",
                    lcdBanner: "[CH \(chId + 1)] ZERO SIGNAL: CHECK CABLE / +48V",
                    applyAction: nil // Advisory only
                )
                findings.append(suggestion)
            }
        }

        lock.lock()
        suggestions = findings
        currentIndex = 0
        lock.unlock()

        // Generate and archive diagnostic report (keeps latest 10)
        AIReportManager.shared.createReport(
            uad: uad,
            peaks: recordedPeaks,
            clips: recordedClips,
            suggestions: findings
        )

        if findings.isEmpty {
            state = .completed
            mcu?.showTempHUD(text: ">>> ALL CHANNELS NOMINAL (FINE: EXIT) <<<", duration: 4.0)
            voice.speak("All channels nominal! Gain staging is clean with healthy converter headroom across your session. Press Fine to exit AI mode.")
        } else {
            state = .consulting
            let countStr = "\(findings.count) \(findings.count == 1 ? "recommendation" : "recommendations")"
            mcu?.showTempHUD(text: ">>> FOUND \(findings.count) ISSUES: ◄/► BROWSE ▲YES ▼NO (FINE: EXIT) <<<", duration: 3.5)
            voice.speak("I found \(countStr) for your session. Use Left and Right arrows to browse, Up arrow for Yes, Down arrow for No, or press Fine to exit AI mode.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) { [weak self] in
                self?.speakCurrentSuggestion()
            }
        }
    }

    // MARK: - Interactive Navigation (4-Way Arrow Cluster)

    /// Speaks and displays the currently selected suggestion.
    public func speakCurrentSuggestion() {
        guard state == .consulting, currentIndex >= 0, currentIndex < suggestions.count else { return }
        let item = suggestions[currentIndex]
        let idxBanner = "[ITEM \(currentIndex + 1)/\(suggestions.count)] " + item.lcdBanner
        mcu?.showTempHUD(text: idxBanner, duration: 4.0)

        var intro = "Suggestion \(currentIndex + 1) of \(suggestions.count): "
        if item.isApplied {
            intro += "\(item.channelName) is already applied. "
        } else if item.isSkipped {
            intro += "\(item.channelName) was skipped. "
        }
        voice.speak(intro + item.voiceDescription)
    }

    /// User pressed RIGHT ARROW (Note 99): Next suggestion.
    public func handleRightArrow() {
        guard state == .consulting else { return }
        if currentIndex < suggestions.count - 1 {
            currentIndex += 1
            speakCurrentSuggestion()
        } else {
            mcu?.showTempHUD(text: ">>> LAST SUGGESTION — ▲YES  ▼NO (FINE: EXIT) <<<", duration: 1.5)
            voice.speak("Last suggestion. Use Left arrow for previous, or press Fine to exit AI mode.")
        }
    }

    /// User pressed LEFT ARROW (Note 98): Previous suggestion / Repeat.
    public func handleLeftArrow() {
        guard state == .consulting else { return }
        if currentIndex > 0 {
            currentIndex -= 1
            speakCurrentSuggestion()
        } else {
            speakCurrentSuggestion() // Repeat first
        }
    }

    /// User pressed UP ARROW (Note 96): YES / Apply Fix.
    public func handleUpArrow() {
        if state == .completed {
            startListening()
            return
        }
        guard state == .consulting, currentIndex >= 0, currentIndex < suggestions.count else { return }
        var item = suggestions[currentIndex]
        if item.isApplied {
            voice.speak("Already applied.")
            return
        }

        if let apply = item.applyAction {
            let resultText = apply()
            item.isApplied = true
            suggestions[currentIndex] = item
            AIReportManager.shared.updateActiveReport(suggestions: suggestions)
            bridgeLog("[AI Auditor] Applied fix for \(item.channelName): \(resultText)")
            mcu?.showTempHUD(text: ">>> APPLIED: \(item.channelName.uppercased()) <<<", duration: 1.5)
            voice.speak("Applied! \(resultText)")

            // Advance automatically after 1.5s
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
                guard let self = self, self.state == .consulting else { return }
                if self.currentIndex < self.suggestions.count - 1 {
                    self.currentIndex += 1
                    self.speakCurrentSuggestion()
                } else {
                    self.finishConsultation()
                }
            }
        } else {
            voice.speak("This is an advisory item. Check your hardware connection.")
            if currentIndex < suggestions.count - 1 {
                currentIndex += 1
                speakCurrentSuggestion()
            } else {
                finishConsultation()
            }
        }
    }

    /// User pressed DOWN ARROW (Note 97): NO / Skip.
    public func handleDownArrow() {
        if state == .completed {
            exitSession()
            return
        }
        guard state == .consulting, currentIndex >= 0, currentIndex < suggestions.count else { return }
        suggestions[currentIndex].isSkipped = true
        AIReportManager.shared.updateActiveReport(suggestions: suggestions)
        voice.speak("Skipped.")
        mcu?.showTempHUD(text: ">>> SKIPPED <<<", duration: 1.0)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self, self.state == .consulting else { return }
            if self.currentIndex < self.suggestions.count - 1 {
                self.currentIndex += 1
                self.speakCurrentSuggestion()
            } else {
                self.finishConsultation()
            }
        }
    }

    private func finishConsultation() {
        state = .completed
        mcu?.showTempHUD(text: ">>> ALL SUGGESTIONS REVIEWED (FINE: EXIT) <<<", duration: 3.0)
        voice.speak("All suggestions reviewed! Press Up arrow to re-test, or press Fine to exit AI mode.")
    }
}
