// meboki-eval-run: runs benchmark cases through one backend and times each reply, so Apple's built-in model
// and llama-server can be measured by the same code on the same Mac (a macOS 26 Mac with no Xcode or Python).
// Built here (`swift build -c release --product meboki-eval-run`) and shipped in the bench kit
// (`Scripts/make-bench-kit.sh`); `eval/bench_remote.py` turns its output into the standard result JSON.
//
//   meboki-eval-run --probe
//       Prints this Mac's facts and Apple's model availability as one JSON line. Exit 0 when available, 3 if not.
//   meboki-eval-run (--apple [--default-guardrails] | --server URL) --cases FILE --out FILE
//                   [--prompt us|uk] [--lanes N] [--stream] [--label NAME] [--kinds a,b] [--no-warmup]
//       FILE: one JSON object per line, {"id", "kind", "input", ...} (`eval/export_cases.py`).
//       Writes JSON lines: a "meta" line (backend, prompt, lanes, machine facts, cold and warm first calls), one
//       "row" per case (output, wall, ttft, truncated, rejected, error) in input order, a "summary" line.
//       `--apple` uses `AppleModelClient` (fresh session per call, greedy, the app's prompt); `--server` uses the
//       app's `LLMClient` against llama-server (non-streaming) or the same request streamed (`--stream`, for time
//       to first token). `--lanes N` keeps N requests in flight, like `CheckPipeline`'s lanes.
//   Exit codes: 0 ok, 2 bad arguments, 3 Apple's model not available, 4 the backend failed for good.
import Foundation
import MebokiCore

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func sysctlString(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "" }
    return String(cString: buf)
}

func sysctlInt(_ name: String) -> Int64 {
    var v: Int64 = 0
    var size = MemoryLayout<Int64>.size
    return sysctlbyname(name, &v, &size, nil, 0) == 0 ? v : 0
}

/// The model changes with macOS updates, so every result carries the build it was measured on.
func machineFacts() -> [String: Any] {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    return [
        "model": sysctlString("hw.model"),
        "chip": sysctlString("machdep.cpu.brand_string"),
        "ram_gb": Double(sysctlInt("hw.memsize")) / 1_073_741_824,
        "macos": "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
        "build": sysctlString("kern.osversion"),
        "apple_model": AppleModelAvailability.system().rawValue,
    ]
}

func jsonLine(_ obj: [String: Any]) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    return String(decoding: data, as: UTF8.self)
}

// MARK: Arguments

var args = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name) else { return nil }
    guard i + 1 < args.count else { fail("\(name) needs a value", code: 2) }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

if flag("--probe") {
    let facts = machineFacts()
    print(jsonLine(facts))
    let a = AppleModelAvailability.system()
    if !a.isAvailable { FileHandle.standardError.write(Data((AppleModel.unavailableMessage(a) + "\n").utf8)) }
    exit(a.isAvailable ? 0 : 3)
}

let useApple = flag("--apple")
let defaultGuardrails = flag("--default-guardrails")
let serverURL = option("--server").flatMap(URL.init(string:))
let casesPath = option("--cases")
let outPath = option("--out")
let promptName = option("--prompt") ?? "us"
let lanes = max(1, Int(option("--lanes") ?? "1") ?? 1)
let stream = flag("--stream")
let warmup = !flag("--no-warmup")
let kinds = option("--kinds").map { Set($0.split(separator: ",").map(String.init)) }
let label = option("--label") ?? (useApple ? "apple" : "server")
if !args.isEmpty { fail("unknown arguments: \(args.joined(separator: " "))", code: 2) }
guard useApple != (serverURL != nil) else { fail("give exactly one of --apple or --server URL", code: 2) }
guard let casesPath, let outPath else { fail("--cases FILE and --out FILE are required", code: 2) }
guard let variant: EnglishVariant = promptName == "us" ? .us : promptName == "uk" ? .uk : nil else {
    fail("--prompt is us or uk", code: 2)
}
let system = Prompt.system(for: variant)

