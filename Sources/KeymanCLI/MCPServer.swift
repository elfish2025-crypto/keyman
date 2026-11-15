import Foundation
import Darwin
import KeymanCore

/// Local stdio MCP. No network listener, shell dispatch, credential export or stdout logging.
public actor MCPServer {
    public static let version = "0.7.5"
    static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    private enum Phase { case new, initializing, ready, closed }
    private var phase = Phase.new
    private let adapter: MCPToolAdapter
    private let output: @Sendable (Data) -> Void
    private var requests: [String: (token: UUID, task: Task<Void, Never>)] = [:]

    public init(application: CLIApplication, output: @escaping @Sendable (Data) -> Void) {
        adapter = MCPToolAdapter(application: application)
        self.output = output
    }

    public static func run(application: CLIApplication) async {
        // A disconnected client must not terminate Keyman with SIGPIPE while a result is written.
        signal(SIGPIPE, SIG_IGN)
        let server = MCPServer(application: application) { data in
            try? FileHandle.standardOutput.write(contentsOf: data)
        }
        await Task.detached {
            var framer = MCPLineFramer()
            var bytes = [UInt8](repeating: 0, count: 65_536)
            while true {
                // Foundation read(upToCount:) can wait to fill the buffer on a pipe.
                // POSIX read returns the available bytes so a short initialize is answered immediately.
                let count = bytes.withUnsafeMutableBytes { Darwin.read(STDIN_FILENO, $0.baseAddress, $0.count) }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                for event in framer.append(Data(bytes.prefix(count))) {
                    switch event {
                    case .message(let data): await server.receive(data)
                    case .oversized: await server.rejectOversized()
                    }
                }
            }
            // EOF is not a delimiter: a partial JSON line has not been submitted.
            await server.shutdown()
        }.value
    }

    func receive(_ line: Data) {
        guard phase != .closed else { return }
        guard line.count <= MCPLineFramer.limit else { rejectOversized(); return }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: line) else {
            error(id: .null, code: -32700, message: "Parse error"); return
        }
        guard let message = value.objectValue, message["jsonrpc"] == .string("2.0"),
              let method = message["method"]?.stringValue else {
            error(id: .null, code: -32600, message: "Invalid Request"); return
        }
        let optionalID = message["id"]
        if let id = optionalID, requestKey(id) == nil { error(id: .null, code: -32600, message: "Invalid request id"); return }
        guard message["params"] == nil || message["params"]?.objectValue != nil else {
            if let id = optionalID { error(id: id, code: -32602, message: "Params must be an object") }; return
        }
        let params = message["params"]?.objectValue ?? [:]
        if optionalID == nil {
            if method == "notifications/initialized", phase == .initializing { phase = .ready }
            if method == "notifications/cancelled", let id = params["requestId"], let key = requestKey(id) {
                requests.removeValue(forKey: key)?.task.cancel()
            }
            // Unknown notifications are ignored and never receive a response.
            return
        }
        let id = optionalID!
        if method == "ping" { response(id: id, result: .object([:])); return }
        if method == "initialize" {
            guard phase == .new, let requested = params["protocolVersion"]?.stringValue,
                  params["capabilities"]?.objectValue != nil,
                  params["clientInfo"]?["name"]?.stringValue != nil,
                  params["clientInfo"]?["version"]?.stringValue != nil else {
                error(id: id, code: -32602, message: "Invalid or repeated initialize"); return
            }
            phase = .initializing
            response(id: id, result: .object([
                "protocolVersion": .string(Self.protocolVersions.contains(requested) ? requested : Self.protocolVersions[0]),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": .object(["name": .string("keyman"), "version": .string(Self.version)]),
                "instructions": .string(MCPToolAdapter.instructions)
            ]))
            return
        }
        guard phase == .ready else { error(id: id, code: -32002, message: "Server not initialized"); return }
        switch method {
        case "tools/list":
            guard params["cursor"] == nil else { error(id: id, code: -32602, message: "Invalid cursor"); return }
            response(id: id, result: .object(["tools": .array(MCPToolAdapter.tools.map(\.json))]))
        case "tools/call":
            guard let name = params["name"]?.stringValue,
                  params["arguments"] == nil || params["arguments"]?.objectValue != nil else {
                error(id: id, code: -32602, message: "Invalid tool parameters"); return
            }
            let key = requestKey(id)!
            guard requests[key] == nil else { error(id: id, code: -32600, message: "Request id already in flight"); return }
            guard requests.count < 32 else { error(id: id, code: -32000, message: "Too many in-flight requests"); return }
            let arguments = params["arguments"]?.objectValue ?? [:]
            let token = UUID()
            let adapter = adapter
            let task = Task {
                let result: JSONValue
                do {
                    try Task.checkCancellation()
                    result = try await adapter.call(name: name, arguments: arguments)
                } catch is CancellationError { return }
                catch MCPToolError.unknownTool { finishError(id: id, key: key, token: token, message: "Unknown tool"); return }
                catch MCPToolError.invalidArguments { finishError(id: id, key: key, token: token, message: "Invalid arguments; follow the tool input schema and conditional fields."); return }
                catch { result = MCPToolAdapter.wrap(CLIOutput.error(error)) }
                guard !Task.isCancelled, requests[key]?.token == token else { return }
                requests.removeValue(forKey: key)
                response(id: id, result: result)
            }
            requests[key] = (token, task)
        default: error(id: id, code: -32601, message: "Method not found")
        }
    }

    func shutdown() {
        phase = .closed
        for request in requests.values { request.task.cancel() }
        requests.removeAll()
    }
    func rejectOversized() { error(id: .null, code: -32600, message: "Message exceeds 1 MiB") }
    private func finishError(id: JSONValue, key: String, token: UUID, message: String) {
        guard requests[key]?.token == token else { return }
        requests.removeValue(forKey: key)
        error(id: id, code: -32602, message: message)
    }
    private func requestKey(_ id: JSONValue) -> String? {
        switch id {
        case .integer, .string:
            return (try? JSONEncoder().encode(id)).map { String(decoding: $0, as: UTF8.self) }
        default: return nil
        }
    }
    private func response(id: JSONValue, result: JSONValue) {
        emit(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
    }
    private func error(id: JSONValue, code: Int64, message: String) {
        emit(.object(["jsonrpc": .string("2.0"), "id": id,
            "error": .object(["code": .integer(code), "message": .string(message)])]))
    }
    private func emit(_ message: JSONValue) {
        guard phase != .closed, var data = try? JSONEncoder().encode(message) else { return }
        if data.count > 8 * 1_048_576 {
            data = (try? JSONEncoder().encode(JSONValue.object(["jsonrpc": .string("2.0"), "id": message["id"] ?? .null,
                "error": .object(["code": .integer(-32000), "message": .string("Result too large; narrow the query. Do not repeat a generation request.")])]))) ?? Data()
        }
        data.append(0x0a)
        output(data)
    }
}

/// Bound memory even if a peer never sends a newline; discard the entire oversized message.
struct MCPLineFramer {
    static let limit = 1_048_576
    enum Event { case message(Data), oversized }
    private var buffer = Data()
    private var discarding = false
    mutating func append(_ chunk: Data) -> [Event] {
        var events: [Event] = []
        for byte in chunk {
            if byte == 0x0a {
                if !discarding, !buffer.isEmpty { events.append(.message(buffer)) }
                buffer.removeAll(keepingCapacity: true); discarding = false
            } else if !discarding {
                if buffer.count == Self.limit {
                    events.append(.oversized); buffer.removeAll(keepingCapacity: true); discarding = true
                } else { buffer.append(byte) }
            }
        }
        return events
    }
}
