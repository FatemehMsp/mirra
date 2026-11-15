import Foundation
import Network

/// Minimal usbmuxd client: enough to list devices and open a TCP tunnel to a port on a USB
/// iOS device, which is how WDA's HTTP server is reached without external tools like iproxy.
///
/// Speaks the plist variant of the protocol over the `/var/run/usbmuxd` UNIX socket.
enum USBMux {
    static let socketPath = "/var/run/usbmuxd"

    struct Device: Equatable {
        let id: Int
        let serial: String
    }

    enum USBMuxError: Error, LocalizedError {
        case socketFailed
        case badResponse
        case connectRefused

        public var errorDescription: String? {
            switch self {
            case .socketFailed: return "Could not talk to usbmuxd (is the device connected?)"
            case .badResponse: return "Unexpected response from usbmuxd"
            case .connectRefused: return "The device refused the connection (is WDA running?)"
            }
        }
    }

    /// One request/response plist exchange with a fresh socket.
    static func exchange(_ request: [String: Any]) throws -> [String: Any] {
        let socket = try openSocket()
        defer { close(socket) }
        let payload = try plistData(request)
        // The usbmuxd header is little-endian (Apple never shipped it big-endian).
        var header = Data()
        header.append(UInt32(payload.count + 16).littleEndianData) // total length
        header.append(UInt32(1).littleEndianData)                  // version 1 = plist protocol
        header.append(UInt32(8).littleEndianData)                  // message 8 = plist
        header.append(UInt32(1).littleEndianData)                  // tag
        try writeFully(socket, header + payload)

        let responseHeader = try readFully(socket, 16)
        let length = responseHeader.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        guard length >= 16, length < 1_000_000 else { throw USBMuxError.badResponse }
        let body = length > 16 ? try readFully(socket, Int(length) - 16) : Data()
        guard let plist = try? PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any]
        else { throw USBMuxError.badResponse }
        return plist
    }

    /// Devices currently visible to usbmuxd (serial = UDID).
    static func devices() throws -> [Device] {
        try devices(in: exchange(["MessageType": "ListDevices"]))
    }

    /// Parses a ListDevices reply. usbmuxd nests the serial number under `Properties`,
    /// with only `DeviceID` (and `MessageType`) at the entry level.
    static func devices(in response: [String: Any]) -> [Device] {
        let list = (response["DeviceList"] as? [[String: Any]]) ?? []
        return list.compactMap { entry in
            let properties = entry["Properties"] as? [String: Any] ?? entry
            guard let serial = properties["SerialNumber"] as? String,
                  let id = (entry["DeviceID"] as? NSNumber)?.intValue else { return nil }
            return Device(id: id, serial: serial)
        }
    }

    /// Opens a connected socket to `port` on the device. After this returns, the socket carries
    /// the raw TCP stream. usbmuxd expects the port in big-endian byte order inside the plist.
    static func connect(deviceID: Int, port: UInt16) throws -> Int32 {
        let portNumber = UInt16(port).bigEndian // byte order, not the logical value
        let socket = try openSocket()
        let payload = try plistData(["MessageType": "Connect", "DeviceID": deviceID, "PortNumber": Int(portNumber)])
        var header = Data()
        header.append(UInt32(payload.count + 16).littleEndianData)
        header.append(UInt32(1).littleEndianData)
        header.append(UInt32(8).littleEndianData)
        header.append(UInt32(2).littleEndianData)
        do {
            try writeFully(socket, header + payload)
            let responseHeader = try readFully(socket, 16)
            let length = responseHeader.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            let body = length > 16 ? try readFully(socket, Int(length) - 16) : Data()
            let number = ((try? PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any])?["Number"] as? NSNumber)?.intValue ?? -1
            guard number == 0 else { close(socket); throw USBMuxError.connectRefused }
        } catch {
            close(socket)
            throw error
        }
        return socket
    }

    // MARK: - Socket plumbing

    static func openSocket() throws -> Int32 {
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { throw USBMuxError.socketFailed }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8CString.map { UInt8(bitPattern: $0) })
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { close(socket); throw USBMuxError.socketFailed }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.prefix(path.count)) }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { close(socket); throw USBMuxError.socketFailed }
        return socket
    }

    static func plistData(_ dictionary: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
    }

    static func writeFully(_ socket: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let written = Darwin.write(socket, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if written <= 0 { throw USBMuxError.socketFailed }
                sent += written
            }
        }
    }

    static func readFully(_ socket: Int32, _ count: Int) throws -> Data {
        var data = Data(capacity: count)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < count {
            let want = min(buffer.count, count - data.count)
            let read = buffer.withUnsafeMutableBufferPointer { Darwin.read(socket, $0.baseAddress, want) }
            if read <= 0 { throw USBMuxError.socketFailed }
            data.append(contentsOf: buffer.prefix(read))
        }
        return data
    }

    static func close(_ socket: Int32) {
        if socket >= 0 { Darwin.close(socket) }
    }
}

