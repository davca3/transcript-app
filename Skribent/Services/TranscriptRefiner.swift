import Foundation
// `Hub`, `HuggingFace`, `Tokenizers` are required at the macro call site below — the
// `#huggingFaceLoadModelContainer` macro expands to code that references types in those
// modules (HubClient, AutoTokenizer), so without these imports the expansion fails.
import Hub
import HuggingFace
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import Tokenizers

/// Post-processing pass over a Whisper transcript: feeds chunks of segments to a local Qwen 3
/// model running in-process via MLX, and asks it to fix obvious recognition errors using the
/// surrounding context. Timestamps and speaker assignments are preserved exactly — only
/// `TranscriptSegment.text` is rewritten.
///
/// Why MLX (and not Apple Foundation Models): Apple Intelligence does not yet support Czech.
/// Why MLX (and not Ollama HTTP): user wants the model bundled with the app, no separate daemon.
///
/// Setup is one-time:
/// 1. Dev machine needs Metal Toolchain: `sudo xcodebuild -downloadComponent MetalToolchain`
/// 2. First refine click triggers the model download to `Documents/huggingface/...` (~5 GB).
@MainActor
final class TranscriptRefiner {

    /// Mistral Nemo 12B Instruct 4-bit MLX. Picked over Qwen 3 8B because Czech tech meetings
    /// are typically bilingual (CS prose with EN technical terms — "deploynem ten endpoint",
    /// "nasdílím ten Slack channel"). Mistral has explicit European-language training data and
    /// preserves EN code-switching verbatim where Qwen sometimes "translates" EN tech terms to
    /// awkward CS equivalents. ~7 GB on disk, ~7 GB RAM, ~35 tokens/sec on M-series.
    /// To swap quality/speed:
    ///   - `LLMRegistry.qwen3_8b_4bit` (~5 GB, ~50 tok/s, slightly weaker CS naturalness)
    ///   - `LLMRegistry.qwen3_4b_4bit` (~2.5 GB, ~80 tok/s, fastest)
    static let modelRepoId = "mlx-community/Mistral-Nemo-Instruct-2407-4bit"
    static let modelConfiguration = ModelConfiguration(id: modelRepoId)

    /// Estimated total download size for the configured model. Used as denominator for the
    /// disk-poll progress when HubClient hasn't yet reported `totalUnitCount` (it only fires
    /// after listing the repo, which can take a few seconds). For Mistral Nemo 4-bit MLX the
    /// repo is ~7.0 GB; if you swap models, update this estimate so the bar isn't off.
    private static let estimatedTotalBytes: Int64 = 7_000_000_000

    /// Tiny lock-protected Int64 — used so the progress-poll task can safely read the
    /// HubClient-reported total while the resolve callback writes it. `os_unfair_lock` is the
    /// fastest available primitive on Apple platforms for this kind of single-word access.
    private final class AtomicInt64: @unchecked Sendable {
        private var lock = os_unfair_lock()
        private var _value: Int64
        init(_ initial: Int64) { _value = initial }
        var value: Int64 {
            os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
            return _value
        }
        func set(_ new: Int64) {
            os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
            _value = new
        }
    }

    /// Number of segments per LLM call. Balances cross-sentence context vs. per-call latency
    /// and token budget. 15 ≈ 2–3 minutes of meeting speech.
    static let chunkSize = 15

    /// Read-only context segments included from the previous chunk so the model understands
    /// continuity (who's talking, ongoing topic).
    static let contextOverlap = 2

    /// Reported back to the caller so the UI can label each phase distinctly.
    /// `.downloadingModel` carries a 0…1 fraction plus raw byte counts (so the UI can show
    /// "3.4 GB z 7.0 GB"); `.refining` carries a 0…1 fraction; `.loadingModel` is indeterminate
    /// — parsing safetensors + JIT-compiling Metal kernels happens after download completes
    /// and the underlying API doesn't expose progress for it.
    enum ProgressStage {
        case downloadingModel(fraction: Double, completedBytes: Int64, totalBytes: Int64)
        case loadingModel
        case refining(fraction: Double)
    }

