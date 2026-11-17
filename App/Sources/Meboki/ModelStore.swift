import CryptoKit
import Foundation

struct ModelInfo: Equatable {
    let id: String
    let name: String
    let file: String
    let url: URL
    let sha256: String
    let bytes: Int64
    let recommendedMinRAMGB: Int
    /// Name without the quantization, for the popover and Settings › Models ("Gemma 4 E4B").
    let shortName: String
    /// Measured peak memory and paragraph time (PLAN.md §3 benchmark, text-only `llama-server`).
    let peakMemoryGB: Double
    let paragraphSeconds: Double
    /// Errors fixed out of 45 on the shipped file (progress.md, eval on the bundled `llama-server`).
    let errorsFixed: Int
    /// One or two words on the onboarding card ("Most accurate").
    let tagline: String
    /// The 1–5 scales of Settings › Models (PLAN.md §3 "How Models Are Shown in the App").
    let ratings: ModelRatings
    var license: ModelLicense = .apache2
}

/// Accuracy, speed and memory as 1–5 scales (PLAN.md §3 Curated Catalog): accuracy and speed, more is better;
/// memory, more is heavier (≤2 GB → 1, ≤3 GB → 2, ≤4 GB → 3, ≤5 GB → 4, ≤6 GB → 5).
struct ModelRatings: Equatable {
    let accuracy: Int
    let speed: Int
    let memory: Int

    /// "Light", "Medium", "Heavy".
    var memoryWord: String { memory <= 2 ? "Light" : memory == 3 ? "Medium" : "Heavy" }
}

/// A model file's license (PLAN.md §3 Notes): shown with a link in Settings › Models. A license that needs
/// acceptance (Llama 3.1) is asked for once before the first download.
struct ModelLicense: Equatable {
    /// Key for the stored acceptance (`AppSettings.acceptedLicenses`).
    let id: String
    let name: String
    let url: URL
    let requiresAcceptance: Bool
    /// Who sets the terms, for the acceptance alert ("Meta").
    var owner = ""

    static let apache2 = ModelLicense(
        id: "apache-2.0", name: "Apache-2.0",
        url: URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!, requiresAcceptance: false)
    static let llama31 = ModelLicense(
        id: "llama3.1", name: "Llama 3.1 Community License",
        url: URL(string: "https://www.llama.com/llama3_1/license/")!, requiresAcceptance: true,
        owner: "Meta")
}

/// Curated models (PLAN.md §3). URLs are pinned to a Hugging Face commit. Gemma's numbers are from the
/// benchmark run (`-np 1`); Qwen3.5 and Llama 3.1 peak memory is measured with the app's server arguments
/// (`-c 8192 -np 4 --kv-unified`, 4 paragraphs at once; Gemma 4 E4B gives the same 4.76 GB there).
enum Catalog {
    static let gemma4E4B = ModelInfo(
        id: "gemma-4-e4b-q4_0", name: "Gemma 4 E4B (Q4_0)", file: "gemma-4-E4B-it-Q4_0.gguf",
        url: URL(string: "https://huggingface.co/ggml-org/gemma-4-E4B-it-GGUF/resolve/8903cb408c7df39cde2ed15fac397e6d7be92951/gemma-4-E4B-it-Q4_0.gguf")!,
        sha256: "a555b900214b477d8880e7832e0b8925e139b0159640036b09fe472b6f2097f2",
        bytes: 4_590_807_392, recommendedMinRAMGB: 16,
        shortName: "Gemma 4 E4B", peakMemoryGB: 4.75, paragraphSeconds: 1.4, errorsFixed: 45,
        tagline: "Most accurate",
        ratings: ModelRatings(accuracy: 5, speed: 3, memory: 4))

    static let gemma4E2B = ModelInfo(
        id: "gemma-4-e2b-q4_0", name: "Gemma 4 E2B (Q4_0)", file: "gemma-4-E2B-it-Q4_0.gguf",
        url: URL(string: "https://huggingface.co/ggml-org/gemma-4-E2B-it-GGUF/resolve/2a8538c2e2d4687953a86c422c7c623cfd022880/gemma-4-E2B-it-Q4_0.gguf")!,
        sha256: "8e30dff3ac4c8434c49a7036fa15564bdbb6044e42bf04550bf1a096ad7e6a52",
        bytes: 2_841_481_184, recommendedMinRAMGB: 8,
        shortName: "Gemma 4 E2B", peakMemoryGB: 3.6, paragraphSeconds: 0.8, errorsFixed: 43,
        tagline: "Faster",
        ratings: ModelRatings(accuracy: 4, speed: 5, memory: 3))

