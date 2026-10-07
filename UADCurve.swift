import Foundation

/// Mathematical curves, string formatters, and abbreviation dictionaries for Apollo faders, pans, and plug-in parameters.
public enum UADCurve {

    // Exact Universal Audio Apollo Console fader calibration curve breakpoints: (tapered, dB)
    private static let breakpoints: [(tapered: Double, db: Double)] = [
        (0.000000000, -144.0),
        (0.050088988,  -86.0),
        (0.151783903,  -56.0),
        (0.306622612,  -32.0),
        (0.471328495,  -18.0),
        (0.563636364,  -12.0),
        (1.000000000,   12.0)
    ]

    /// Convert normalized fader level (0.0 to 1.0) to decibels (-144.0 to +12.0 dB).
    public static func taperedToDb(_ tapered: Double) -> Double {
        if tapered <= 0.0 { return -144.0 }
        if tapered >= 1.0 { return 12.0 }

        for i in 0..<(breakpoints.count - 1) {
            let p0 = breakpoints[i]
            let p1 = breakpoints[i + 1]
            if tapered >= p0.tapered && tapered <= p1.tapered {
                let frac = (tapered - p0.tapered) / (p1.tapered - p0.tapered)
                return p0.db + frac * (p1.db - p0.db)
            }
        }
        return -144.0
    }

    /// Convert decibels (-144.0 to +12.0 dB) to normalized fader level (0.0 to 1.0).
    public static func dbToTapered(_ db: Double) -> Double {
        if db <= -144.0 { return 0.0 }
        if db >= 12.0 { return 1.0 }

        for i in 0..<(breakpoints.count - 1) {
            let p0 = breakpoints[i]
            let p1 = breakpoints[i + 1]
            if db >= p0.db && db <= p1.db {
                let frac = (db - p0.db) / (p1.db - p0.db)
                return p0.tapered + frac * (p1.tapered - p0.tapered)
            }
        }
        return 0.0
    }

    /// Format dB value into a clean 7-character string for MCU scribble strips.
    public static func formatDb7Char(_ db: Double) -> String {
        if db <= -140.0 {
            return " -oo dB"
        }
        if abs(db) < 0.05 {
            return "  0.0dB"
        }
        if db > 0 {
            let str = String(format: "+%.1fdB", db)
            return String(format: "%7s", (str as NSString).utf8String!)
        } else if db <= -99.95 {
            let str = String(format: "%.0fdB", round(db))
            return String(format: "%7s", (str as NSString).utf8String!)
        } else {
            let str = String(format: "%.1fdB", db)
            return String(format: "%7s", (str as NSString).utf8String!)
        }
    }

    /// Format peak input dB value into a clean 7-character string for MCU scribble strips.
    public static func formatMeterPeak7Char(_ db: Double) -> String {
        if db <= -70.0 {
            return " -oo PK"
        }
        if db >= 0.0 {
            return " CLIP! "
        }
        if db <= -99.95 {
            let str = String(format: "%.0f PK", round(db))
            return String(format: "%7s", (str as NSString).utf8String!)
        }
        let str = String(format: "%.1fPK", db)
        return String(format: "%7s", (str as NSString).utf8String!)
    }

    /// Format dB float to natural speech for blind audio engineers.
    public static func formatDbSpeech(_ db: Double) -> String {
        if db <= -140.0 {
            return "minus infinity d B"
        }
        if abs(db) < 0.1 {
            return "zero d B"
        }
        if db > 0 {
            return String(format: "plus %.1f d B", db)
        }
        return String(format: "%.1f d B", db)
    }

    /// Format dB into an exact 4-character string: e.g. ' 0.0', '-6.0', ' -12', ' -oo'.
    public static func formatCompactDb(_ db: Double) -> String {
        if db <= -140.0 {
            return " -oo"
        }
        if abs(db) < 0.05 {
            return " 0.0"
        }
        if db > 0 {
            if db < 9.95 {
                return String(format: "+%.1f", db)
            }
            return String(format: "%4.0f", round(db))
        }
        if db <= -99.95 {
            return String(format: "%4.0f", round(db))
        }
        if db > -9.95 {
            return String(format: "%.1f", db)
        }
        return String(format: "%4.0f", round(db))
    }