    private var modelContainer: ModelContainer?

    /// HubClient configured with a URLSession that **ignores system proxy / WPAD config**.
    ///
    /// Without this, machines whose macOS Network settings have `Auto Proxy Discovery`
    /// enabled (`http://wpad/wpad.dat` is the default WPAD URL) hang on every download
    /// connection — URLSession spends 5–30 s trying to resolve the unreachable `wpad` host
    /// before falling back to direct, and the cumulative wait blocks multi-GB downloads.
    /// An empty `connectionProxyDictionary` forces direct connections regardless of system
    /// settings, which is the right behaviour for our case (we always talk to public HF).
    private static let noProxyHubClient: HubClient = {
        let config = URLSessionConfiguration.default
        config.connectionProxyDictionary = [:]
        // Long timeouts: weight blobs are multi-GB, slow links can stretch a single request
        // beyond the default 60 s.
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: config)
        return HubClient(session: session)
    }()

    func refine(
        transcript: Transcript,
        speakerName: (UUID?) -> String,
        progress: @escaping (ProgressStage) -> Void
    ) async throws -> Transcript {
        let segments = transcript.segments
        guard !segments.isEmpty else { return transcript }

        let container = try await ensureLoaded(progress: progress)

        var refined = segments
        let chunkSize = Self.chunkSize
        let overlap = Self.contextOverlap
        let totalChunks = (segments.count + chunkSize - 1) / chunkSize
        progress(.refining(fraction: 0))

        var i = 0
        var chunkIdx = 0
        while i < segments.count {
            // Honor `Task.cancel()` from the caller (the UI's "Zrušit" button) — we throw out
            // of the loop and the original transcript stays untouched (we only persist on
            // full success).
            try Task.checkCancellation()

            let end = Swift.min(segments.count, i + chunkSize)
            let ctxStart = Swift.max(0, i - overlap)
            let ctxEnd = Swift.min(segments.count, end + overlap)

            let userPrompt = buildPrompt(
                segments: segments,
                refineRange: i..<end,
                contextRange: ctxStart..<ctxEnd,
                nameFor: speakerName
            )

            do {
                let cT0 = Date()
                let response = try await generate(
                    container: container,
                    systemPrompt: Self.systemInstructions,
                    userPrompt: userPrompt
                )
                let elapsed = Date().timeIntervalSince(cT0)
                let parsed = parseResponse(response, expectedCount: end - i)
                if parsed.count == end - i {
                    for (offset, newText) in parsed.enumerated() {
                        refined[i + offset].text = newText
                    }
                    print(String(format: "[Refiner] chunk %d/%d: %d segments in %.2fs",
                                 chunkIdx + 1, totalChunks, end - i, elapsed))
                } else {
                    print("[Refiner] chunk \(chunkIdx + 1)/\(totalChunks): parse failed (got \(parsed.count) of \(end - i)), keeping originals")
                }
            } catch {
                print("[Refiner] chunk \(chunkIdx + 1)/\(totalChunks) FAILED: \(error) — keeping originals")
            }

            chunkIdx += 1
            progress(.refining(fraction: Double(chunkIdx) / Double(totalChunks)))
            i = end
        }

        return Transcript(segments: refined, detectedLanguage: transcript.detectedLanguage)
    }

    // MARK: - Model loading

    private func ensureLoaded(progress: @escaping (ProgressStage) -> Void) async throws -> ModelContainer {
        if let modelContainer { return modelContainer }
        print("[Refiner] resolving \(Self.modelConfiguration.id) (downloads on first run)…")
        let t0 = Date()

        // HubClient's `progressHandler` only fires per-file-completion, so during a multi-GB
        // safetensors blob the bar can sit on the same byte count for minutes while bytes are
        // actually streaming to disk. Workaround: spawn a sibling task that polls the cache
        // directory's on-disk size every second and feeds that into our progress reporting.
        // We reconcile with HubClient's reported `totalUnitCount` once it's known, falling
        // back to `estimatedTotalBytes` until then.
        progress(.downloadingModel(fraction: 0, completedBytes: 0, totalBytes: Self.estimatedTotalBytes))

        let cacheURL = Self.hubCacheDir(for: Self.modelRepoId)
        let totalBox = AtomicInt64(0)

        let pollTask = Task<Void, Never>.detached(priority: .utility) {
            while !Task.isCancelled {
                let onDisk = Self.directorySize(at: cacheURL)
                let total = await Swift.max(totalBox.value, Self.estimatedTotalBytes)
                let fraction = total > 0 ? Swift.min(1.0, Double(onDisk) / Double(total)) : 0
                progress(.downloadingModel(
                    fraction: fraction,
                    completedBytes: onDisk,
                    totalBytes: total
                ))
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        do {
            let resolved = try await resolve(
                configuration: Self.modelConfiguration,
                from: #hubDownloader(Self.noProxyHubClient),
                useLatest: false
            ) { hubProgress in
                // Capture the HubClient-reported total — used by the polling task as soon as
                // it's available so the fraction is grounded in reality, not our static
                // estimate. We deliberately ignore `completedUnitCount` here because it's the
                // jumpy per-file-done value we're trying to smooth out.
                if hubProgress.totalUnitCount > Self.estimatedTotalBytes / 10 {
                    totalBox.set(hubProgress.totalUnitCount)
                }
            }
            pollTask.cancel()
            // One last poll to lock the bar at 100 % before the load phase begins.
            let finalSize = Self.directorySize(at: cacheURL)
            progress(.downloadingModel(
                fraction: 1,
                completedBytes: finalSize,
                totalBytes: Swift.max(finalSize, totalBox.value)
            ))
            let dlElapsed = Date().timeIntervalSince(t0)
            print(String(format: "[Refiner] download phase done in %.1fs (%.1f GB on disk), loading into memory…",
                         dlElapsed, Double(finalSize) / 1_000_000_000))

            progress(.loadingModel)
            let loadStart = Date()
            let container = try await LLMModelFactory.shared.loadContainer(
                from: resolved.modelDirectory,
                using: #huggingFaceTokenizerLoader()
            )
            print(String(format: "[Refiner] load-into-memory done in %.1fs (total %.1fs)",
                         Date().timeIntervalSince(loadStart),
                         Date().timeIntervalSince(t0)))
            self.modelContainer = container
            return container
        } catch {
            pollTask.cancel()
            throw error
        }
    }

    /// Recursive byte-count of a directory tree. Returns 0 if the directory doesn't exist
    /// (e.g. before the first byte lands). Robust to partial / locked files — we only sum
    /// entries that report a `fileSize` resource value.
    /// `nonisolated` so the detached poll task can call it off the main actor.
    private nonisolated static func directorySize(at url: URL) -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        while let item = enumerator?.nextObject() as? URL {
            let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true, let size = values?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// Path that swift-huggingface's HubClient uses to cache a given repo. Mirrors the upstream
    /// `HubCache.default` layout (`Library/Caches/huggingface/hub/models--<org>--<repo>/`) so
    /// our disk poll watches the same directory the downloader writes to.
    private nonisolated static func hubCacheDir(for repoId: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let safeName = "models--" + repoId.replacingOccurrences(of: "/", with: "--")
        return caches
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("hub", isDirectory: true)
            .appendingPathComponent(safeName, isDirectory: true)
    }

    // MARK: - Generation

    private func generate(
        container: ModelContainer,
        systemPrompt: String,
        userPrompt: String
    ) async throws -> String {
        let chat: [Chat.Message] = [
            .system(systemPrompt),
            .user(userPrompt),
        ]
        let userInput = UserInput(chat: chat)
        // Low temperature: we want corrections, not creative rewrites. Generous max tokens to
        // accommodate the longest plausible chunk (15 segments × ~50 tokens × some margin).
        let parameters = GenerateParameters(maxTokens: 4096, temperature: 0.2)

        let lmInput = try await container.prepare(input: userInput)
        let stream = try await container.generate(input: lmInput, parameters: parameters)

        var output = ""
        for await item in stream {
            if let chunk = item.chunk {
                output += chunk
            }
        }
        return output
    }

    // MARK: - Prompt building / parsing

    private static let systemInstructions = """
    Jsi editor přepisů česky/anglicky mluvených nahrávek z tech meetingů. Tvůj úkol:

    1. Opravit zjevné chyby automatického rozpoznávání řeči — foneticky podobná slova, \
    špatně rozpoznaná jména, chybné koncovky, překlepy — pomocí kontextu věty a okolních vět.
    2. Zachovat smysl, tón a styl mluvčího. Nevymýšlej obsah. Nepřidávej a neodstraňuj informace.
    3. **Anglické technické termy zachovej beze změny** (deploy, endpoint, API, repository, \
    pull request, Slack, GitHub, frontend, backend, atd.). NEPŘEKLÁDEJ je do češtiny ani \
    nečešti přes koncovky cizích slov, pokud to mluvčí sám neudělal. Code-switching CS/EN je \
    v tech meetingu norma — respektuj to.
    4. Zachovat speakera, identifikátory ([N]), formát řádku.
    5. NESLUČOVAT, NEDĚLIT segmenty. Vrátíš přesně tolik řádků, kolik dostaneš.
    6. Pokud je segment OK, vrať ho beze změny.

    Odpověz POUZE opravenými řádky ve formátu vstupu, nic víc — žádné komentáře, vysvětlení \
    ani markdown.
    """

    private func buildPrompt(
        segments: [TranscriptSegment],
        refineRange: Range<Int>,
        contextRange: Range<Int>,
        nameFor: (UUID?) -> String
    ) -> String {
        var lines: [String] = []
        lines.append("Oprav následující segmenty přepisu. Vrať přesně \(refineRange.count) řádků se stejnými indexy [1]–[\(refineRange.count)].")
        lines.append("")

        if contextRange.lowerBound < refineRange.lowerBound {
            lines.append("Předchozí kontext (NEUPRAVUJ, jen pro orientaci v tématu):")
            for j in contextRange.lowerBound..<refineRange.lowerBound {
                let s = segments[j]
                lines.append("[ctx] \(nameFor(s.speakerId)): \(s.text)")
            }
            lines.append("")
        }

        lines.append("Segmenty k opravě:")
        for j in refineRange {
            let s = segments[j]
            let label = j - refineRange.lowerBound + 1
            lines.append("[\(label)] \(nameFor(s.speakerId)): \(s.text)")
        }

        if contextRange.upperBound > refineRange.upperBound {
            lines.append("")
            lines.append("Následující kontext (NEUPRAVUJ, jen pro orientaci v tématu):")
            for j in refineRange.upperBound..<contextRange.upperBound {
                let s = segments[j]
                lines.append("[ctx] \(nameFor(s.speakerId)): \(s.text)")
            }
        }

        lines.append("")
        lines.append("Opravené segmenty (\(refineRange.count) řádků):")
        return lines.joined(separator: "\n")
    }

    /// Parse the model's `[N] Speaker: text` response back into ordered texts. Returns an
    /// empty array on any structural failure so the caller can fall back to originals.
    private func parseResponse(_ response: String, expectedCount: Int) -> [String] {
        var slots: [String?] = Array(repeating: nil, count: expectedCount)
        for rawLine in response.split(whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("["),
                  let close = line.firstIndex(of: "]") else { continue }
            let inside = line[line.index(after: line.startIndex)..<close]
            // Skip context-marker lines the model might echo back.
            guard inside != "ctx", let idx = Int(inside), idx >= 1, idx <= expectedCount else { continue }

            // After ']' we expect " SPEAKER: text" — strip everything up to and including the first ':'.
            let afterBracket = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            guard let colon = afterBracket.firstIndex(of: ":") else { continue }
            let text = afterBracket[afterBracket.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            slots[idx - 1] = text
        }
        guard !slots.contains(where: { $0 == nil }) else { return [] }
        return slots.compactMap { $0 }
    }
}
