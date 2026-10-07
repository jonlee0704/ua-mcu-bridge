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

/// Manages generation, storage, local export, and emailing of AI Co-Producer diagnostic reports.
/// Retains the latest 10 reports on disk and provides an accessible macOS viewer window.
public final class AIReportManager {
    public static let shared = AIReportManager()

    public let reportsDir: URL
    private let maxReportsToKeep = 10
    public private(set) var activeReportURL: URL?

    private var windowController: AIReportsWindowController?

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        reportsDir = appSupport.appendingPathComponent("UA-MCU Bridge/AI_Reports", isDirectory: true)
        try? FileManager.default.createDirectory(at: reportsDir, withIntermediateDirectories: true)
    }

    // MARK: - Report Generation & Storage

    private static func padRight(_ text: String, _ width: Int) -> String {
        if text.count >= width {
            return String(text.prefix(width))
        }
        return text + String(repeating: " ", count: width - text.count)
    }

    /// Generates a comprehensive plain-text diagnostic report and saves it to disk.
    @discardableResult
    public func createReport(
        uad: UADClient,
        peaks: [Int: Double],
        clips: [Int: Bool],
        suggestions: [AISuggestion]
    ) -> URL? {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestampStr = formatter.string(from: now)

        let fileFormatter = DateFormatter()
        fileFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let filename = "AI_Report_\(fileFormatter.string(from: now)).txt"
        let fileURL = reportsDir.appendingPathComponent(filename)

        let allChannels = uad.channels.values.sorted(by: { $0.id < $1.id })
        let activeChannels = allChannels.filter { (peaks[$0.id] ?? $0.meterPeak) > -50.0 }
        var maxPeak: Double = -144.0
        var maxPeakChannel: String = "None"
        for ch in allChannels {
            let pk = peaks[ch.id] ?? ch.meterPeak
            if pk > maxPeak {
                maxPeak = pk
                maxPeakChannel = "Ch \(ch.id + 1) [\(ch.name)]"
            }
        }

        var report = ""
        report += "================================================================================\n"
        report += "  UA-MCU BRIDGE - AI STUDIO CO-PRODUCER ANALYSIS REPORT [ALPHA]\n"
        report += "================================================================================\n"
        report += "Timestamp:         \(timestampStr)\n"
        report += "Hardware Surface:  Solid State Logic UF8 (8 Motorized Faders)\n"
        report += "Audio Interface:   Universal Audio Apollo Console (32 Channels)\n"
        report += "Engine Status:     Connected | Master Monitor: \(String(format: "%.1f", uad.monitorLevelDb)) dB (Mute=\(uad.monitorMute))\n\n"

        report += "--------------------------------------------------------------------------------\n"
        report += "1. SESSION ACOUSTIC SUMMARY\n"
        report += "--------------------------------------------------------------------------------\n"
        report += "• Total Channels Monitored:   \(allChannels.count)\n"
        report += "• Active Channels Detected:   \(activeChannels.count) tracks (> -50.0 dBFS)\n"
        report += "• Maximum Session Peak:       \(String(format: "%.1f", maxPeak)) dBFS (\(maxPeakChannel))\n"
        report += "• Master Headroom Margin:     \(String(format: "%.1f", max(0.0, -maxPeak))) dB\n\n"

        report += "--------------------------------------------------------------------------------\n"
        report += "2. AI CO-PRODUCER FINDINGS & RECOMMENDATIONS (\(suggestions.count) Items)\n"
        report += "--------------------------------------------------------------------------------\n"
        if suggestions.isEmpty {
            report += "✔ All channels nominal. Gain staging is clean with healthy converter headroom.\n"
        } else {
            for (idx, item) in suggestions.enumerated() {
                let statusStr = item.isApplied ? "[APPLIED]" : (item.isSkipped ? "[SKIPPED]" : "[PENDING]")
                report += "[\(idx + 1)] \(statusStr) \(item.issueTitle)\n"
                report += "    Target:       \(item.channelId >= 0 ? "Channel \(item.channelId + 1) (\(item.channelName))" : "Master / Session Wide")\n"
                report += "    Diagnosis:    \(item.voiceDescription)\n"
                report += "    Hardware HUD: \(item.lcdBanner)\n\n"
            }
        }

        report += "--------------------------------------------------------------------------------\n"
        report += "3. DETAILED 32-CHANNEL TELEMETRY\n"
        report += "--------------------------------------------------------------------------------\n"
        report += AIReportManager.padRight("CH", 6) + " " +
                  AIReportManager.padRight("TRACK NAME", 16) + " " +
                  AIReportManager.padRight("PEAK LEVEL", 12) + " " +
                  AIReportManager.padRight("FADER dB", 12) + " " +
                  AIReportManager.padRight("MUTE/SOLO", 10) + " " +
                  AIReportManager.padRight("PREAMP/STATUS", 14) + "\n"
        report += "--------------------------------------------------------------------------------\n"

        for ch in allChannels {
            let pk = peaks[ch.id] ?? ch.meterPeak
            let clip = (clips[ch.id] == true) || ch.meterClip
            let pkStr = String(format: "%+5.1f dB", pk) + (clip ? " [CLIP]" : "")
            let faderStr = (ch.faderDb <= -140.0) ? "-oo dB" : String(format: "%+5.1f dB", ch.faderDb)
            let muteSolo = ch.mute ? "MUTED" : (ch.solo ? "SOLO" : "--")
            var preStr = "--"
            if ch.preamp.hasPreamp {
                preStr = String(format: "Pre %2.0fdB", ch.preamp.gain) + (ch.preamp.phase ? " [Ø]" : "")
            } else if ch.chType == "aux" {
                preStr = "AUX"
            }

            let chLabel = String(format: "Ch %02d", ch.id + 1)
            let row = AIReportManager.padRight(chLabel, 6) + " " +
                      AIReportManager.padRight(String(ch.name.prefix(16)), 16) + " " +
                      AIReportManager.padRight(pkStr, 12) + " " +
                      AIReportManager.padRight(faderStr, 12) + " " +
                      AIReportManager.padRight(muteSolo, 10) + " " +
                      AIReportManager.padRight(preStr, 14) + "\n"
            report += row
        }

        report += "\n================================================================================\n"
        report += "Generated by UA-MCU Bridge Native Swift Engine.\n"
        report += "S&D A11y Studio | Accessibility & Audio Technology (jonlee0704@gmail.com)\n"
        report += "================================================================================\n"

        do {
            try report.write(to: fileURL, atomically: true, encoding: .utf8)
            activeReportURL = fileURL
            bridgeLog("[AI Report] Diagnostic report saved to: \(fileURL.lastPathComponent)")
            pruneOldReports()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Notification.Name("AIReportsDidChange"), object: nil)
            }
            return fileURL
        } catch {
            bridgeLog("[AI Report] Failed to write report: \(error.localizedDescription)")
            return nil
        }
    }

    /// Updates the existing active report with updated application statuses.
    public func updateActiveReport(suggestions: [AISuggestion]) {
        guard let url = activeReportURL,
              let content = try? String(contentsOf: url, encoding: .utf8) else { return }

        // Regenerate findings section
        var newContent = content
        for item in suggestions {
            if item.isApplied {
                newContent = newContent.replacingOccurrences(of: "[PENDING] \(item.issueTitle)", with: "[APPLIED] \(item.issueTitle)")
                newContent = newContent.replacingOccurrences(of: "[SKIPPED] \(item.issueTitle)", with: "[APPLIED] \(item.issueTitle)")
            } else if item.isSkipped {
                newContent = newContent.replacingOccurrences(of: "[PENDING] \(item.issueTitle)", with: "[SKIPPED] \(item.issueTitle)")
            }
        }
        try? newContent.write(to: url, atomically: true, encoding: .utf8)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Notification.Name("AIReportsDidChange"), object: nil)
        }
    }

    /// Prunes reports so that only the latest 10 files are kept.
    private func pruneOldReports() {
        let reports = listReports()
        if reports.count > maxReportsToKeep {
            let toRemove = reports.suffix(reports.count - maxReportsToKeep)
            for file in toRemove {
                try? FileManager.default.removeItem(at: file)
                bridgeLog("[AI Report] Pruned old report: \(file.lastPathComponent)")
            }
        }
    }

    /// Returns all saved reports sorted newest first.
    public func listReports() -> [URL] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: reportsDir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return []
        }
        return files
            .filter { $0.pathExtension == "txt" }
            .sorted { (u1, u2) -> Bool in
                let d1 = (try? u1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
                let d2 = (try? u2.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
                return d1 > d2
            }
    }

    public func latestReport() -> URL? {
        return listReports().first
    }

    // MARK: - User Export & Sharing Actions

    /// Displays the built-in accessible AI Reports viewer window.
    public func showReportsWindow() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.windowController == nil {
                self.windowController = AIReportsWindowController(manager: self)
            }
            self.windowController?.showWindow(nil)
            self.windowController?.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Allows user to save a report file to an arbitrary local destination via NSSavePanel.
    public func saveReportLocally(url: URL, parentWindow: NSWindow? = nil) {
        DispatchQueue.main.async {
            let panel = NSSavePanel()
            panel.title = "Save AI Co-Producer Report"
            panel.prompt = "Save"
            panel.nameFieldStringValue = url.lastPathComponent
            panel.allowedFileTypes = ["txt", "md"]
            panel.canCreateDirectories = true

            let handler: (NSApplication.ModalResponse) -> Void = { response in
                if response == .OK, let target = panel.url {
                    do {
                        if FileManager.default.fileExists(atPath: target.path) {
                            try FileManager.default.removeItem(at: target)
                        }
                        try FileManager.default.copyItem(at: url, to: target)
                        bridgeLog("[AI Report] Exported report to \(target.path)")
                    } catch {
                        bridgeLog("[AI Report] Export error: \(error.localizedDescription)")
                    }
                }
            }

            if let win = parentWindow {
                panel.beginSheetModal(for: win, completionHandler: handler)
            } else {
                panel.begin(completionHandler: handler)
            }
        }
    }

    /// Opens default macOS mail client with the report contents embedded in the email body.
    public func emailReport(url: URL) {
        DispatchQueue.main.async {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
            let subject = "UA-MCU Bridge - AI Co-Producer Report (\(url.lastPathComponent))"

            // Construct mailto link
            var components = URLComponents()
            components.scheme = "mailto"
            components.path = ""
            components.queryItems = [
                URLQueryItem(name: "subject", value: subject),
                URLQueryItem(name: "body", value: content)
            ]

            if let mailURL = components.url {
                NSWorkspace.shared.open(mailURL)
                bridgeLog("[AI Report] Opened mail client for report \(url.lastPathComponent)")
            }
        }
    }

    /// Reveals the reports directory in Finder.
    public func revealInFinder() {
        NSWorkspace.shared.selectFile(latestReport()?.path, inFileViewerRootedAtPath: reportsDir.path)
    }
}