/// Bridges a local TCP port to a port on a USB iOS device through usbmuxd, so WDA can be
/// reached with plain HTTP from the Mac. One bridge per accepted connection.
final class USBMuxPortForwarder: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "mirra.usbmux.forwarder")
    private let deviceSerial: String
    private let devicePort: UInt16
    private var connections: [ObjectIdentifier: Bridge] = [:]
    private let lock = NSLock()
    public private(set) var localPort: UInt16?

    init(deviceSerial: String, devicePort: UInt16) {
        self.deviceSerial = deviceSerial
        self.devicePort = devicePort
    }

    /// Starts listening on an ephemeral localhost port; returns the port.
    func start() throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.localPort = listener.port?.rawValue
                ready.signal()
            }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.queue.async {
                let bridge = Bridge(connection: connection, serial: self.deviceSerial, port: self.devicePort)
                self.lock.withLock { self.connections[ObjectIdentifier(bridge)] = bridge }
                bridge.onClose = { [weak self, id = ObjectIdentifier(bridge)] in
                    guard let self else { return }
                    self.lock.withLock { self.connections.removeValue(forKey: id) }
                }
                bridge.start()
            }
        }
        self.listener = listener
        // Deliver listener callbacks on the forwarder's own queue, not the main queue:
        // start() blocks the calling thread (usually the main actor) on the semaphore below,
        // so a main-queue callback could never fire and start would always time out.
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = localPort else {
            throw USBMux.USBMuxError.socketFailed
        }
        return port
    }

    func stop() {
        listener?.cancel()
        listener = nil
        lock.withLock { connections.values.forEach { $0.stop() } }
        connections.removeAll()
    }

    /// Pumps bytes between one local TCP connection and one usbmuxd socket.
    private final class Bridge: @unchecked Sendable {
        let connection: NWConnection
        let serial: String
        let port: UInt16
        var onClose: (() -> Void)?
        private var muxSocket: Int32 = -1
        private var readSource: DispatchSourceRead?
        private let queue = DispatchQueue(label: "mirra.usbmux.bridge")

        init(connection: NWConnection, serial: String, port: UInt16) {
            self.connection = connection
            self.serial = serial
            self.port = port
        }

        func start() {
            do {
                guard let device = try USBMux.devices().first(where: { $0.serial == serial }) else {
                    throw USBMux.USBMuxError.socketFailed
                }
                muxSocket = try USBMux.connect(deviceID: device.id, port: port)
                connection.stateUpdateHandler = { [weak self] state in
                    if case .failed = state { self?.stop() }
                    if case .cancelled = state { self?.stop() }
                }
                connection.start(queue: queue)
                receiveFromDevice()
                receiveFromLocal()
            } catch {
                stop()
            }
        }

        private func receiveFromLocal() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data, !data.isEmpty {
                    try? USBMux.writeFully(self.muxSocket, data)
                }
                if isComplete || error != nil { self.stop(); return }
                self.receiveFromLocal()
            }
        }

        private func receiveFromDevice() {
            let source = DispatchSource.makeReadSource(fileDescriptor: muxSocket, queue: queue)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                let capacity = buffer.count
                let read = buffer.withUnsafeMutableBufferPointer { Darwin.read(self.muxSocket, $0.baseAddress, capacity) }
                if read > 0 {
                    self.connection.send(content: Data(buffer.prefix(read)), completion: .contentProcessed { _ in })
                } else {
                    self.stop()
                }
            }
            source.setCancelHandler { [weak self] in self?.stop() }
            source.resume()
            readSource = source
        }

        func stop() {
            readSource?.cancel(); readSource = nil
            if muxSocket >= 0 { USBMux.close(muxSocket); muxSocket = -1 }
            connection.cancel()
            onClose?()
            onClose = nil
        }
    }
}

private extension UInt32 {
    var littleEndianData: Data {
        withUnsafeBytes(of: littleEndian) { Data($0) }
    }
}