    // Apollo Console meter tick marks:
    // [-oo, -60, -46, -36, -27, -21, -18, -15, -12, -9, -6, -3, 0 dB]
    private static let meterTicks: [(threshold: Double, seg: UInt8)] = [
        (-60.0, 0x01),  // -60 dB
        (-46.0, 0x02),  // -46 dB
        (-36.0, 0x03),  // -36 dB
        (-27.0, 0x04),  // -27 dB
        (-21.0, 0x05),  // -21 dB
        (-18.0, 0x06),  // -18 dB
        (-15.0, 0x07),  // -15 dB
        (-12.0, 0x08),  // -12 dB
        (-9.0,  0x09),  // -9 dB
        (-6.0,  0x0A),  // -6 dB
        (-3.0,  0x0B),  // -3 dB
        (-0.2,  0x0C),  // 0 dB
    ]

    /// Map Apollo audio dBFS to MCU 4-bit meter nibble matching Apollo Console meter ticks:
    /// -oo (0x0), -60, -46, -36, -27, -21, -18, -15, -12, -9, -6, -3, 0 dB (0xC), CLIP (0xE)
    public static func dbToMcuMeter(db: Double, isClip: Bool = false) -> UInt8 {
        if isClip || db >= 0.0 {
            return 0x0E
        }
        if db <= -60.0 {
            return 0x00
        }
        for (threshold, seg) in meterTicks.reversed() {
            if db >= threshold {
                return seg
            }
        }
        return 0x01
    }

    /// Format peak meter dBFS into speech (e.g. "peak minus 12.4 d B F S" or "no input signal")
    public static func formatPeakMeterSpeech(_ db: Double) -> String {
        if db <= -65.0 {
            return "no input signal"
        }
        return "Peak \(formatDbSpeech(db)) F S"
    }

    /// Format pan value (-1.0 to 1.0) into a 7-character string.
    public static func panToStr(_ pan: Double, stereo: Bool = false) -> String {
        if abs(pan) < 0.05 {
            return "   C   "
        }
        let pct = Int(round(abs(pan) * 100))
        if pan < 0 {
            let s = " L\(pct)"
            return String(format: "%-7s", (s as NSString).utf8String!)
        } else {
            let s = " R\(pct)"
            return String(format: "%-7s", (s as NSString).utf8String!)
        }
    }

    /// Format pan value (-1.0 to 1.0) into natural speech.
    public static func formatPanSpeech(_ pan: Double) -> String {
        if abs(pan) < 0.05 {
            return "center"
        }
        let pct = Int(round(abs(pan) * 100))
        let side = pan < 0 ? "left" : "right"
        return "\(side) \(pct) percent"
    }

    /// Format pan information for speech, handling mono and stereo tracks accurately.
    public static func formatChannelPanSpeech(pan: Double, pan2: Double = 0.0, stereo: Bool = false) -> String {
        if stereo {
            let bal = (pan + pan2) / 2.0
            if abs(bal) < 0.03 {
                return "stereo center"
            }
            let side = bal < 0 ? "left" : "right"
            let pct = Int(round(abs(bal) * 100))
            return "\(side) \(pct) percent"
        }
        return formatPanSpeech(pan)
    }

    /// Format channel name into a clean, unambiguous 7-character string.
    public static func formatChannelName7Char(_ name: String) -> String {
        var s = name.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return "       " }
        if s.count <= 7 { return s }

        // Remove redundant prefixes
        for prefix in ["ANALOG ", "MIC/LINE ", "LINE ", "ADAT ", "VIRTUAL ", "SP-DIF "] {
            if s.hasPrefix(prefix) {
                s = String(s.dropFirst(prefix.count))
                break
            }
        }
        if s.count <= 7 { return s }

        // Stereo suffix preservation
        var isStereo = false
        if s.hasSuffix("-ST") {
            isStereo = true
            s = String(s.dropLast(3))
        }