    static let qwen35_4B = ModelInfo(
        id: "qwen3.5-4b-q4_k_m", name: "Qwen3.5 4B (Q4_K_M)", file: "Qwen3.5-4B-Q4_K_M.gguf",
        url: URL(string: "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/e87f176479d0855a907a41277aca2f8ee7a09523/Qwen3.5-4B-Q4_K_M.gguf")!,
        sha256: "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4",
        bytes: 2_740_937_888, recommendedMinRAMGB: 8,
        shortName: "Qwen3.5 4B", peakMemoryGB: 3.5, paragraphSeconds: 1.1, errorsFixed: 38,
        tagline: "Fewest wrong changes",
        ratings: ModelRatings(accuracy: 3, speed: 4, memory: 2))

    static let llama31_8B = ModelInfo(
        id: "llama-3.1-8b-q4_k_m", name: "Llama 3.1 8B Instruct (Q4_K_M)",
        file: "Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf",
        url: URL(string: "https://huggingface.co/bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/resolve/bf5b95e96dac0462e2a09145ec66cae9a3f12067/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf")!,
        sha256: "7b064f5842bf9532c91456deda288a1b672397a54fa729aa665952863033557c",
        bytes: 4_920_739_232, recommendedMinRAMGB: 16,
        shortName: "Llama 3.1 8B", peakMemoryGB: 5.5, paragraphSeconds: 1.55, errorsFixed: 41, tagline: "Meta's Llama",
        ratings: ModelRatings(accuracy: 3, speed: 3, memory: 5), license: .llama31)

    static let all = [gemma4E4B, gemma4E2B, qwen35_4B, llama31_8B]
    /// The onboarding's Model page offers the two defaults only; the rest are in Settings › Models.
    static let onboarding = [gemma4E4B, gemma4E2B]

    static var ramGB: Int { Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) }

    static var recommended: ModelInfo { ramGB >= 16 ? gemma4E4B : gemma4E2B }

    static func byID(_ id: String?) -> ModelInfo? { all.first { $0.id == id } }
}

/// A model download that isn't finished (design_code.md §8.3 row states). No entry means idle: installed or
/// never started.
enum DownloadState: Equatable {
    case downloading(written: Int64, total: Int64)
    case paused(written: Int64, total: Int64)
    /// SHA-256 check of the finished file.
    case verifying
    case failed(String)

    var fraction: Double {
        switch self {
        case .downloading(let w, let t), .paused(let w, let t): t > 0 ? min(1, Double(w) / Double(t)) : 0
        case .verifying: 1
        case .failed: 0
        }
    }
}

/// Downloads models into ~/Library/Application Support/Meboki/Models with progress, pause, resume and a
/// SHA-256 check. Several models can download at once. All state lives on the main thread: URLSession
/// delegate callbacks are delivered on the main queue, and only the SHA-256 pass runs in the background.
/// A paused download keeps its resume data next to the model (`<file>.resume`), so it survives a relaunch
/// as long as the system keeps URLSession's partial file.
@MainActor
final class ModelStore: NSObject, ObservableObject, URLSessionDownloadDelegate {
    nonisolated static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Meboki/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Unfinished downloads by model ID.
    @Published private(set) var downloads: [String: DownloadState] = [:]
    /// Bumped when a model file appears (a download finished), so views re-read `isInstalled`.
    @Published private(set) var installedVersion = 0

    /// A download finished: installed (`.success`) or failed. Not called for a pause.
    var onFinish: ((ModelInfo, Result<URL, Error>) -> Void)?

