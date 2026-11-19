import Foundation
import MebokiCore

/// Runs the bundled llama-server as a hidden child process on 127.0.0.1 (PLAN.md §2).
@MainActor
final class ServerManager {
    enum State: Equatable {
        case stopped
        case starting
        case ready(URL)
        /// Stopped to free memory (idle, or memory pressure); the next check loads the model again (`reload()`).
        case unloaded
        case failed(String)
    }

    /// Requests the server works on at once (Optimization A3): `-np` slots sharing one 8192-token KV pool
    /// (`--kv-unified`), so a long paragraph still fits. Measured 2026-11-16 on the long-field page (E4B, M2 Max):
    /// 196 requests take 55 s one at a time on one slot, 31 s four at a time on four; replies are byte-identical
    /// (eval/bench_parallel.py); a request alone is ~16% slower; +0.25 GB.
    static let slots = 4

    private(set) var state: State = .stopped { didSet { onChange?(state) } }
    var onChange: ((State) -> Void)?
    private var process: Process?
    private var stopping = false
    /// The model `start(model:)` loaded last: `reload()` starts it again after an unload.
    private var model: URL?
    private var startedAt = Date()

    // Idle unload (Optimization B3, PLAN §7): after `idleLimit` with no request, and on memory pressure, the
    // server stops and frees the model's memory (about 4.4 GB for E4B). Loading again takes ~1.5 s with the
    // weights in the file cache and ~4.6 s from disk (M2 Max, measured 2026-11-16).

    /// No request for this long unloads the model; nil never unloads for idleness.
    var idleLimit: TimeInterval? = 15 * 60
    /// The app is in the middle of a check (the server may not have the request yet): don't unload.
    var isBusy: () -> Bool = { false }
    private var lastUse = Date()
    private var idleTimer: Timer?
    private var pressure: DispatchSourceMemoryPressure?
    /// A memory-pressure warning unloads only a model unused for this long; critical pressure, one unused for
    /// `pressureCriticalIdle` (a scheduler may be about to send what was just handed to it after a typing pause).
    static let pressureWarningIdle: TimeInterval = 60
    static let pressureCriticalIdle: TimeInterval = 10

