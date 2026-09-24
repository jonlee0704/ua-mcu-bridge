import Cocoa
import Foundation

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var menu: NSMenu!
    
    var bridgeProcess: Process?
    var logPipe: Pipe?
    let logFileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/UAMCUBridge.log")
    
    var currentPort: Int = 9
    var isRunning: Bool = false
    var currentWheelMode: String = "channel"
    let configFileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".uamcu_config.json")
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Read saved port or default to 9
        let savedPort = UserDefaults.standard.integer(forKey: "UAMCUBridgePort")
        if savedPort > 0 {
            currentPort = savedPort
        }
        readWheelMode()
        
        setupStatusBar()
        startBridge()
    }
    
    func readWheelMode() {
        if let data = try? Data(contentsOf: configFileURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let mode = json["wheel_mode"] as? String {
            currentWheelMode = mode
        } else {
            let saved = UserDefaults.standard.string(forKey: "UAMCUWheelMode") ?? "channel"
            currentWheelMode = saved
        }
    }
    
    func writeWheelMode(_ mode: String) {
        currentWheelMode = mode
        UserDefaults.standard.set(mode, forKey: "UAMCUWheelMode")
        let dict = ["wheel_mode": mode]
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted) {
            try? data.write(to: configFileURL)
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        stopBridgeSync()
    }
    
    // MARK: - Status Bar Setup
    func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            // Use SF Symbol slider.vertical.3 or fallback to custom drawn faders
            if let sfSymbol = NSImage(systemSymbolName: "slider.vertical.3", accessibilityDescription: "UA-MCU Bridge") {
                sfSymbol.isTemplate = true
                button.image = sfSymbol
            } else {
                button.image = drawFaderIcon()
            }
            button.toolTip = "Tactile Hardware Accessibility Bridge for UAD Apollo using SSL UF8"
        }
        
        menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        buildMenu()
    }
    
    func drawFaderIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath()
            // 3 vertical fader lines
            path.move(to: NSPoint(x: 4, y: 2))
            path.line(to: NSPoint(x: 4, y: 16))
            path.move(to: NSPoint(x: 9, y: 2))
            path.line(to: NSPoint(x: 9, y: 16))
            path.move(to: NSPoint(x: 14, y: 2))
            path.line(to: NSPoint(x: 14, y: 16))
            path.lineWidth = 1.5
            NSColor.black.setStroke()
            path.stroke()
            
            // Fader caps
            let cap1 = NSRect(x: 2, y: 10, width: 4, height: 3)
            let cap2 = NSRect(x: 7, y: 5, width: 4, height: 3)
            let cap3 = NSRect(x: 12, y: 12, width: 4, height: 3)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: cap1, xRadius: 1, yRadius: 1).fill()
            NSBezierPath(roundedRect: cap2, xRadius: 1, yRadius: 1).fill()
            NSBezierPath(roundedRect: cap3, xRadius: 1, yRadius: 1).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
    
    // MARK: - Menu Construction
    func buildMenu() {
        menu.removeAllItems()
        
        // Title
        let titleItem = NSMenuItem(title: "Tactile Accessibility Bridge", action: nil, keyEquivalent: "")
        titleItem.attributedTitle = NSAttributedString(
            string: "Tactile Accessibility Bridge",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]
        )
        menu.addItem(titleItem)
        
        // Status indicator
        let statusString = isRunning ? "● Running (Port \(currentPort))" : "○ Stopped"
        let statusItem = NSMenuItem(title: statusString, action: nil, keyEquivalent: "")
        let color = isRunning ? NSColor.systemGreen : NSColor.systemRed
        statusItem.attributedTitle = NSAttributedString(
            string: statusString,
            attributes: [.foregroundColor: color, .font: NSFont.systemFont(ofSize: 12)]
        )
        menu.addItem(statusItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Toggle Start / Stop
        if isRunning {
            let stopItem = NSMenuItem(title: "Stop Bridge", action: #selector(toggleBridgeAction), keyEquivalent: "s")
            stopItem.target = self
            menu.addItem(stopItem)
            
            let restartItem = NSMenuItem(title: "Restart Bridge", action: #selector(restartBridgeAction), keyEquivalent: "r")
            restartItem.target = self
            menu.addItem(restartItem)
        } else {
            let startItem = NSMenuItem(title: "Start Bridge", action: #selector(toggleBridgeAction), keyEquivalent: "s")
            startItem.target = self
            menu.addItem(startItem)
        }
        
        menu.addItem(NSMenuItem.separator())
        
        // Port Selection Submenu
        let portMenu = NSMenu()
        let ports = [
            (9, "Port 9 (SSL 360 DAW 3 - Recommended)"),
            (1, "Port 1 (SSL 360 DAW 1)"),
            (2, "Port 2"),
            (3, "Port 3"),
            (4, "Port 4"),
            (5, "Port 5 (SSL 360 DAW 2)"),
            (6, "Port 6"),
            (7, "Port 7"),
            (8, "Port 8"),
            (10, "Port 10"),
            (11, "Port 11"),
            (12, "Port 12")
        ]
        
        for (portNum, label) in ports {
            let item = NSMenuItem(title: label, action: #selector(selectPortAction(_:)), keyEquivalent: "")
            item.target = self
            item.tag = portNum
            if portNum == currentPort {
                item.state = .on
            }
            portMenu.addItem(item)
        }
        
        let portParentItem = NSMenuItem(title: "MIDI Port: SSL V-MIDI Port \(currentPort)", action: nil, keyEquivalent: "")
        portParentItem.submenu = portMenu
        menu.addItem(portParentItem)
        
        // Channel Wheel Mode Submenu
        readWheelMode()
        let wheelMenu = NSMenu()
        let channelItem = NSMenuItem(title: "Option 1: Track Navigation (1-Track Step)", action: #selector(selectWheelModeAction(_:)), keyEquivalent: "")
        channelItem.target = self
        channelItem.representedObject = "channel"
        if currentWheelMode == "channel" { channelItem.state = .on }
        wheelMenu.addItem(channelItem)
        
        let monitorItem = NSMenuItem(title: "Option 2: Apollo Master Monitor Volume", action: #selector(selectWheelModeAction(_:)), keyEquivalent: "")
        monitorItem.target = self
        monitorItem.representedObject = "monitor"
        if currentWheelMode == "monitor" { monitorItem.state = .on }
        wheelMenu.addItem(monitorItem)
        
        let wheelTitle = currentWheelMode == "channel" ? "Channel Wheel: 1-Track Navigation" : "Channel Wheel: Apollo Monitor Vol"
        let wheelParentItem = NSMenuItem(title: wheelTitle, action: nil, keyEquivalent: "")
        wheelParentItem.submenu = wheelMenu
        menu.addItem(wheelParentItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Log & Utility options
        let liveLogItem = NSMenuItem(title: "Live Terminal Monitor...", action: #selector(openTerminalMonitor), keyEquivalent: "t")
        liveLogItem.target = self
        menu.addItem(liveLogItem)
        
        let viewLogItem = NSMenuItem(title: "Open Log File...", action: #selector(openLogFile), keyEquivalent: "l")
        viewLogItem.target = self
        menu.addItem(viewLogItem)
        
        let openFolderItem = NSMenuItem(title: "Open Bridge Directory...", action: #selector(openBridgeDirectory), keyEquivalent: "o")
        openFolderItem.target = self
        menu.addItem(openFolderItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Quit
        let quitItem = NSMenuItem(title: "Quit UA-MCU Bridge", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }
    
    func menuWillOpen(_ menu: NSMenu) {
        buildMenu()
    }
    
    // MARK: - Process Management
    func locateScriptDirectory() -> URL {
        // First check inside App Bundle Resources
        if let resURL = Bundle.main.resourceURL,
           FileManager.default.fileExists(atPath: resURL.appendingPathComponent("bridge.py").path) {
            return resURL
        }
        // Fallback to the known source workspace directory
        let fallbackPath = "/Users/jongyeonglee/Desktop/Vibe projects/echonav---accessible-media-manager/ua-mcu-bridge"
        return URL(fileURLWithPath: fallbackPath)
    }
    
    func startBridge() {
        if isRunning { return }
        
        // Kill any previous orphan bridge instances
        killExistingBridgeProcesses()
        
        let scriptDir = locateScriptDirectory()
        let bridgeScript = scriptDir.appendingPathComponent("bridge.py").path
        
        guard FileManager.default.fileExists(atPath: bridgeScript) else {
            NSLog("[UAMCUBridge] Error: bridge.py not found at \(bridgeScript)")
            return
        }
        
        // Prepare log file
        try? FileManager.default.createDirectory(at: logFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }
        
        guard let fileHandle = try? FileHandle(forWritingTo: logFileURL) else {
            NSLog("[UAMCUBridge] Error: Cannot open log file for writing at \(logFileURL.path)")
            return
        }
        fileHandle.seekToEndOfFile()
        let startMsg = "\n\n--- UA-MCU Bridge Started (\(Date())) Port: \(currentPort) ---\n"
        if let data = startMsg.data(using: .utf8) {
            fileHandle.write(data)
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", bridgeScript, "--port", String(currentPort)]
        process.currentDirectoryURL = scriptDir
        
        process.standardOutput = fileHandle
        process.standardError = fileHandle
        
        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                self?.isRunning = false
                self?.buildMenu()
                NSLog("[UAMCUBridge] Process terminated with status: \(proc.terminationStatus)")
            }
        }
        
        do {
            try process.run()
            self.bridgeProcess = process
            self.isRunning = true
            buildMenu()
            NSLog("[UAMCUBridge] Bridge started successfully (PID: \(process.processIdentifier))")
        } catch {
            NSLog("[UAMCUBridge] Failed to launch bridge: \(error)")
            self.isRunning = false
            buildMenu()
        }
    }
    
    func stopBridge(completion: (() -> Void)? = nil) {
        guard let process = bridgeProcess, process.isRunning else {
            isRunning = false
            buildMenu()
            completion?()
            return
        }
        
        // Send SIGINT so bridge cleanly resets faders and clears LCD
        kill(process.processIdentifier, SIGINT)
        
        DispatchQueue.global().async {
            var waitCount = 0
            while process.isRunning && waitCount < 20 {
                usleep(100_000) // 100ms
                waitCount += 1
            }
            if process.isRunning {
                process.terminate()
            }
            DispatchQueue.main.async {
                self.bridgeProcess = nil
                self.isRunning = false
                self.buildMenu()
                completion?()
            }
        }
    }
    
    func stopBridgeSync() {
        guard let process = bridgeProcess, process.isRunning else { return }
        kill(process.processIdentifier, SIGINT)
        var waitCount = 0
        while process.isRunning && waitCount < 15 {
            usleep(100_000)
            waitCount += 1
        }
        if process.isRunning {
            process.terminate()
        }
    }
    
    func killExistingBridgeProcesses() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-f", "bridge.py"]
        try? task.run()
        task.waitUntilExit()
    }
    
    // MARK: - Actions
    @objc func toggleBridgeAction() {
        if isRunning {
            stopBridge()
        } else {
            startBridge()
        }
    }
    
    @objc func restartBridgeAction() {
        stopBridge { [weak self] in
            self?.startBridge()
        }
    }
    
    @objc func selectPortAction(_ sender: NSMenuItem) {
        let newPort = sender.tag
        if newPort != currentPort {
            currentPort = newPort
            UserDefaults.standard.set(newPort, forKey: "UAMCUBridgePort")
            restartBridgeAction()
        }
    }
    
    @objc func selectWheelModeAction(_ sender: NSMenuItem) {
        if let mode = sender.representedObject as? String {
            writeWheelMode(mode)
            buildMenu()
        }
    }
    
    @objc func openTerminalMonitor() {
        // Opens terminal and tails the live log
        let script = "tell application \"Terminal\" to do script \"tail -f '\(logFileURL.path)'\""
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
        }
    }
    
    @objc func openLogFile() {
        NSWorkspace.shared.open(logFileURL)
    }
    
    @objc func openBridgeDirectory() {
        let dir = locateScriptDirectory()
        NSWorkspace.shared.open(dir)
    }
    
    @objc func quitApp() {
        stopBridgeSync()
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Main Entry Point
let app = NSApplication.shared
app.setActivationPolicy(.accessory) // Hides Dock icon, runs only in menu bar
let delegate = AppDelegate()
app.delegate = delegate
app.run()