    private var tasks: [String: URLSessionDownloadTask] = [:]
    /// Models whose task is being cancelled for a pause (their cancellation error is expected).
    private var pausing: Set<String> = []
    /// Models whose running task started from resume data (if it fails at once, start over).
    private var resumed: Set<String> = []
    private var lastPublish: [String: Date] = [:]
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    override init() {
        super.init()
        // Paused downloads from an earlier run.
        for m in Catalog.all where !isInstalled(m) {
            guard let data = try? Data(contentsOf: resumeURL(m)) else { continue }
            downloads[m.id] = .paused(written: Self.bytesReceived(in: data), total: m.bytes)
        }
    }

    /// Room left free beside a model download (the SHA-256 pass and the system need some).
    nonisolated static let spaceMargin: Int64 = 1_000_000_000

    /// Free space on the models folder's volume, counting what the system can purge for important data; nil
    /// when the system doesn't say.
    nonisolated static var freeSpace: Int64? {
        let v = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage
    }

    func localURL(_ m: ModelInfo) -> URL { Self.directory.appendingPathComponent(m.file) }
    private func resumeURL(_ m: ModelInfo) -> URL { Self.directory.appendingPathComponent(m.file + ".resume") }

    #if DEBUG
    /// DEBUG `--settings-demo`: fake installed models and download states.
    var demoInstalled: Set<String>?
    func demoSet(_ m: ModelInfo, _ state: DownloadState?) { downloads[m.id] = state }
    #endif

    func isInstalled(_ m: ModelInfo) -> Bool {
        #if DEBUG
        if let demoInstalled { return demoInstalled.contains(m.id) }
        #endif
        let size = (try? FileManager.default.attributesOfItem(atPath: localURL(m).path)[.size] as? NSNumber)?.int64Value
        return size == m.bytes
    }

    func state(_ m: ModelInfo) -> DownloadState? { downloads[m.id] }

