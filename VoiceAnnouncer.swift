import Foundation
import AVFoundation

/// Non-blocking, interruptible speech announcer for blind and screenless audio operation.
/// Uses Apple's native AVSpeechSynthesizer with zero-latency in-process execution.
public final class VoiceAnnouncer: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    public static let shared = VoiceAnnouncer()

    private let synthesizer = AVSpeechSynthesizer()
    private var debounceTimer: DispatchSourceTimer?

    public var isEnabled: Bool = true
    public var volume: Float = 1.0 // 0.0 to 1.0

    // Speech rate corresponding to ~210 words per minute (AVSpeechUtterance rate 0.0 to 1.0)
    public var speechRate: Float = 0.52

    override public init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Sanitize text for clear phonetics and accessibility speech.
    public func sanitizeForSpeech(_ text: String) -> String {
        var s = text
        // Ensure 'dB' is spoken as 'd B'
        if let regex = try? NSRegularExpression(pattern: "(\\d|\\b)dB\\b", options: .caseInsensitive) {
            s = regex.stringByReplacingMatches(in: s, options: [], range: NSRange(location: 0, length: s.utf16.count), withTemplate: "$1 d B")
        }
        // Stereo track indicators
        if let regex = try? NSRegularExpression(pattern: "[-_/]ST\\b", options: .caseInsensitive) {
            s = regex.stringByReplacingMatches(in: s, options: [], range: NSRange(location: 0, length: s.utf16.count), withTemplate: " Stereo")
        }
        if let regex = try? NSRegularExpression(pattern: "\\bST\\b", options: []) {
            s = regex.stringByReplacingMatches(in: s, options: [], range: NSRange(location: 0, length: s.utf16.count), withTemplate: "Stereo")
        }
        // Audio Hardware Phonetics & Pronunciations
        let phoneticReplacements: [(String, String)] = [
            ("\\b1176\\s*LN\\b", "Eleven-Seventy-Six L N"),
            ("\\b1176\\s*SE\\b", "Eleven-Seventy-Six S E"),
            ("\\b1176\\b", "Eleven-Seventy-Six"),
            ("\\bLA-?2A\\b", "L A 2 A"),
            ("\\bLA-?3A\\b", "L A 3 A"),
            ("\\b610-?A\\b", "Six-Ten A"),
            ("\\b610-?B\\b", "Six-Ten B"),
            ("\\b1073\\b", "Ten-Seventy-Three"),
            ("\\b1084\\b", "Ten-Eighty-Four"),
            ("\\b1081\\b", "Ten-Eighty-One"),
            ("\\b670\\b", "Six-Seventy"),
            ("\\b660\\b", "Six-Sixty"),
            ("\\bEQP-?1A\\b", "E Q P One A"),
            ("\\bMEQ-?5\\b", "M E Q Five"),
            ("\\bRev\\.?\\s*([A-Za-z])\\b", "Revision $1"),
            ("\\bGR\\b", "Gain Reduction")
        ]
        for (pattern, template) in phoneticReplacements {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                s = regex.stringByReplacingMatches(in: s, options: [], range: NSRange(location: 0, length: s.utf16.count), withTemplate: template)
            }
        }

        // Collapse whitespace
        let components = s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        return components.joined(separator: " ")
    }

    /// Speak text immediately with optional interruption of previous speech.
    public func speak(_ text: String, interrupt: Bool = true) {
        guard isEnabled, volume > 0.001, !text.isEmpty else { return }

        let cleanText = sanitizeForSpeech(text)
        guard !cleanText.isEmpty else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.cancelDebounceTimer()

            if interrupt && self.synthesizer.isSpeaking {
                self.synthesizer.stopSpeaking(at: .immediate)
            }

            let utterance = AVSpeechUtterance(string: cleanText)
            utterance.rate = self.speechRate
            utterance.volume = self.volume
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")

            self.synthesizer.speak(utterance)
        }
    }

    /// Debounced speech for rapid fader moves and rotary encoder rotations.
    public func speakDebounced(_ text: String, delay: TimeInterval = 0.25) {
        guard isEnabled, volume > 0.001, !text.isEmpty else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.cancelDebounceTimer()

            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + delay)
            timer.setEventHandler { [weak self] in
                self?.speak(text, interrupt: true)
            }
            self.debounceTimer = timer
            timer.resume()
        }
    }

    private func cancelDebounceTimer() {
        if let timer = debounceTimer {
            timer.cancel()
            debounceTimer = nil
        }
    }
}
