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
        case armed
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

    // Telemetry recorded during the 3.5s listening window
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
    public func handleFineButton() {
        switch state {
        case .idle:
            armSession()
        case .armed:
            startListening()
        case .listening, .analyzing:
            break
        case .consulting, .completed:
            exitSession()
        }
    }

    /// First press of FINE: arms the session, welcomes user, and waits for audio to start.
    public func armSession() {
        lock.lock()
        listenTimer?.cancel()
        listenTimer = nil
        isActive = true
        state = .armed
        suggestions.removeAll()
        recordedPeaks.removeAll()
        recordedClips.removeAll()
        currentIndex = 0
        lock.unlock()

        bridgeLog("[AI Auditor] Session armed. Waiting for user to play audio and press FINE again...")
        mcu?.sendMIDI([0x90, 83, 0x7F]) // Illuminate FINE key (Note 83)
        mcu?.sendMIDI([0x90, 70, 0x7F])
        mcu?.showTempHUD(text: ">>> GEMINI AI [ALPHA]: PRESS FINE TO LISTEN <<<", duration: 4.0)
        voice.speak("AI Alpha inspector. Start playing audio, then press Fine to begin listening, or Flip to exit.")
    }

    /// Second press of FINE (or armed trigger): begins the 3.5s listening accumulation window.
    public func startListening() {
        lock.lock()
        guard isActive else {
            lock.unlock()
            armSession()
            return
        }
        state = .listening
        recordedPeaks.removeAll()
        recordedClips.removeAll()
        lock.unlock()

        bridgeLog("[AI Auditor] Starting listening session across 32 channels...")
        mcu?.sendMIDI([0x90, 83, 0x7F])
        mcu?.sendMIDI([0x90, 70, 0x7F])
        mcu?.showTempHUD(text: ">>> GEMINI AI [ALPHA]: LISTENING 32 CHS (3s) <<<", duration: 3.5)
        voice.speak("Listening across 32 channels...")

        // Start 3.5-second listening accumulation window
        listenTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 3.5)
        timer.setEventHandler { [weak self] in
            self?.finishListeningAndAnalyze()
        }
        listenTimer = timer
        timer.resume()
    }

    /// Starts or restarts the AI Studio session.
    public func startSession() {
        armSession()
    }

    /// Exits the AI session cleanly and returns surface to Main Mix.
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
        mcu?.showTempHUD(text: ">>> EXITED AI STUDIO [ALPHA] <<<", duration: 1.2)
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

        for ch in allChannels {
            let chId = ch.id
            let chName = ch.name
            let peak = recordedPeaks[chId] ?? ch.meterPeak
            let clipped = (recordedClips[chId] == true) || ch.meterClip || peak >= -0.1

            // Rule 1: DIGITAL OVERLOAD / CLIPPING (Sound-Critical)
            if clipped {
                let currentGain = ch.preamp.gain
                let isPreamp = ch.preamp.hasPreamp
                let suggestion = AISuggestion(
                    id: "clip_\(chId)",
                    channelId: chId,
                    channelName: chName,
                    issueTitle: "Clipping / Overload",
                    voiceDescription: "Channel \(chId + 1), \(chName), is clipping into the red at \(String(format: "%.1f", peak)) d B. Would you like me to auto-trim gain down by 4 d B for clean converter headroom?",
                    lcdBanner: "[CH \(chId + 1)] CLIP: AUTO-TRIM GAIN (-4 dB)? ▲YES ▼NO",
                    applyAction: { [weak self] in
                        guard let self = self else { return "" }
                        if isPreamp {
                            let targetGain = max(10.0, currentGain - 4.0)
                            self.uad.setPreampGain(chId: chId, gainDb: targetGain)
                            return "Trimmed \(chName) preamp gain down by 4 d B to \(Int(targetGain)) d B."
                        } else {
                            let targetFaderDb = max(-144.0, ch.faderDb - 4.0)
                            let tap = UADCurve.dbToTapered(targetFaderDb)
                            self.uad.setFader(chId: chId, tapered: tap)
                            return "Trimmed \(chName) fader down by 4 d B."
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

        if findings.isEmpty {
            state = .completed
            mcu?.showTempHUD(text: ">>> ALL CHANNELS NOMINAL — READY TO RECORD <<<", duration: 3.0)
            voice.speak("All channels nominal! Gain staging is clean with healthy converter headroom across your session. You're ready to start recording.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                self?.exitSession()
            }
        } else {
            state = .consulting
            let countStr = "\(findings.count) \(findings.count == 1 ? "recommendation" : "recommendations")"
            mcu?.showTempHUD(text: ">>> FOUND \(findings.count) ISSUES: ◄/► BROWSE  ▲YES  ▼NO <<<", duration: 2.5)
            voice.speak("I found \(countStr) for your session. Use Left and Right arrows to browse, Up arrow for Yes, Down arrow for No.")
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
            mcu?.showTempHUD(text: ">>> LAST SUGGESTION — ▲YES  ▼NO  ◄PREV <<<", duration: 1.5)
            voice.speak("Last suggestion. Use Left arrow for previous, or press Fine key to finish.")
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
        if state == .armed {
            startListening()
            return
        }
        if state == .completed {
            armSession()
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
        if state == .armed || state == .completed {
            exitSession()
            return
        }
        guard state == .consulting, currentIndex >= 0, currentIndex < suggestions.count else { return }
        suggestions[currentIndex].isSkipped = true
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
        mcu?.showTempHUD(text: ">>> ALL SUGGESTIONS REVIEWED — READY! <<<", duration: 3.0)
        voice.speak("All suggestions reviewed! Press Up arrow to re-test, or Fine key to start mixing.")
    }
}
