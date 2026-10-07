import Foundation
import CoreMIDI

/// Native Swift CoreMIDI Adapter for communicating with hardware and virtual MIDI ports.
public final class CoreMIDIAdapter {
    private var midiClient: MIDIClientRef = 0
    private var inPort: MIDIPortRef = 0
    private var outPort: MIDIPortRef = 0
    private var destinationEndpoint: MIDIEndpointRef = 0
    private var sourceEndpoint: MIDIEndpointRef = 0

    public private(set) var isConnected: Bool = false
    public var onMidiReceived: (([UInt8]) -> Void)?

    public init() {
        createClientAndPorts()
    }

    deinit {
        disposeAll()
    }

    private func createClientAndPorts() {
        var status = MIDIClientCreateWithBlock("UAMCUBridgeClient" as CFString, &midiClient) { [weak self] notifyPtr in
            self?.handleMIDINotification(notifyPtr)
        }
        guard status == noErr else {
            bridgeLog("[CoreMIDI] Error creating MIDI client: \(status)")
            return
        }

        status = MIDIOutputPortCreate(midiClient, "UAMCUBridgeOutPort" as CFString, &outPort)
        if status != noErr {
            bridgeLog("[CoreMIDI] Error creating MIDI output port: \(status)")
        }

        status = MIDIInputPortCreateWithBlock(midiClient, "UAMCUBridgeInPort" as CFString, &inPort) { [weak self] packetList, _ in
            self?.handleIncomingPackets(packetList)
        }
        if status != noErr {
            bridgeLog("[CoreMIDI] Error creating MIDI input port: \(status)")
        }
    }

    private func handleMIDINotification(_ notifyPtr: UnsafePointer<MIDINotification>) {
        let msgId = notifyPtr.pointee.messageID
        if msgId == .msgObjectAdded || msgId == .msgObjectRemoved || msgId == .msgPropertyChanged {
            // MIDI setup changed (e.g., virtual ports enabled/disabled)
        }
    }

    private func handleIncomingPackets(_ packetListPtr: UnsafePointer<MIDIPacketList>) {
        var packet = packetListPtr.pointee.packet
        for _ in 0..<packetListPtr.pointee.numPackets {
            var bytes: [UInt8] = []
            let dataCount = Int(packet.length)
            withUnsafePointer(to: &packet.data) { dataPtr in
                let bytePtr = UnsafeRawPointer(dataPtr).assumingMemoryBound(to: UInt8.self)
                for b in 0..<dataCount {
                    bytes.append(bytePtr[b])
                }
            }
            if !bytes.isEmpty {
                onMidiReceived?(bytes)
            }
            packet = MIDIPacketNext(&packet).pointee
        }
    }

    /// List all available CoreMIDI sources.
    public static func listSources() -> [(id: Int, name: String)] {
        var list: [(Int, String)] = []
        let count = MIDIGetNumberOfSources()
        for i in 0..<count {
            let endpoint = MIDIGetSource(i)
            list.append((i, getEndpointName(endpoint)))
        }
        return list
    }

    /// List all available CoreMIDI destinations.
    public static func listDestinations() -> [(id: Int, name: String)] {
        var list: [(Int, String)] = []
        let count = MIDIGetNumberOfDestinations()
        for i in 0..<count {
            let endpoint = MIDIGetDestination(i)
            list.append((i, getEndpointName(endpoint)))
        }
        return list
    }

    private static func getEndpointName(_ endpoint: MIDIEndpointRef) -> String {
        var name: Unmanaged<CFString>?
        let status = MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name)
        if status == noErr, let name = name {
            return name.takeRetainedValue() as String
        }
        var nameFallback: Unmanaged<CFString>?
        let status2 = MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &nameFallback)
        if status2 == noErr, let nameFallback = nameFallback {
            return nameFallback.takeRetainedValue() as String
        }
        return "Unknown MIDI Endpoint"
    }

    /// Connect to virtual or hardware ports matching port queries.
    public func connect(portNumber: Int, onReceived: @escaping ([UInt8]) -> Void) -> Bool {
        self.onMidiReceived = onReceived
        let portPrefix = "SSL V-MIDI Port \(portNumber)"

        // 1. Find Destination (outbound to UF8)
        destinationEndpoint = 0
        let destCount = MIDIGetNumberOfDestinations()
        for i in 0..<destCount {
            let endpoint = MIDIGetDestination(i)
            let name = CoreMIDIAdapter.getEndpointName(endpoint)
            if name.localizedCaseInsensitiveContains(portPrefix) {
                destinationEndpoint = endpoint
                break
            }
        }

        // 2. Find Source (inbound from UF8)
        sourceEndpoint = 0
        let srcCount = MIDIGetNumberOfSources()
        for i in 0..<srcCount {
            let endpoint = MIDIGetSource(i)
            let name = CoreMIDIAdapter.getEndpointName(endpoint)
            if name.localizedCaseInsensitiveContains(portPrefix) {
                sourceEndpoint = endpoint
                break
            }
        }

        guard destinationEndpoint != 0, sourceEndpoint != 0 else {
            bridgeLog("[CoreMIDI] Failed to find source or destination for: \(portPrefix)")
            isConnected = false
            return false
        }

        if midiClient == 0 || inPort == 0 || outPort == 0 {
            createClientAndPorts()
        }

        if sourceEndpoint != 0 && inPort != 0 {
            MIDIPortDisconnectSource(inPort, sourceEndpoint)
        }

        let status = MIDIPortConnectSource(inPort, sourceEndpoint, nil)
        guard status == noErr else {
            bridgeLog("[CoreMIDI] Failed to connect source: \(status)")
            isConnected = false
            return false
        }

        isConnected = true
        bridgeLog("[CoreMIDI] Successfully connected to \(portPrefix)")
        return true
    }

    private let sendLock = NSLock()

    /// Transmit raw MIDI bytes to the connected destination safely.
    public func sendMIDI(_ bytes: [UInt8]) {
        guard isConnected, destinationEndpoint != 0, outPort != 0, !bytes.isEmpty else { return }

        sendLock.lock()
        defer { sendLock.unlock() }

        let packetBufferSize = max(1024, bytes.count + 64)
        var packetData = [UInt8](repeating: 0, count: packetBufferSize)
        packetData.withUnsafeMutableBytes { rawBuf in
            guard let packetListPtr = rawBuf.baseAddress?.assumingMemoryBound(to: MIDIPacketList.self) else { return }
            let curPacket = MIDIPacketListInit(packetListPtr)
            _ = MIDIPacketListAdd(packetListPtr, packetBufferSize, curPacket, 0, bytes.count, bytes)
            MIDISend(outPort, destinationEndpoint, packetListPtr)
        }
    }

    /// Disconnect endpoints without destroying client/ports.
    public func close() {
        if isConnected && sourceEndpoint != 0 && inPort != 0 {
            MIDIPortDisconnectSource(inPort, sourceEndpoint)
        }
        sourceEndpoint = 0
        destinationEndpoint = 0
        isConnected = false
    }

    /// Full teardown on shutdown.
    public func disposeAll() {
        close()
        if inPort != 0 {
            MIDIPortDispose(inPort)
            inPort = 0
        }
        if outPort != 0 {
            MIDIPortDispose(outPort)
            outPort = 0
        }
        if midiClient != 0 {
            MIDIClientDispose(midiClient)
            midiClient = 0
        }
    }
}
