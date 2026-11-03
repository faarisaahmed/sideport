import Foundation

/// Talks to sideport-engine (bundled in the app) over stdin/stdout, one JSON object per line.
/// Requests are matched to replies by id; anything with an "event" key goes to `onEvent`.
final class Engine {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    var onEvent: (([String: Any]) -> Void)?
    var onLog: ((String) -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<Any, Error>] = [:]
    private let lock = NSLock()
    private var buffer = Data()

    static var executableURL: URL {
        if let bundled = Bundle.main.url(forResource: "sideport-engine", withExtension: nil) {
            return bundled
        }
        // Running from `swift run` during development.
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("engine/target/release/sideport-engine")
    }

    func start() throws {
        let p = Process()
        p.executableURL = Engine.executableURL
        var env = ProcessInfo.processInfo.environment
        env["RUST_LOG"] = env["RUST_LOG"] ?? "info"
        p.environment = env
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { return }
            self?.receive(data)
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") { self?.onLog?(String(line)) }
        }
        p.terminationHandler = { [weak self] _ in self?.failAll("The engine stopped unexpectedly. Restart Sideport.") }
        try p.run()
        process = p
        input = stdin.fileHandleForWriting
    }

    func stop() {
        process?.terminate()
    }

    @discardableResult
    func call(_ cmd: String, _ args: [String: Any] = [:]) async throws -> Any {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Any, Error>) in
            lock.lock()
            let id = nextId
            nextId += 1
            pending[id] = c
            lock.unlock()
            var request = args
            request["id"] = id
            request["cmd"] = cmd
            guard var data = try? JSONSerialization.data(withJSONObject: request) else {
                resolve(id, .failure(Failure(message: "couldn't encode \(cmd)")))
                return
            }
            data.append(0x0A)
            input?.write(data)
        }
    }

    /// Answers a "prompt" event (two-factor code, certificate question).
    func answer(_ prompt: String, _ fields: [String: Any]) {
        var request = fields
        request["prompt"] = prompt
        let payload = request
        Task { try? await call("answer", payload) }
    }

    private func receive(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer.subdata(in: buffer.startIndex..<nl))
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        lock.unlock()
        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if obj["event"] != nil {
                onEvent?(obj)
            } else if let id = obj["id"] as? Int {
                if obj["ok"] as? Bool == true {
                    resolve(id, .success(obj["result"] ?? NSNull()))
                } else {
                    resolve(id, .failure(Failure(message: obj["error"] as? String ?? "unknown error")))
                }
            }
        }
    }

    private func resolve(_ id: Int, _ result: Result<Any, Error>) {
        lock.lock()
        let c = pending.removeValue(forKey: id)
        lock.unlock()
        c?.resume(with: result)
    }

    private func failAll(_ message: String) {
        lock.lock()
        let all = pending
        pending.removeAll()
        lock.unlock()
        for c in all.values { c.resume(throwing: Failure(message: message)) }
    }
}
