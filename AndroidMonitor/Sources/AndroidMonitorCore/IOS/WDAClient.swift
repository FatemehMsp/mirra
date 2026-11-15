import Foundation

/// HTTP client for a running WebDriverAgent server on the device, reached through the local
/// usbmuxd port-forwarder. Touch input uses the W3C actions endpoint with viewport coordinates.
public struct WDAClient: Sendable {
    public enum WDAError: Error, LocalizedError {
        case notReady
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .notReady: return "WebDriverAgent did not come up on the device"
            case .failed(let text): return text
            }
        }
    }

    private let baseURL: URL
    private let session: URLSession

    public init(port: UInt16) {
        self.baseURL = URL(string: "http://127.0.0.1:\(port)")!
        self.session = URLSession(configuration: .ephemeral)
    }

    // MARK: - Session lifecycle

    /// Polls `/status` until WDA answers or `timeout` passes.
    public func waitUntilReady(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let ready = (try? await status())?.value.ready, ready { return true }
            try? await Task.sleep(for: .milliseconds(400))
        }
        return false
    }

    public struct Status: Decodable {
        struct Value: Decodable {
            struct Build: Decodable { let version: String? }
            let ready: Bool?
            let build: Build?
            let sessionId: String?
        }
        let value: Value
    }

    public func status() async throws -> Status {
        try await get("status")
    }

    public struct SessionReply: Decodable {
        struct Value: Decodable { let sessionId: String? }
        let value: Value
    }

    public func createSession() async throws -> String {
        let reply: SessionReply = try await post("session", body: ["capabilities": ["alwaysMatch": [String: Any]()]])
        guard let id = reply.value.sessionId else { throw WDAError.failed("WDA created no session") }
        return id
    }

    public struct WindowSize: Decodable {
        struct Value: Decodable { let width: Int?; let height: Int? }
        let value: Value
    }

    /// Screen size in points — the coordinate space WDA actions use.
    public func windowSize(sessionId: String) async throws -> (width: Double, height: Double) {
        let reply: WindowSize = try await get("session/\(sessionId)/window/size")
        guard let width = reply.value.width, let height = reply.value.height, width > 0, height > 0 else {
            throw WDAError.failed("WDA reported no window size")
        }
        return (Double(width), Double(height))
    }

    // MARK: - Input

    /// Sends one W3C actions payload (the only input API WDA needs).
    public func performActions(sessionId: String, actions: [[String: Any]]) async throws {
        let _: SessionReply = try await post("session/\(sessionId)/actions", body: ["actions": actions])
    }

    /// Tap at a viewport point.
    public func tap(sessionId: String, x: Double, y: Double) async throws {
        try await performActions(sessionId: sessionId, actions: Self.pointer([
            ["type": "pointerMove", "duration": 0, "x": Int(x.rounded()), "y": Int(y.rounded()), "origin": "viewport"],
            ["type": "pointerDown", "button": 0],
            ["type": "pause", "duration": 60],
            ["type": "pointerUp", "button": 0],
        ]))
    }

    /// Drag between two viewport points over `duration` milliseconds.
    public func drag(sessionId: String, from: (x: Double, y: Double), to: (x: Double, y: Double), durationMs: Int) async throws {
        let steps: Int = max(2, durationMs / 60)
        var sequence: [[String: Any]] = [
            ["type": "pointerMove", "duration": 0, "x": Int(from.x.rounded()), "y": Int(from.y.rounded()), "origin": "viewport"],
            ["type": "pointerDown", "button": 0],
        ]
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            let x = from.x + (to.x - from.x) * t
            let y = from.y + (to.y - from.y) * t
            sequence.append(["type": "pointerMove", "duration": durationMs / steps, "x": Int(x.rounded()), "y": Int(y.rounded()), "origin": "viewport"])
        }
        sequence.append(["type": "pointerUp", "button": 0])
        try await performActions(sessionId: sessionId, actions: Self.pointer(sequence))
    }

    /// One-finger W3C pointer action template.
    public static func pointer(_ steps: [[String: Any]]) -> [[String: Any]] {
        [
            [
                "type": "pointer",
                "id": "mirra-finger",
                "parameters": ["pointerType": "touch"],
                "actions": steps,
            ]
        ]
    }

    // MARK: - Transport

    private func get<T: Decodable>(_ path: String) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func post<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["value"]
            let text = (message as? [String: Any])?["message"] as? String ?? String(decoding: data, as: UTF8.self)
            throw WDAError.failed("WDA error \(http.statusCode): \(String(text.prefix(200)))")
        }
    }
}