        let replacements = [
            ("Apollo", "Apo"),
            ("OctoPre", "Octo"),
            ("Channel", "Ch"),
            ("Return", "Ret"),
            ("Monitor", "Mon"),
            ("Playback", "Play"),
            ("Master", "Mst"),
            ("Virtual", "Vrt")
        ]
        for (full, abbr) in replacements {
            s = s.replacingOccurrences(of: full, with: abbr)
        }

        if isStereo {
            if s.count + 2 <= 7 {
                return "\(s)ST"
            }
            return "\(s.prefix(5))ST"
        }
        return String(s.prefix(7))
    }

    /// Format plug-in parameter name into a clean 7-character string.
    public static func formatParamName7Char(_ name: String) -> String {
        var s = name.trimmingCharacters(in: .whitespaces)
        if s.count <= 7 { return s }

        let replacements = [
            ("Frequency", "Freq"),
            ("Threshold", "Thresh"),
            ("Select", "Sel"),
            ("Attack", "Atk"),
            ("Release", "Rel"),
            ("Reduction", "Red"),
            ("Output", "Out"),
            ("Input", "In"),
            ("Gain", "Gn"),
            ("Level", "Lvl"),
            ("Ratio", "Rat")
        ]
        for (full, abbr) in replacements {
            s = s.replacingOccurrences(of: full, with: abbr)
            if s.count <= 7 { return s }
        }
        let noSpace = s.replacingOccurrences(of: " ", with: "")
        if noSpace.count <= 7 { return noSpace }
        return String(noSpace.prefix(7))
    }

    /// Format cleaned plug-in name into an unambiguous 7-character string for MCU LCD.
    public static func formatPluginName7Char(_ rawName: String) -> String {
        var s = rawName.trimmingCharacters(in: .whitespaces)
        for prefix in ["Universal Audio ", "UAD ", "Teletronix ", "UA "] {
            if s.hasPrefix(prefix) {
                s = String(s.dropFirst(prefix.count))
            }
        }
        s = s.replacingOccurrences(of: " Legacy", with: "")
             .replacingOccurrences(of: " Classic", with: "")
             .replacingOccurrences(of: " Channel Strip", with: "")
             .trimmingCharacters(in: .whitespaces)

        if s.count <= 7 { return s }

        let replacements = [
            ("Pure Plate", "PurePlt"),
            ("Fairchild", "Fairchd"),
            ("Precision", "Precisn"),
            ("Compressor", "Comp"),
            ("Limiter", "Limit"),
            ("Equalizer", "EQ"),
            ("Pultec", "Pultec"),
            ("Helios", "Helios")
        ]
        for (full, abbr) in replacements {
            s = s.replacingOccurrences(of: full, with: abbr)
            if s.count <= 7 { return s }
        }
        let noSpace = s.replacingOccurrences(of: " ", with: "")
        if noSpace.count <= 7 { return noSpace }
        return String(noSpace.prefix(7))
    }

    /// Format plug-in name for natural, clear spoken feedback (announces full name and model).
    public static func formatPluginNameFullSpeech(_ rawName: String) -> String {
        var s = rawName.trimmingCharacters(in: .whitespaces)
        if s.isEmpty || s.lowercased() == "none" {
            return "Empty"
        }
        for prefix in ["Universal Audio ", "UAD "] {
            if s.hasPrefix(prefix) {
                s = String(s.dropFirst(prefix.count))
            }
        }
        s = s.replacingOccurrences(of: " Legacy", with: "")
             .trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "Empty" : s
    }

    /// Format plug-in parameter setting for spoken feedback.
    public static func formatParamSettingSpeech(paramName: String, strVal: String) -> String {
        let pName = paramName.trimmingCharacters(in: .whitespaces)
        let sVal = strVal.trimmingCharacters(in: .whitespaces)
        if sVal.isEmpty {
            return pName
        }

        var spokenVal = sVal
        // Ratio: e.g. "4:1" -> "4 to 1"
        if spokenVal.contains(":") {
            let parts = spokenVal.components(separatedBy: ":")
            if parts.count == 2 {
                let r1 = parts[0].trimmingCharacters(in: .whitespaces)
                let r2 = parts[1].trimmingCharacters(in: .whitespaces)
                spokenVal = "\(r1) to \(r2)"
            }
        } else if spokenVal.lowercased() == "all" || spokenVal.lowercased() == "all buttons" {
            spokenVal = "All buttons in"
        }
        // Frequencies: kHz -> kiloHertz, Hz -> Hertz
        if spokenVal.localizedCaseInsensitiveContains("kHz") {
            spokenVal = spokenVal.replacingOccurrences(of: "kHz", with: " kiloHertz", options: .caseInsensitive)
        } else if spokenVal.localizedCaseInsensitiveContains("Hz") {
            spokenVal = spokenVal.replacingOccurrences(of: "Hz", with: " Hertz", options: .caseInsensitive)
        }

        return "\(pName), \(spokenVal)"
    }

    /// Format sound-critical parameter readout when SEL is pressed in Plugin Mode.
    public static func formatSoundCriticalParamSpeech(slotLabel: String, pluginName: String, param: UADEffectParam, power: Bool) -> String {
        let pClean = formatPluginNameFullSpeech(pluginName)
        let pName = param.name.trimmingCharacters(in: .whitespaces)
        let sVal = param.strVal.trimmingCharacters(in: .whitespaces)
        let pLower = pName.lowercased()
        let valLower = sVal.lowercased()

        // Section categorization based on sonic function
        var section = ""
        if pLower.contains("eq") || pLower.contains("filter") || pLower.contains("freq") || pLower.contains("low cut") || pLower.contains("hi cut") || pLower.contains("treble") || pLower.contains("bass") || pLower.contains("mid") {
            section = "EQ section"
        } else if pLower.contains("attack") || pLower.contains("release") || pLower.contains("ratio") || pLower.contains("thresh") || pLower.contains("comp") || pLower.contains("limit") || pLower.contains("peak red") || pLower.contains("makeup") {
            section = "Dynamics section"
        } else if pLower.contains("delay") || pLower.contains("decay") || pLower.contains("feedback") || pLower.contains("reverb") || pLower.contains("room") || pLower.contains("mix") {
            section = "Time and Space section"
        } else if pLower.contains("gain") || pLower.contains("input") || pLower.contains("pad") || pLower.contains("phase") || pLower.contains("source") {
            section = "Preamp section"
        } else if pLower.contains("output") || pLower.contains("level") || pLower.contains("master") {
            section = "Output section"
        }

        var speechVal = sVal
        if speechVal.contains(":") {
            let parts = speechVal.components(separatedBy: ":")
            if parts.count == 2 {
                let num = parts[0].trimmingCharacters(in: .whitespaces)
                speechVal = "\(num) to 1"
                if num == "2" || num == "3" || num == "4" {
                    speechVal += ", moderate compression"
                } else if num == "8" || num == "12" {
                    speechVal += ", heavy compression"
                } else if num == "20" {
                    speechVal += ", limiting"
                }
            }
        } else if valLower == "all" || valLower == "all buttons" {
            speechVal = "All buttons in, aggressive overdrive limiting"
        } else if valLower.contains("db") || (sVal.hasPrefix("-") || sVal.hasPrefix("+")) {
            if let num = Double(sVal.replacingOccurrences(of: "dB", with: "").replacingOccurrences(of: "db", with: "").trimmingCharacters(in: .whitespaces)) {
                if num < 0 {
                    speechVal = String(format: "minus %.1f d B", abs(num))
                } else if num > 0 {
                    speechVal = String(format: "plus %.1f d B", num)
                } else {
                    speechVal = "zero d B, unity gain"
                }
            }
        }

        let secText = section.isEmpty ? "" : ", \(section)"
        let bypWarning = !power ? ", Warning: plug-in is bypassed" : ""
        return "\(slotLabel): \(pClean)\(secText): \(pName), \(speechVal)\(bypWarning)"
    }
}
