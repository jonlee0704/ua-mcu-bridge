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
import Cocoa
import CoreMIDI
import Network
import AVFoundation

// MARK: - Configuration Model

struct BridgeConfig: Codable {
    var port: Int = 9
    var wheelMode: String = "monitor"
    var speechFeedback: Bool = true
    var speechVolume: Float = 0.5
    var speechRate: Float = 0.52
    var sendLabels: [String] = ["AUX 1", "AUX 2", "HP 1", "HP 2", "CUE 3", "CUE 4", "OUTPUT", "PAN"]

    enum CodingKeys: String, CodingKey {
        case port = "port"
        case wheelMode = "wheel_mode"
        case speechFeedback = "speech_feedback"
        case speechVolume = "speech_volume"
        case speechRate = "speech_rate"
        case sendLabels = "send_labels"
    }
}

final class ConfigManager {
    static let shared = ConfigManager()
    private let fileURL: URL

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        fileURL = home.appendingPathComponent(".uamcu_config.json")
    }

    func load() -> BridgeConfig {
        var config = BridgeConfig()
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(BridgeConfig.self, from: data) {
            config = decoded
        } else {
            // Check UserDefaults fallback
            if let savedPort = UserDefaults.standard.value(forKey: "UAMCUPort") as? Int {
                config.port = savedPort
            }
            if let savedWheel = UserDefaults.standard.string(forKey: "UAMCUWheelMode") {
                config.wheelMode = savedWheel
            }
            if let savedSpeech = UserDefaults.standard.value(forKey: "UAMCUSpeechFeedback") as? Bool {
                config.speechFeedback = savedSpeech
            }
            if let savedVol = UserDefaults.standard.value(forKey: "UAMCUSpeechVolume") as? Float {
                config.speechVolume = savedVol
            }
            if let savedRate = UserDefaults.standard.value(forKey: "UAMCUSpeechRate") as? Float {
                config.speechRate = savedRate
            }
            if let savedLabels = UserDefaults.standard.stringArray(forKey: "UAMCUSendLabels"), !savedLabels.isEmpty {
                config.sendLabels = savedLabels
            }
        }
        let defaultSendLabels = ["AUX 1", "AUX 2", "HP 1", "HP 2", "CUE 3", "CUE 4", "OUTPUT", "PAN"]
        if config.sendLabels.count < 8 {
            for i in config.sendLabels.count..<8 {
                config.sendLabels.append(defaultSendLabels[i])
            }
        }
        return config
    }

    func save(_ config: BridgeConfig) {
        // Save to file
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(config) {
            try? data.write(to: fileURL)
        }
        // Save to UserDefaults
        UserDefaults.standard.set(config.port, forKey: "UAMCUPort")
        UserDefaults.standard.set(config.wheelMode, forKey: "UAMCUWheelMode")
        UserDefaults.standard.set(config.speechFeedback, forKey: "UAMCUSpeechFeedback")
        UserDefaults.standard.set(config.speechVolume, forKey: "UAMCUSpeechVolume")
        UserDefaults.standard.set(config.speechRate, forKey: "UAMCUSpeechRate")
        UserDefaults.standard.set(config.sendLabels, forKey: "UAMCUSendLabels")
    }
}

// MARK: - Application Logger

final class AppLogger {
    static let shared = AppLogger()
    let logFileURL: URL
    private var fileHandle: FileHandle?

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let logsDir = home.appendingPathComponent("Library/Logs")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        logFileURL = logsDir.appendingPathComponent("UAMCUBridge.log")

        // Truncate if larger than 10MB to avoid ballooning disk space
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
           let size = attrs[.size] as? UInt64, size > 10_000_000 {
            try? FileManager.default.removeItem(at: logFileURL)
        }
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: logFileURL)
        fileHandle?.seekToEndOfFile()
        log("=== UA-MCU Bridge Native Swift Session Started ===")
    }

    func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        NSLog("%@", message)
        if let data = line.data(using: .utf8), let handle = try? FileHandle(forWritingTo: logFileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }
    }

    func openLog() {
        NSWorkspace.shared.open(logFileURL)
    }
}