    /// Starts or resumes the download of `m`. Does nothing while it's already downloading or verifying.
    func download(_ m: ModelInfo) {
        guard tasks[m.id] == nil, downloads[m.id] != .verifying, !isInstalled(m) else { return }
        let data = try? Data(contentsOf: resumeURL(m))
        // The rest of the file, plus some room, must fit on the disk (onboarding and Settings › Models).
        let needed = m.bytes - (data.map(Self.bytesReceived(in:)) ?? 0) + Self.spaceMargin
        if let free = Self.freeSpace, free < needed {
            let message = String(format: "Not enough disk space: needs %.1f GB, %.1f GB free.",
                                 Double(needed) / 1e9, Double(free) / 1e9)
            downloads[m.id] = .failed(message)
            Log.write("download: \(m.file) not started: \(message)")
            return
        }
        try? FileManager.default.removeItem(at: resumeURL(m))
        let task = data.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: m.url)
        if data != nil { resumed.insert(m.id) } else { resumed.remove(m.id) }
        task.taskDescription = m.id
        tasks[m.id] = task
        let written = data.map(Self.bytesReceived(in:)) ?? 0
        downloads[m.id] = .downloading(written: written, total: m.bytes)
        Log.write("download: \(data == nil ? "start" : "resume") \(m.file)")
        task.resume()
    }

    /// Deletes an installed model's file, or discards a paused or failed download (resume data and partial
    /// file). Refuses while the model downloads or its SHA-256 check runs. The caller makes sure the model
    /// isn't the one `llama-server` runs.
    func delete(_ m: ModelInfo) throws {
        switch downloads[m.id] {
        case .downloading, .verifying:
            throw Failure(message: "\(m.shortName) is still downloading.")
        default:
            break
        }
        #if DEBUG
        if demoInstalled != nil {
            demoInstalled?.remove(m.id)
            downloads[m.id] = nil
            installedVersion += 1
            return
        }
        #endif
        let fm = FileManager.default
        let partial = Self.directory.appendingPathComponent(m.file + ".partial")
        for url in [resumeURL(m), partial] where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        if fm.fileExists(atPath: localURL(m).path) { try fm.removeItem(at: localURL(m)) }
        downloads[m.id] = nil
        installedVersion += 1
        Log.write("model: deleted \(m.file)")
    }

    /// Pauses a running download. Its resume data is kept on disk for `download(_:)`.
    func pause(_ m: ModelInfo) {
        guard let task = tasks[m.id], case .downloading(let w, let t) = downloads[m.id] else { return }
        pausing.insert(m.id)
        tasks[m.id] = nil
        downloads[m.id] = .paused(written: w, total: t)
        Log.write("download: pause \(m.file)")
        task.cancel(byProducingResumeData: { [weak self] data in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Resumed again before the data arrived: that download started over.
                    guard let self, self.tasks[m.id] == nil else { return }
                    if let data { try? data.write(to: self.resumeURL(m), options: .atomic) }
                    // No resume data (the server doesn't support ranges): Resume starts over.
                    if data == nil, case .paused = self.downloads[m.id] {
                        self.downloads[m.id] = .paused(written: 0, total: m.bytes)
                    }
                }
            }
        })
    }

    // MARK: URLSessionDownloadDelegate (main queue)

    nonisolated func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        MainActor.assumeIsolated {
            guard let id = downloadTask.taskDescription, tasks[id] === downloadTask,
                  let m = Catalog.byID(id) else { return }
            // At most ten updates a second per model.
            let now = Date()
            if let last = lastPublish[id], now.timeIntervalSince(last) < 0.1 { return }
            lastPublish[id] = now
            let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : m.bytes
            downloads[id] = .downloading(written: totalBytesWritten, total: total)
        }
    }

    nonisolated func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        MainActor.assumeIsolated {
            guard let id = downloadTask.taskDescription, tasks[id] === downloadTask,
                  let m = Catalog.byID(id) else { return }
            tasks[id] = nil
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200, http.statusCode != 206 {
                fail(m, Failure(message: "Download failed with HTTP \(http.statusCode)."))
                return
            }
            // The temp file is deleted when this method returns: move it synchronously (same volume, fast).
            let partial = Self.directory.appendingPathComponent(m.file + ".partial")
            try? FileManager.default.removeItem(at: partial)
            do {
                try FileManager.default.moveItem(at: location, to: partial)
            } catch {
                fail(m, error)
                return
            }
            downloads[id] = .verifying
            let dest = localURL(m)
            DispatchQueue.global(qos: .utility).async {
                let result: Result<URL, Error>
                do {
                    let sum = try Self.sha256(of: partial)
                    guard sum == m.sha256 else {
                        try? FileManager.default.removeItem(at: partial)
                        throw Failure(message: "Checksum mismatch for \(m.file). The download was deleted; try again.")
                    }
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: partial, to: dest)
                    result = .success(dest)
                } catch {
                    result = .failure(error)
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        switch result {
                        case .success:
                            self.downloads[m.id] = nil
                            self.installedVersion += 1
                            Log.write("download: installed \(m.file)")
                            self.onFinish?(m, result)
                        case .failure(let e):
                            self.fail(m, e)
                        }
                    }
                }
            }
        }
    }

    nonisolated func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            guard let error, let id = task.taskDescription, let m = Catalog.byID(id) else { return }
            if pausing.remove(id) != nil { return }
            guard tasks[id] === task else { return }
            tasks[id] = nil
            if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                try? data.write(to: resumeURL(m), options: .atomic)
            } else if resumed.remove(id) != nil {
                // The partial file of an old pause is gone: start over once.
                Log.write("download: resume of \(m.file) failed (\(error.localizedDescription)); starting over")
                try? FileManager.default.removeItem(at: resumeURL(m))
                downloads[id] = nil
                download(m)
                return
            }
            fail(m, error)
        }
    }

    private func fail(_ m: ModelInfo, _ error: Error) {
        tasks[m.id] = nil
        downloads[m.id] = .failed(error.localizedDescription)
        Log.write("download: \(m.file) failed: \(error.localizedDescription)")
        onFinish?(m, .failure(error))
    }

    // MARK: Helpers

    /// Bytes already received, from URLSession resume data (a property list).
    nonisolated static func bytesReceived(in resumeData: Data) -> Int64 {
        let plist = try? PropertyListSerialization.propertyList(from: resumeData, format: nil) as? [String: Any]
        return (plist?["NSURLSessionResumeBytesReceived"] as? NSNumber)?.int64Value ?? 0
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        var h = SHA256()
        while let d = try fh.read(upToCount: 8 << 20), !d.isEmpty { h.update(data: d) }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