// MARK: Backends

struct Answer: Sendable {
    var output = ""
    var wall: TimeInterval = 0
    var ttft: TimeInterval?
    var truncated = false
    var error: String?
    /// Fatal for the whole run (model gone).
    var fatal = false
}

protocol Backend: Sendable {
    func answer(_ text: String) async -> Answer
}

#if canImport(FoundationModels)
@available(macOS 26, *)
struct AppleBackend: Backend {
    let client: AppleModelClient

    func answer(_ text: String) async -> Answer {
        // A system rate limit is waited out (a few tries) and counted, not scored as a refusal.
        var tries = 0
        while true {
            let started = Date()
            do {
                let t = try await client.respond(text, system: system, stream: stream)
                return Answer(output: t.reply.text, wall: Date().timeIntervalSince(started), ttft: t.firstToken,
                              truncated: t.reply.truncated)
            } catch let e as AppleModelError {
                if e == .rateLimited, tries < 4 {
                    tries += 1
                    try? await Task.sleep(for: .seconds(5 * tries))
                    continue
                }
                return Answer(wall: Date().timeIntervalSince(started), error: e.name,
                              fatal: e.isFatal && e != .rateLimited)
            } catch {
                return Answer(wall: Date().timeIntervalSince(started), error: "\(error)")
            }
        }
    }
}
#endif

struct ServerBackend: Backend {
    let base: URL

    func answer(_ text: String) async -> Answer {
        let started = Date()
        if !stream {
            do {
                let r = try await LLMClient(baseURL: base, timeout: 300).correct(text, system: system)
                return Answer(output: r.text, wall: Date().timeIntervalSince(started), truncated: r.truncated)
            } catch {
                return Answer(wall: Date().timeIntervalSince(started), error: error.localizedDescription)
            }
        }
        // The app's request (`LLMClient.correct`), streamed: time to the first content delta.
        let body: [String: Any] = [
            "messages": [["role": "system", "content": system], ["role": "user", "content": Prompt.user(text)]],
            "temperature": 0, "seed": 1, "max_tokens": LLMClient.maxTokens(for: text), "stream": true,
            "chat_template_kwargs": ["enable_thinking": false],
        ]
        var req = URLRequest(url: base.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        var out = Answer()
        do {
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                return Answer(wall: Date().timeIntervalSince(started), error: "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
            }
            for try await line in bytes.lines {
                guard line.hasPrefix("data: ") else { continue }
                let payload = line.dropFirst(6)
                if payload == "[DONE]" { break }
                guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                      let choice = (obj["choices"] as? [[String: Any]])?.first else { continue }
                if let delta = (choice["delta"] as? [String: Any])?["content"] as? String, !delta.isEmpty {
                    if out.ttft == nil { out.ttft = Date().timeIntervalSince(started) }
                    out.output += delta
                }
                if let finish = choice["finish_reason"] as? String { out.truncated = finish == "length" }
            }
        } catch {
            out.error = error.localizedDescription
        }
        out.wall = Date().timeIntervalSince(started)
        return out
    }
}

let backend: any Backend
var backendName: String
if useApple {
    #if canImport(FoundationModels)
    if #available(macOS 26, *) {
        let a = AppleModelAvailability.system()
        guard a.isAvailable else { fail("Apple's model isn't available (\(a.rawValue)): \(AppleModel.unavailableMessage(a))", code: 3) }
        backend = AppleBackend(client: AppleModelClient(permissiveGuardrails: !defaultGuardrails))
        backendName = defaultGuardrails ? "apple-default-guardrails" : "apple"
    } else {
        fail("Apple's model isn't available (osTooOld): \(AppleModel.unavailableMessage(.osTooOld))", code: 3)
    }
    #else
    fail("This build has no FoundationModels: \(AppleModel.unavailableMessage(.osTooOld))", code: 3)
    #endif
} else {
    backend = ServerBackend(base: serverURL!)
    backendName = "server"
}