    static let logURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Meboki", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("llama-server.log")
    }()

    /// Bundled binary; in DEBUG builds `MEBOKI_LLAMA_SERVER` overrides it when running outside the .app.
    /// Release builds ignore it: the server runs inside Meboki's Accessibility trust, so a variable set with
    /// `launchctl setenv` must not be able to pick the binary.
    static var executable: URL? {
        #if DEBUG
        if let p = ProcessInfo.processInfo.environment["MEBOKI_LLAMA_SERVER"] { return URL(fileURLWithPath: p) }
        #endif
        return Bundle.main.url(forAuxiliaryExecutable: "llama-server")
    }

    func start(model: URL) {
        stop()
        self.model = model
        startedAt = Date()
        startWatching()
        guard let exe = Self.executable, FileManager.default.isExecutableFile(atPath: exe.path) else {
            state = .failed("llama-server not found in the app bundle")
            return
        }
        killOrphans(exe)
        let port = Self.freePort()
        let p = Process()
        p.executableURL = exe
        p.arguments = [
            "-m", model.path, "--host", "127.0.0.1", "--port", String(port),
            "-c", "8192", "-np", String(Self.slots), "--kv-unified", "--jinja", "--no-webui", "-ngl", "999",
        ]
        FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)
        if let log = try? FileHandle(forWritingTo: Self.logURL) {
            p.standardOutput = log
            p.standardError = log
        }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self, self.process === proc else { return }
                self.process = nil
                if !self.stopping { self.state = .failed("Model server exited (code \(proc.terminationStatus)). See log.") }
            }
        }
        do {
            try p.run()
        } catch {
            state = .failed("Couldn't start llama-server: \(error.localizedDescription)")
            return
        }
        process = p
        stopping = false
        state = .starting

        let base = URL(string: "http://127.0.0.1:\(port)")!
        let client = LLMClient(baseURL: base)
        Task { @MainActor in
            for _ in 0..<1800 {  // up to ~3 min for a cold load
                if self.process !== p { return }
                if await client.isHealthy() {
                    guard self.process === p else { return }
                    Log.write(String(format: "server: %@ loaded in %.1f s", model.lastPathComponent,
                                     Date().timeIntervalSince(self.startedAt)))
                    self.lastUse = Date()
                    self.state = .ready(base)
                    return
                }
                // Polled often: the load itself takes 1.5–5 s, so a 0.5 s step added up to 0.5 s.
                try? await Task.sleep(for: .milliseconds(100))
            }
            if self.process === p { self.state = .failed("Model server didn't become ready. See log.") }
        }
    }

    func stop() {
        guard let p = process else {
            if state == .unloaded { state = .stopped }
            return
        }
        stopping = true
        process = nil
        p.terminate()
        p.waitUntilExit()
        state = .stopped
    }

    /// A request is about to go to the model (or the user started a check): restarts the idle clock.
    func noteUse() {
        lastUse = Date()
    }

    /// Loads the model again after an unload. True when it started (the caller waits for `.ready`).
    @discardableResult
    func reload(reason: String) -> Bool {
        guard state == .unloaded, let model else { return false }
        Log.write("server: loading again (\(reason))")
        start(model: model)
        return true
    }

    /// Stops the server to free memory; `state` becomes `.unloaded`, and `reload()` starts it again. Skipped
    /// while a check runs or a slot is still working on a request.
    private func unload(reason: String, minimumIdle: TimeInterval) {
        guard case .ready(let base) = state, process != nil, !isBusy(),
              Date().timeIntervalSince(lastUse) >= minimumIdle else { return }
        let use = lastUse
        Task { @MainActor in
            // The server knows best whether a request is still running (one sent by a scheduler after a pause).
            guard await !Self.slotsBusy(base), case .ready(base) = self.state, self.lastUse == use, !self.isBusy(),
                  let p = self.process else { return }
            self.stopping = true
            self.process = nil
            p.terminate()
            p.waitUntilExit()
            Log.write("server: unloaded (\(reason))")
            self.state = .unloaded
        }
    }

    /// The menu's Unload Model: unload unless a check is running.
    func unloadNow() {
        unload(reason: "from the menu", minimumIdle: 0)
    }

    /// Any slot processing a request. An unreachable server counts as busy (don't act on a guess).
    private static func slotsBusy(_ base: URL) async -> Bool {
        var req = URLRequest(url: base.appendingPathComponent("slots"))
        req.timeoutInterval = 2
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let slots = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return true }
        return slots.contains { $0["is_processing"] as? Bool == true }
    }

    /// The idle timer and the memory-pressure source, set up once on the first start.
    private func startWatching() {
        if idleTimer == nil {
            let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.idleTick() }
            }
            t.tolerance = 10
            RunLoop.main.add(t, forMode: .common)
            idleTimer = t
        }
        if pressure == nil {
            let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
            src.setEventHandler { [weak self, weak src] in
                guard let event = src?.data else { return }
                MainActor.assumeIsolated { self?.memoryPressure(event) }
            }
            src.resume()
            pressure = src
        }
    }

    private func idleTick() {
        guard let limit = idleLimit else { return }
        unload(reason: "idle \(Int(limit / 60)) min", minimumIdle: limit)
    }

    private func memoryPressure(_ event: DispatchSource.MemoryPressureEvent) {
        let critical = event.contains(.critical)
        guard critical || event.contains(.warning) else { return }
        unload(reason: critical ? "memory pressure: critical" : "memory pressure",
               minimumIdle: critical ? Self.pressureCriticalIdle : Self.pressureWarningIdle)
    }

    /// A previous crash can leave our llama-server running; only kill processes started from our binary path.
    private func killOrphans(_ exe: URL) {
        let k = Process()
        k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        k.arguments = ["-f", "^" + NSRegularExpression.escapedPattern(for: exe.path) + " "]
        try? k.run()
        k.waitUntilExit()
    }

    private static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        let port = Int(UInt16(bigEndian: addr.sin_port))
        return port > 0 ? port : 18080
    }
}