public func bridgeLog(_ message: String) {
    AppLogger.shared.log(message)
}

// MARK: - Application Delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!

    private var config: BridgeConfig = BridgeConfig()
    private var uadClient: UADClient!
    private var midiAdapter: CoreMIDIAdapter!
    private var mcuEngine: MCUEngine!

    private var monitorTimer: Timer?
    private var uadStatusMenuItem: NSMenuItem?
    private var midiStatusMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Load configuration
        config = ConfigManager.shared.load()

        // Configure Voice Announcer
        VoiceAnnouncer.shared.isEnabled = config.speechFeedback
        VoiceAnnouncer.shared.volume = config.speechVolume
        VoiceAnnouncer.shared.speechRate = config.speechRate

        // Setup Status Bar Item
        setupStatusBar()

        // Initialize Core Systems
        setupBridgeSystems()

        // Start Periodic Connection Health Monitor
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            self?.checkConnections()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        cleanupHardware()
    }

    // MARK: - Bridge Setup

    private func setupBridgeSystems() {
        bridgeLog("[Bridge] Initializing pure native Swift UA-MCU Bridge...")

        // 1. Initialize UAD Client
        uadClient = UADClient(host: "127.0.0.1", port: 4710)

        // 2. Initialize CoreMIDI Adapter
        midiAdapter = CoreMIDIAdapter()

        // 3. Initialize MCU Engine
        mcuEngine = MCUEngine(uadClient: uadClient, sendMIDIFn: { [weak self] bytes in
            self?.midiAdapter.sendMIDI(bytes)
        }, voice: VoiceAnnouncer.shared)
        mcuEngine.wheelMode = config.wheelMode
        mcuEngine.sendLabels = config.sendLabels

        // 4. Connect MIDI Port
        connectMIDIPort(config.port)

        // 5. Connect UAD Client
        connectUAD()
    }

    private func connectMIDIPort(_ portNumber: Int) {
        config.port = portNumber
        ConfigManager.shared.save(config)

        let success = midiAdapter.connect(portNumber: portNumber) { [weak self] bytes in
            self?.mcuEngine.handleMidiBytes(bytes)
        }

        if success {
            bridgeLog("[Bridge] CoreMIDI connected to SSL V-MIDI Port \(portNumber)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.mcuEngine.refreshAllSlots()
            }
        } else {
            bridgeLog("[Bridge] Failed to connect to SSL V-MIDI Port \(portNumber)")
        }
        updateMenuStatus()
    }

    private func connectUAD() {
        uadClient.connect { [weak self] connected in
            DispatchQueue.main.async {
                if connected {
                    bridgeLog("[Bridge] UA Mixer Engine connected successfully")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self?.mcuEngine.refreshAllSlots()
                    }
                } else {
                    bridgeLog("[Bridge] Waiting for UA Mixer Engine at 127.0.0.1:4710...")
                }
                self?.updateMenuStatus()
            }
        }
    }

    private func checkConnections() {
        // Check UAD connection
        if !uadClient.isConnected {
            bridgeLog("[Bridge] UAD disconnected, attempting automatic reconnect...")
            connectUAD()
        }

        // Check MIDI connection
        if !midiAdapter.isConnected {
            bridgeLog("[Bridge] MIDI disconnected, attempting automatic reconnect...")
            connectMIDIPort(config.port)
        }

        updateMenuStatus()
    }

    private func cleanupHardware() {
        bridgeLog("[Bridge] Cleaning up hardware and disconnecting...")
        // Reset UF8 Mute/Solo LEDs and Scribble Strips
        for s in 0..<8 {
            midiAdapter.sendMIDI([0x90, UInt8(16 + s), 0x00]) // Mute off
            midiAdapter.sendMIDI([0x90, UInt8(8 + s), 0x00])  // Solo off
            midiAdapter.sendMIDI([0x90, UInt8(0 + s), 0x00])  // Rec Ready off
            midiAdapter.sendMIDI([0x90, UInt8(24 + s), 0x00]) // Sel off
        }
        mcuEngine.sendLcdText(row: 1, text: " ")
        mcuEngine.sendLcdText(row: 2, text: " ")

        midiAdapter.close()
        uadClient.disconnect()
    }

    // MARK: - Status Bar UI

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "slider.vertical.3", accessibilityDescription: "UA-MCU Bridge") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "UA-MCU"
            }
            button.toolTip = "UA-MCU Bridge (SSL UF8 <-> UAD Apollo)"
        }

        menu = NSMenu()
        menu.delegate = self
        buildMenu()
        statusItem.menu = menu

        NotificationCenter.default.addObserver(self, selector: #selector(handleReportsChangedNotification), name: Notification.Name("AIReportsDidChange"), object: nil)
    }

    private func buildMenu() {
        menu.removeAllItems()

        // 1. Title Header
        let titleItem = NSMenuItem(title: "UA-MCU Bridge 1.0 (Native Swift)", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        let subtitleItem = NSMenuItem(title: "SSL UF8 ↔ UAD Apollo Console", action: nil, keyEquivalent: "")
        subtitleItem.isEnabled = false
        menu.addItem(subtitleItem)

        menu.addItem(NSMenuItem.separator())

        // 2. Connection Status Items
        let uadStatus = NSMenuItem(title: "Apollo Console: Checking...", action: nil, keyEquivalent: "")
        uadStatus.isEnabled = false
        menu.addItem(uadStatus)
        self.uadStatusMenuItem = uadStatus

        let midiStatus = NSMenuItem(title: "CoreMIDI: Checking...", action: nil, keyEquivalent: "")
        midiStatus.isEnabled = false
        menu.addItem(midiStatus)
        self.midiStatusMenuItem = midiStatus

        menu.addItem(NSMenuItem.separator())

        // 3. Port Selector Submenu
        let portMenu = NSMenu(title: "MIDI Port")
        for p in 1...16 {
            var label = "SSL V-MIDI Port \(p)"
            if p == 9 { label += " (DAW 3 - Recommended)" }
            else if p == 1 { label += " (DAW 1)" }
            else if p == 5 { label += " (DAW 2)" }

            let item = NSMenuItem(title: label, action: #selector(handleSelectPort(_:)), keyEquivalent: "")
            item.tag = p
            item.target = self
            item.state = (p == config.port) ? .on : .off
            portMenu.addItem(item)
        }
        let portParentItem = NSMenuItem(title: "MIDI Port (SSL 360°)", action: nil, keyEquivalent: "")
        portParentItem.submenu = portMenu
        menu.addItem(portParentItem)

        // 4. Channel Wheel Mode Submenu
        let wheelMenu = NSMenu(title: "Wheel Mode")
        let monItem = NSMenuItem(title: "Apollo Master Monitor Volume (Dedicated)", action: #selector(handleWheelMode(_:)), keyEquivalent: "")
        monItem.tag = 1
        monItem.target = self
        monItem.state = .on
        wheelMenu.addItem(monItem)

        let wheelParentItem = NSMenuItem(title: "Channel Wheel Mode", action: nil, keyEquivalent: "")
        wheelParentItem.submenu = wheelMenu
        menu.addItem(wheelParentItem)

        // 5. CUE & SENDS Display Labels Submenu
        let sendLabelMenu = NSMenu(title: "CUE / SENDS Display Labels")

        let editAllItem = NSMenuItem(title: "Edit All CUE / SENDS Labels...", action: #selector(handleEditAllSendLabels(_:)), keyEquivalent: "")
        editAllItem.target = self
        sendLabelMenu.addItem(editAllItem)
        sendLabelMenu.addItem(NSMenuItem.separator())

        let slotNames = ["Aux 1 (A1)", "Aux 2 (A2)", "Cue 1 (C1)", "Cue 2 (C2)", "Cue 3 (C3)", "Cue 4 (C4)", "Output (OUT)", "Pan (PAN)"]
        for s in 0..<slotNames.count {
            let currentName = (s < config.sendLabels.count) ? config.sendLabels[s] : ""
            let item = NSMenuItem(title: "\(slotNames[s]): \"\(currentName)\"...", action: #selector(handleEditSingleSendLabel(_:)), keyEquivalent: "")
            item.tag = s
            item.target = self
            sendLabelMenu.addItem(item)
        }

        sendLabelMenu.addItem(NSMenuItem.separator())

        // Presets Submenu
        let presetsMenu = NSMenu(title: "Presets")
        let p1 = NSMenuItem(title: "Default (AUX 1, AUX 2, HP 1, HP 2, CUE 3, CUE 4)", action: #selector(handleApplySendLabelPreset(_:)), keyEquivalent: "")
        p1.tag = 1
        p1.target = self
        presetsMenu.addItem(p1)

        let p2 = NSMenuItem(title: "Studio Monitor & Rig (AUX 1, AUX 2, Monitor, PosGrid, CUE 3, CUE 4)", action: #selector(handleApplySendLabelPreset(_:)), keyEquivalent: "")
        p2.tag = 2
        p2.target = self
        presetsMenu.addItem(p2)

        let p3 = NSMenuItem(title: "Headphone & QSB (AUX 1, AUX 2, HP1, QSB, CUE 3, CUE 4)", action: #selector(handleApplySendLabelPreset(_:)), keyEquivalent: "")
        p3.tag = 3
        p3.target = self
        presetsMenu.addItem(p3)

        let p4 = NSMenuItem(title: "Live IEM & FX (Reverb, Delay, Vox IEM, Band IEM, CUE 3, CUE 4)", action: #selector(handleApplySendLabelPreset(_:)), keyEquivalent: "")
        p4.tag = 4
        p4.target = self
        presetsMenu.addItem(p4)

        let presetsParent = NSMenuItem(title: "Label Presets", action: nil, keyEquivalent: "")
        presetsParent.submenu = presetsMenu
        sendLabelMenu.addItem(presetsParent)

        sendLabelMenu.addItem(NSMenuItem.separator())

        let resetLabelsItem = NSMenuItem(title: "Reset Labels to Defaults", action: #selector(handleResetSendLabels(_:)), keyEquivalent: "")
        resetLabelsItem.target = self
        sendLabelMenu.addItem(resetLabelsItem)

        let sendLabelParentItem = NSMenuItem(title: "CUE / SENDS Display Labels", action: nil, keyEquivalent: "")
        sendLabelParentItem.submenu = sendLabelMenu
        menu.addItem(sendLabelParentItem)

        // 5. Voice Guidance Submenu
        let voiceMenu = NSMenu(title: "Voice Guidance")
        let toggleVoiceItem = NSMenuItem(title: "Speech Feedback (Talkback)", action: #selector(handleToggleVoice(_:)), keyEquivalent: "")
        toggleVoiceItem.target = self
        toggleVoiceItem.state = config.speechFeedback ? .on : .off
        voiceMenu.addItem(toggleVoiceItem)
        voiceMenu.addItem(NSMenuItem.separator())

        // Speech Speed Submenu
        let speedMenu = NSMenu(title: "Voiceover Speed")
        let speedLevels: [(String, Float)] = [
            ("0.5x (Slow)", 0.40),
            ("0.75x (Relaxed)", 0.46),
            ("1.0x (Normal - Default)", 0.52),
            ("1.25x (Brisk)", 0.57),
            ("1.5x (Fast)", 0.62),
            ("1.75x (Very Fast)", 0.67),
            ("2.0x (Pro Speed)", 0.72)
        ]
        for (sTitle, sVal) in speedLevels {
            let item = NSMenuItem(title: sTitle, action: #selector(handleSelectVoiceSpeed(_:)), keyEquivalent: "")
            item.representedObject = sVal
            item.target = self
            let isCurrent = abs(config.speechRate - sVal) < 0.025
            item.state = (config.speechFeedback && isCurrent) ? .on : .off
            speedMenu.addItem(item)
        }
        let currentSpeedTitle = speedLevels.first(where: { abs(config.speechRate - $0.1) < 0.025 })?.0.components(separatedBy: " ").first ?? "1.0x"
        let speedParentItem = NSMenuItem(title: "Voiceover Speed (\(currentSpeedTitle))", action: nil, keyEquivalent: "")
        speedParentItem.submenu = speedMenu
        voiceMenu.addItem(speedParentItem)

        // Speech Volume Submenu
        let volMenu = NSMenu(title: "Voice Volume")
        let volLevels: [(String, Float)] = [
            ("100% (Maximum)", 1.0),
            ("75%", 0.75),
            ("50% (Default)", 0.5),
            ("25%", 0.25),
            ("0% (Turn Off)", 0.0)
        ]
        for (vTitle, vVal) in volLevels {
            let item = NSMenuItem(title: vTitle, action: #selector(handleSelectVoiceVolume(_:)), keyEquivalent: "")
            item.representedObject = vVal
            item.target = self
            let isCurrent = abs(config.speechVolume - vVal) < 0.05
            item.state = (config.speechFeedback && isCurrent) ? .on : .off
            volMenu.addItem(item)
        }
        let volParentItem = NSMenuItem(title: "Voice Volume (\(Int(round(config.speechVolume * 100)))%)", action: nil, keyEquivalent: "")
        volParentItem.submenu = volMenu
        voiceMenu.addItem(volParentItem)

        let voiceParentItem = NSMenuItem(title: "Voice Guidance (Talkback)", action: nil, keyEquivalent: "")
        voiceParentItem.submenu = voiceMenu
        menu.addItem(voiceParentItem)

        menu.addItem(NSMenuItem.separator())

        // 6. AI Co-Producer Reports [ALPHA]
        let aiReportParent = NSMenuItem(title: "AI Co-Producer Reports [ALPHA]", action: nil, keyEquivalent: "")
        let aiReportMenu = NSMenu(title: "AI Co-Producer Reports")

        let openReportsWindowItem = NSMenuItem(title: "Open AI Reports Window...", action: #selector(handleOpenAIReportsWindow(_:)), keyEquivalent: "")
        openReportsWindowItem.target = self
        aiReportMenu.addItem(openReportsWindowItem)

        let saveLatestItem = NSMenuItem(title: "Save Latest Report Locally...", action: #selector(handleSaveLatestReport(_:)), keyEquivalent: "")
        saveLatestItem.target = self
        aiReportMenu.addItem(saveLatestItem)

        let emailLatestItem = NSMenuItem(title: "Email Latest Report...", action: #selector(handleEmailLatestReport(_:)), keyEquivalent: "")
        emailLatestItem.target = self
        aiReportMenu.addItem(emailLatestItem)

        aiReportMenu.addItem(NSMenuItem.separator())

        // Submenu listing recent reports (up to 10)
        let recentMenu = NSMenu(title: "Recent Reports")
        let reports = AIReportManager.shared.listReports()
        if reports.isEmpty {
            let emptyItem = NSMenuItem(title: "No reports generated yet", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            recentMenu.addItem(emptyItem)
        } else {
            for (idx, rUrl) in reports.prefix(10).enumerated() {
                let rItem = NSMenuItem(title: "[\(idx + 1)] \(rUrl.lastPathComponent)", action: #selector(handleOpenSpecificReport(_:)), keyEquivalent: "")
                rItem.representedObject = rUrl
                rItem.target = self
                recentMenu.addItem(rItem)
            }
        }
        let recentParent = NSMenuItem(title: "Recent Reports (\(reports.count) Saved)", action: nil, keyEquivalent: "")
        recentParent.submenu = recentMenu
        aiReportMenu.addItem(recentParent)

        let revealFolderItem = NSMenuItem(title: "Reveal Reports Folder in Finder", action: #selector(handleRevealReportsFolder(_:)), keyEquivalent: "")
        revealFolderItem.target = self
        aiReportMenu.addItem(revealFolderItem)

        aiReportParent.submenu = aiReportMenu
        menu.addItem(aiReportParent)

        menu.addItem(NSMenuItem.separator())

        // 7. Maintenance & Diagnostics
        let refreshItem = NSMenuItem(title: "Refresh Hardware Surface", action: #selector(handleRefreshSurface(_:)), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let reconnectItem = NSMenuItem(title: "Reconnect All Connections", action: #selector(handleReconnect(_:)), keyEquivalent: "")
        reconnectItem.target = self
        menu.addItem(reconnectItem)

        let revealItem = NSMenuItem(title: "Reveal App in Finder...", action: #selector(handleRevealInFinder(_:)), keyEquivalent: "")
        revealItem.target = self
        menu.addItem(revealItem)

        let openLogItem = NSMenuItem(title: "Open Log File...", action: #selector(handleOpenLogFile(_:)), keyEquivalent: "")
        openLogItem.target = self
        menu.addItem(openLogItem)

        menu.addItem(NSMenuItem.separator())

        // 8. Quit
        let quitItem = NSMenuItem(title: "Quit UA-MCU Bridge", action: #selector(handleQuit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        updateMenuStatus()
    }

    private func updateMenuStatus() {
        if let uItem = uadStatusMenuItem {
            if uadClient != nil && uadClient.isConnected {
                let chCount = uadClient.channels.count
                uItem.title = "● Apollo Console: Online (\(chCount) channels)"
            } else {
                uItem.title = "○ Apollo Console: Connecting..."
            }
        }

        if let mItem = midiStatusMenuItem {
            if midiAdapter != nil && midiAdapter.isConnected {
                mItem.title = "● SSL UF8: Connected (Port \(config.port))"
            } else {
                mItem.title = "○ SSL UF8: Disconnected (Port \(config.port))"
            }
        }
    }

    // MARK: - Actions

    @objc private func handleSelectPort(_ sender: NSMenuItem) {
        let newPort = sender.tag
        connectMIDIPort(newPort)
        buildMenu()
        VoiceAnnouncer.shared.speak("Switched to SSL Port \(newPort)")
    }

    @objc private func handleWheelMode(_ sender: NSMenuItem) {
        config.wheelMode = "monitor"
        mcuEngine.wheelMode = "monitor"
        VoiceAnnouncer.shared.speak("Wheel locked to Monitor Volume")
        ConfigManager.shared.save(config)
        buildMenu()
    }

    // MARK: - CUE & SENDS Label Editor Actions

    @objc private func handleEditAllSendLabels(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Edit All CUE / SENDS Display Labels"
        alert.informativeText = "Customize scribble strip titles for Row 1 in CUE/SENDS mode.\nValue numbers and dB readouts will display on Row 2."
        alert.addButton(withTitle: "Save Labels")
        alert.addButton(withTitle: "Cancel")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 260))
        var textFields: [NSTextField] = []
        let slotNames = [
            ("Aux 1 (A1):", (config.sendLabels.count > 0) ? config.sendLabels[0] : "AUX 1"),
            ("Aux 2 (A2):", (config.sendLabels.count > 1) ? config.sendLabels[1] : "AUX 2"),
            ("Cue 1 (C1):", (config.sendLabels.count > 2) ? config.sendLabels[2] : "HP 1"),
            ("Cue 2 (C2):", (config.sendLabels.count > 3) ? config.sendLabels[3] : "HP 2"),
            ("Cue 3 (C3):", (config.sendLabels.count > 4) ? config.sendLabels[4] : "CUE 3"),
            ("Cue 4 (C4):", (config.sendLabels.count > 5) ? config.sendLabels[5] : "CUE 4"),
            ("Output (OUT):", (config.sendLabels.count > 6) ? config.sendLabels[6] : "OUTPUT"),
            ("Pan (PAN):", (config.sendLabels.count > 7) ? config.sendLabels[7] : "PAN")
        ]

        let rowHeight: CGFloat = 30
        for (i, item) in slotNames.enumerated() {
            let y = CGFloat(slotNames.count - 1 - i) * rowHeight + 8
            let label = NSTextField(labelWithString: item.0)
            label.frame = NSRect(x: 0, y: y + 2, width: 110, height: 20)
            label.alignment = .right
            label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            container.addSubview(label)

            let input = NSTextField(frame: NSRect(x: 120, y: y, width: 200, height: 24))
            input.stringValue = item.1
            input.font = NSFont.systemFont(ofSize: 13)
            container.addSubview(input)
            textFields.append(input)
        }

        alert.accessoryView = container
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            for (i, tf) in textFields.enumerated() {
                let trimmed = tf.stringValue.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty && i < config.sendLabels.count {
                    config.sendLabels[i] = trimmed
                }
            }
            ConfigManager.shared.save(config)
            mcuEngine.sendLabels = config.sendLabels
            buildMenu()
            VoiceAnnouncer.shared.speak("All Cue labels saved")
        }
    }

    @objc private func handleEditSingleSendLabel(_ sender: NSMenuItem) {
        let slot = sender.tag
        guard slot >= 0 && slot < config.sendLabels.count else { return }
        let slotNames = ["Aux 1 (A1)", "Aux 2 (A2)", "Cue 1 (C1)", "Cue 2 (C2)", "Cue 3 (C3)", "Cue 4 (C4)", "Output (OUT)", "Pan (PAN)"]
        let slotTitle = (slot < slotNames.count) ? slotNames[slot] : "Slot \(slot + 1)"

        let alert = NSAlert()
        alert.messageText = "Edit Label for \(slotTitle)"
        alert.informativeText = "Enter a title for \(slotTitle) (up to 7 characters, e.g. HP 1, Monitor, QSB, PosGrid):\nThis text appears on Row 1 in CUE/SENDS mode, with values on Row 2."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.stringValue = config.sendLabels[slot]
        input.font = NSFont.systemFont(ofSize: 13)
        alert.accessoryView = input

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let trimmed = input.stringValue.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                config.sendLabels[slot] = trimmed
                ConfigManager.shared.save(config)
                mcuEngine.sendLabels = config.sendLabels
                buildMenu()
                VoiceAnnouncer.shared.speak("\(slotTitle) renamed to \(trimmed)")
            }
        }
    }

    @objc private func handleApplySendLabelPreset(_ sender: NSMenuItem) {
        switch sender.tag {
        case 1:
            config.sendLabels = ["AUX 1", "AUX 2", "HP 1", "HP 2", "CUE 3", "CUE 4", "OUTPUT", "PAN"]
            VoiceAnnouncer.shared.speak("Default Cue labels applied")
        case 2:
            config.sendLabels = ["AUX 1", "AUX 2", "Monitor", "PosGrid", "CUE 3", "CUE 4", "OUTPUT", "PAN"]
            VoiceAnnouncer.shared.speak("Monitor and Rig labels applied")
        case 3:
            config.sendLabels = ["AUX 1", "AUX 2", "HP1", "QSB", "CUE 3", "CUE 4", "OUTPUT", "PAN"]
            VoiceAnnouncer.shared.speak("Headphone and QSB labels applied")
        case 4:
            config.sendLabels = ["Reverb", "Delay", "Vox IEM", "Band IEM", "CUE 3", "CUE 4", "OUTPUT", "PAN"]
            VoiceAnnouncer.shared.speak("Live IEM labels applied")
        default:
            break
        }
        ConfigManager.shared.save(config)
        mcuEngine.sendLabels = config.sendLabels
        buildMenu()
    }

    @objc private func handleResetSendLabels(_ sender: Any?) {
        config.sendLabels = ["AUX 1", "AUX 2", "HP 1", "HP 2", "CUE 3", "CUE 4", "OUTPUT", "PAN"]
        ConfigManager.shared.save(config)
        mcuEngine.sendLabels = config.sendLabels
        buildMenu()
        VoiceAnnouncer.shared.speak("Cue labels reset to defaults")
    }

    @objc private func handleToggleVoice(_ sender: NSMenuItem) {
        config.speechFeedback.toggle()
        VoiceAnnouncer.shared.isEnabled = config.speechFeedback
        ConfigManager.shared.save(config)
        buildMenu()
        if config.speechFeedback {
            VoiceAnnouncer.shared.speak("Voice guidance enabled")
        }
    }

    @objc private func handleSelectVoiceVolume(_ sender: NSMenuItem) {
        if let vol = sender.representedObject as? Float {
            config.speechVolume = vol
            if vol <= 0.001 {
                config.speechFeedback = false
                VoiceAnnouncer.shared.isEnabled = false
            } else {
                config.speechFeedback = true
                VoiceAnnouncer.shared.isEnabled = true
                VoiceAnnouncer.shared.volume = vol
            }
            ConfigManager.shared.save(config)
            buildMenu()
            VoiceAnnouncer.shared.speak("Volume set to \(Int(vol * 100)) percent")
        }
    }

    @objc private func handleSelectVoiceSpeed(_ sender: NSMenuItem) {
        if let rate = sender.representedObject as? Float {
            config.speechRate = rate
            VoiceAnnouncer.shared.speechRate = rate
            ConfigManager.shared.save(config)
            buildMenu()
            let title = sender.title.components(separatedBy: " (").first ?? sender.title
            VoiceAnnouncer.shared.speak("Voiceover speed set to \(title)")
        }
    }

    @objc private func handleRefreshSurface(_ sender: NSMenuItem) {
        mcuEngine.refreshAllSlots()
        VoiceAnnouncer.shared.speak("Hardware surface refreshed")
    }

    @objc private func handleReconnect(_ sender: NSMenuItem) {
        VoiceAnnouncer.shared.speak("Reconnecting bridge")
        uadClient.disconnect()
        midiAdapter.close()
        connectMIDIPort(config.port)
        connectUAD()
    }

    @objc private func handleRevealInFinder(_ sender: NSMenuItem) {
        let appURL = Bundle.main.bundleURL
        NSWorkspace.shared.activateFileViewerSelecting([appURL])
    }

    @objc private func handleOpenLogFile(_ sender: NSMenuItem) {
        AppLogger.shared.openLog()
    }

    // MARK: - AI Reports Action Handlers

    @objc private func handleOpenAIReportsWindow(_ sender: NSMenuItem) {
        AIReportManager.shared.showReportsWindow()
    }

    @objc private func handleSaveLatestReport(_ sender: NSMenuItem) {
        if let latest = AIReportManager.shared.latestReport() {
            AIReportManager.shared.saveReportLocally(url: latest)
        } else {
            AIReportManager.shared.showReportsWindow()
        }
    }

    @objc private func handleEmailLatestReport(_ sender: NSMenuItem) {
        if let latest = AIReportManager.shared.latestReport() {
            AIReportManager.shared.emailReport(url: latest)
        } else {
            AIReportManager.shared.showReportsWindow()
        }
    }

    @objc private func handleOpenSpecificReport(_ sender: NSMenuItem) {
        AIReportManager.shared.showReportsWindow()
    }

    @objc private func handleRevealReportsFolder(_ sender: NSMenuItem) {
        AIReportManager.shared.revealInFinder()
    }

    @objc private func handleQuit(_ sender: NSMenuItem) {
        cleanupHardware()
        NSApplication.shared.terminate(nil)
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        buildMenu()
    }

    @objc private func handleReportsChangedNotification() {
        DispatchQueue.main.async { [weak self] in
            self?.buildMenu()
        }
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // Menu bar only app, no dock icon
app.run()