// MARK: Cases

struct Case: Sendable {
    let id: String
    let kind: String
    let input: String
}

guard let raw = try? String(contentsOfFile: casesPath, encoding: .utf8) else { fail("can't read \(casesPath)", code: 2) }
let cases: [Case] = raw.split(separator: "\n").compactMap { line in
    guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
          let id = o["id"] as? String, let kind = o["kind"] as? String, let input = o["input"] as? String
    else { return nil }
    if let kinds, !kinds.contains(kind) { return nil }
    return Case(id: id, kind: kind, input: input)
}
guard !cases.isEmpty else { fail("no cases in \(casesPath)", code: 2) }

FileManager.default.createFile(atPath: outPath, contents: nil)
guard let out = FileHandle(forWritingAtPath: outPath) else { fail("can't write \(outPath)", code: 2) }
func write(_ obj: [String: Any]) { out.write(Data((jsonLine(obj) + "\n").utf8)) }

func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

// MARK: Run

/// The first call in a fresh process (cold: the model may need loading) and a second one right after (warm).
var meta: [String: Any] = ["type": "meta", "backend": backendName, "label": label, "prompt": promptName,
                           "lanes": lanes, "stream": stream, "cases": cases.count, "machine": machineFacts(),
                           "started": ISO8601DateFormatter().string(from: Date())]
if warmup {
    let cold = await backend.answer("This is a test.")
    if cold.fatal { fail("\(backendName) failed: \(cold.error ?? "")", code: 4) }
    let warm = await backend.answer("This is a test.")
    meta["cold_s"] = cold.wall
    meta["warm_s"] = warm.wall
    log(String(format: "%@: cold first call %.2f s, warm %.2f s", label, cold.wall, warm.wall))
}
write(meta)

actor Progress {
    var done = 0
    var errors = 0
    let total: Int
    init(total: Int) { self.total = total }
    func tick(_ a: Answer) {
        done += 1
        if a.error != nil { errors += 1 }
        if done % 10 == 0 || done == total {
            FileHandle.standardError.write(Data("  \(done)/\(total)\(errors > 0 ? " (\(errors) errors)" : "")\n".utf8))
        }
    }
}

let progress = Progress(total: cases.count)
let started = Date()
var answers = [Answer?](repeating: nil, count: cases.count)
var fatalError: String?
await withTaskGroup(of: (Int, Answer).self) { group in
    var next = 0
    func add() {
        let i = next, c = cases[i]
        next += 1
        group.addTask { (i, await backend.answer(c.input)) }
    }
    while next < min(lanes, cases.count) { add() }
    while let (i, a) = await group.next() {
        answers[i] = a
        await progress.tick(a)
        if a.fatal {
            fatalError = a.error
            group.cancelAll()
            break
        }
        if next < cases.count { add() }
    }
}
let total = Date().timeIntervalSince(started)

var errorCount = 0
for (i, c) in cases.enumerated() {
    guard let a = answers[i] else { continue }
    if a.error != nil { errorCount += 1 }
    var row: [String: Any] = ["type": "row", "id": c.id, "kind": c.kind, "input": c.input, "output": a.output,
                              "wall": a.wall, "truncated": a.truncated,
                              "rejected": a.truncated || a.error != nil]
    if let t = a.ttft { row["ttft"] = t }
    if let e = a.error { row["error"] = e }
    write(row)
}
write(["type": "summary", "total_wall": total, "rows": answers.compactMap { $0 }.count, "errors": errorCount,
       "fatal": fatalError ?? NSNull()])
try? out.close()
log(String(format: "%@: %d cases in %.1f s (%d at a time), %d errors", label, cases.count, total, lanes, errorCount))
if let fatalError { fail("stopped: \(fatalError)", code: 4) }