// MARK: - Accessible AI Reports Window UI

final class AIReportsWindowController: NSWindowController, NSWindowDelegate {
    private let manager: AIReportManager
    private var popUpButton: NSPopUpButton!
    private var textView: NSTextView!

    init(manager: AIReportManager) {
        self.manager = manager

        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 750, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AI Co-Producer Analysis Reports [ALPHA]"
        window.minSize = NSSize(width: 550, height: 400)
        super.init(window: window)
        window.delegate = self
        setupUI()
        NotificationCenter.default.addObserver(self, selector: #selector(handleReportsChangedNotification), name: Notification.Name("AIReportsDidChange"), object: nil)
    }

    @objc private func handleReportsChangedNotification() {
        DispatchQueue.main.async { [weak self] in
            self?.reloadReportList()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let win = window else { return }
        let root = NSView(frame: win.contentView!.bounds)
        root.autoresizingMask = [.width, .height]
        win.contentView = root

        // Top Toolbar Header
        let topBar = NSView(frame: NSRect(x: 0, y: root.bounds.height - 52, width: root.bounds.width, height: 52))
        topBar.autoresizingMask = [.width, .minYMargin]
        root.addSubview(topBar)

        let label = NSTextField(labelWithString: "Saved Report (Last 10):")
        label.frame = NSRect(x: 16, y: 16, width: 170, height: 20)
        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        topBar.addSubview(label)

        popUpButton = NSPopUpButton(frame: NSRect(x: 190, y: 12, width: 340, height: 26), pullsDown: false)
        popUpButton.target = self
        popUpButton.action = #selector(handleSelectReport(_:))
        topBar.addSubview(popUpButton)

        let refreshBtn = NSButton(title: "↻", target: self, action: #selector(handleRefreshList))
        refreshBtn.frame = NSRect(x: 536, y: 14, width: 36, height: 24)
        refreshBtn.bezelStyle = .rounded
        topBar.addSubview(refreshBtn)

        // Middle Text Editor Area
        let scroll = NSScrollView(frame: NSRect(x: 16, y: 56, width: root.bounds.width - 32, height: root.bounds.height - 116))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder

        textView = NSTextView(frame: scroll.bounds)
        textView.autoresizingMask = [.width, .height]
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.backgroundColor = NSColor.textBackgroundColor
        scroll.documentView = textView
        root.addSubview(scroll)

        // Bottom Action Bar
        let bottomBar = NSView(frame: NSRect(x: 0, y: 0, width: root.bounds.width, height: 50))
        bottomBar.autoresizingMask = [.width, .maxYMargin]
        root.addSubview(bottomBar)

        let saveBtn = NSButton(title: "Save Report Locally...", target: self, action: #selector(handleSaveLocally))
        saveBtn.frame = NSRect(x: 16, y: 12, width: 170, height: 28)
        saveBtn.bezelStyle = .rounded
        bottomBar.addSubview(saveBtn)

        let emailBtn = NSButton(title: "Email Report...", target: self, action: #selector(handleEmailReport))
        emailBtn.frame = NSRect(x: 194, y: 12, width: 140, height: 28)
        emailBtn.bezelStyle = .rounded
        bottomBar.addSubview(emailBtn)

        let revealBtn = NSButton(title: "Reveal in Finder", target: self, action: #selector(handleRevealFinder))
        revealBtn.frame = NSRect(x: 342, y: 12, width: 140, height: 28)
        revealBtn.bezelStyle = .rounded
        bottomBar.addSubview(revealBtn)

        let closeBtn = NSButton(title: "Close", target: self, action: #selector(handleClose))
        closeBtn.frame = NSRect(x: root.bounds.width - 106, y: 12, width: 90, height: 28)
        closeBtn.autoresizingMask = [.minXMargin]
        closeBtn.bezelStyle = .rounded
        closeBtn.keyEquivalent = "\u{1b}" // ESC to close
        bottomBar.addSubview(closeBtn)

        reloadReportList()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        reloadReportList()
    }

    @objc private func handleRefreshList() {
        reloadReportList()
    }

    private func reloadReportList() {
        popUpButton.removeAllItems()
        let reports = manager.listReports()
        if reports.isEmpty {
            popUpButton.addItem(withTitle: "No reports generated yet")
            textView.string = "No AI Co-Producer diagnostic reports found.\n\nTo generate an analysis report:\n1. Press the FINE button on your SSL UF8 controller to arm.\n2. Start audio playback in your DAW.\n3. Press FINE a second time (or UP arrow) to listen for 3.5 seconds across all 32 channels.\n4. A detailed report will automatically appear here!"
            return
        }

        for (idx, url) in reports.enumerated() {
            let item = NSMenuItem(title: "[\(idx + 1)] \(url.lastPathComponent)", action: nil, keyEquivalent: "")
            item.representedObject = url
            popUpButton.menu?.addItem(item)
        }

        if let first = reports.first {
            loadReport(url: first)
        }
    }

    @objc private func handleSelectReport(_ sender: NSPopUpButton) {
        guard let url = sender.selectedItem?.representedObject as? URL else { return }
        loadReport(url: url)
    }

    private func loadReport(url: URL) {
        if let content = try? String(contentsOf: url, encoding: .utf8) {
            textView.string = content
        } else {
            textView.string = "Failed to load report from \(url.path)"
        }
    }

    private func currentSelectedURL() -> URL? {
        return popUpButton.selectedItem?.representedObject as? URL ?? manager.latestReport()
    }

    @objc private func handleSaveLocally() {
        guard let url = currentSelectedURL() else { return }
        manager.saveReportLocally(url: url, parentWindow: window)
    }

    @objc private func handleEmailReport() {
        guard let url = currentSelectedURL() else { return }
        manager.emailReport(url: url)
    }

    @objc private func handleRevealFinder() {
        manager.revealInFinder()
    }

    @objc private func handleClose() {
        window?.close()
    }
}
