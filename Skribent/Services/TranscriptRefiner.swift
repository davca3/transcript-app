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

    /// Qwen 2.5 7B Instruct 4-bit MLX. Picked over Mistral Nemo 12B 4-bit because Mistral at
    /// 4-bit quantization was deterministically greedy ("copy input verbatim") — needed temp 0.5
    /// to break out, which then introduced spurious changes ("tuhle" → "touhle"). Qwen 2.5 has
    /// stronger instruction following at the same parameter scale and follows the few-shot prompt
    /// reliably even at temp 0.3. Trade-off vs. Mistral: marginally weaker on EN code-switching
    /// preservation, mitigated by explicit list in system prompt. ~4.3 GB on disk, ~4 GB RAM,
    /// ~50 tokens/sec on M-series.
    /// Other options if quality/speed needs to shift:
    ///   - `mlx-community/Qwen2.5-14B-Instruct-4bit` (~8 GB, ~25 tok/s, better hard-case recovery)
    ///   - `mlx-community/Qwen2.5-3B-Instruct-4bit` (~2 GB, ~80 tok/s, fastest, weaker reconstruction)
    static let modelRepoId = "mlx-community/Qwen2.5-7B-Instruct-4bit"
    static let modelConfiguration = ModelConfiguration(id: modelRepoId)

    /// Estimated total download size for the configured model. Used as denominator for the
    /// disk-poll progress when HubClient hasn't yet reported `totalUnitCount` (it only fires
    /// after listing the repo, which can take a few seconds). For Qwen 2.5 7B 4-bit MLX the
    /// repo is ~4.3 GB; if you swap models, update this estimate so the bar isn't off.
    private nonisolated static let estimatedTotalBytes: Int64 = 4_500_000_000

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

                // Diagnostic: dump raw LLM response so we can tell whether the model returned
                // input verbatim (model issue) or something different that the parser later
                // re-aligned to the original (parser issue). Truncated to 1200 chars.
                let preview = response.count > 1200 ? String(response.prefix(1200)) + "\n…[truncated, total \(response.count) chars]" : response
                Log.refiner.debug("chunk \(chunkIdx + 1, privacy: .public)/\(totalChunks, privacy: .public) raw response:\n\(preview, privacy: .public)\n--- end of raw response ---")

                let parsed = parseResponse(response, expectedCount: end - i)
                var changed = 0
                var skipped = 0
                for offset in 0..<(end - i) {
                    let oldText = refined[i + offset].text
                    guard let newText = parsed[offset] else {
                        skipped += 1
                        Log.refiner.debug("  [\(offset + 1, privacy: .public)] PARSE FAILED — keeping original: \(oldText)")
                        continue
                    }
                    if oldText != newText {
                        changed += 1
                        Log.refiner.debug("  [\(offset + 1, privacy: .public)] CHANGED OLD: \(oldText) NEW: \(newText.isEmpty ? "(empty — segment will be dropped)" : newText)")
                    }
                    refined[i + offset].text = newText
                }
                let unchanged = (end - i) - changed - skipped
                Log.refiner.info("chunk \(chunkIdx + 1, privacy: .public)/\(totalChunks, privacy: .public): \(end - i, privacy: .public) segments in \(elapsed, format: .fixed(precision: 2), privacy: .public)s (\(changed, privacy: .public) changed, \(unchanged, privacy: .public) unchanged, \(skipped, privacy: .public) parse-skipped)")
            } catch {
                Log.refiner.error("chunk \(chunkIdx + 1, privacy: .public)/\(totalChunks, privacy: .public) FAILED: \(error.localizedDescription, privacy: .public) — keeping originals")
            }

            chunkIdx += 1
            progress(.refining(fraction: Double(chunkIdx) / Double(totalChunks)))
            i = end
        }

        // Drop segments the LLM blanked out (system prompt instructs it to return empty text
        // for evidently-hallucinated content like "Děkuji za sledování"). The original
        // Whisper run already filters empty segments, so anything blank here came from refine.
        let cleaned = refined.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return Transcript(segments: cleaned, detectedLanguage: transcript.detectedLanguage)
    }

    // MARK: - Model loading

    private func ensureLoaded(progress: @escaping (ProgressStage) -> Void) async throws -> ModelContainer {
        if let modelContainer { return modelContainer }
        Log.refiner.info("resolving \(Self.modelRepoId, privacy: .public) (downloads on first run)…")
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
            Log.refiner.info("download phase done in \(dlElapsed, format: .fixed(precision: 1), privacy: .public)s (\(Double(finalSize) / 1_000_000_000, format: .fixed(precision: 1), privacy: .public) GB on disk), loading into memory…")

            progress(.loadingModel)
            let loadStart = Date()
            let container = try await LLMModelFactory.shared.loadContainer(
                from: resolved.modelDirectory,
                using: #huggingFaceTokenizerLoader()
            )
            Log.refiner.info("load-into-memory done in \(Date().timeIntervalSince(loadStart), format: .fixed(precision: 1), privacy: .public)s (total \(Date().timeIntervalSince(t0), format: .fixed(precision: 1), privacy: .public)s)")
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
        let safeName = "models--" + repoId.replacingOccurrences(of: "/", with: "--")
        return AppPaths.caches
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
        // Temperature 0.3: Qwen 2.5 follows few-shot prompts reliably without needing the
        // 0.5 we had to use for Mistral Nemo. Lower temp = same correction depth + fewer
        // hallucinated changes (Mistral at 0.5 sometimes "corrected" already-correct words,
        // e.g. "tuhle" → "touhle"). Generous max tokens to accommodate the longest plausible
        // chunk (15 segments × ~50 tokens × margin).
        let parameters = GenerateParameters(maxTokens: 4096, temperature: 0.3)

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
    Jsi profesionální editor přepisů česko-anglických nahrávek. Whisper produkuje přepis se \
    spoustou chyb — fonetické deformace, vymyšlená slova, chybějící hlásky, špatné koncovky. \
    Tvým úkolem JE je AGRESIVNĚ rekonstruovat do správné češtiny pomocí kontextu věty a okolí. \
    Nedělej jen kosmetické úpravy (čárky, velká písmena) — primárně oprav OBSAH slov.

    PRAVIDLO Č. 1 — REKONSTRUKCE FONETICKY DEFORMOVANÝCH SLOV:
    Pokud slovo NENÍ reálné české (nebo anglické tech-term) slovo, je foneticky podobné nějakému \
    skutečnému slovu, NEBO věta jako celek nedává smysl, REKONSTRUUJ správné slovo podle \
    kontextu. Drž se zvukové podoby, ale výsledek musí být reálné slovo dávající smysl ve větě.

    Příklady fonetických deformací (jen pro inspiraci, ne výčet):
    „kacelař" → „kancelář" • „zratíž" → „ztratíš" • „v přípádi" → „v případě" • \
    „udelame deploj" → „uděláme deploy" • „pouříví" → „používáš" • „kdyz" → „když" • \
    „buť" → „buď" • „svům" → „svůj" • „odhlanit" → „odhlásit" • „rekvest" → „request" • \
    „revjů" → „review" • „eskejp" → „escape"

    DALŠÍ OPRAVY:
    2. **Chybné koncovky** — rod, pád, číslo, shoda podmětu s přísudkem napříč větou.
    3. **Diakritika a interpunkce** — doplň čárky v souvětích, oprav ú/ů, i/y, tečky.
    4. **Vlastní jména a produkty** — kapitalizuj správně (Slack, GitHub, macOS, Figma, Postgres, \
    Linear, Jira, Notion, Apple, Google).
    5. **Halucinace Whisperu** — pokud je segment evidentně YouTube boilerplate („Děkuji za \
    sledování", „Titulky vytvořil…", „nezapomeňte se přihlásit k odběru"), URL artefakt, \
    nebo repetitivní smyčka stejného slova 3× a víc za sebou, nahraď text PRÁZDNÝM řetězcem \
    za dvojtečkou.

    CO ZACHOVEJ:
    - Anglické technické termy beze změny: deploy, endpoint, API, pull request, repository, \
    frontend, backend, commit, branch, merge, build, release, rollback. Code-switching CS/EN \
    je norma — NEPŘEKLÁDEJ je do češtiny.
    - Smysl a fakta. Nevymýšlej nový obsah, který v audio evidentně nezazněl. Pokud opravdu \
    nevíš, co tam mělo být, nech segment beze změny.
    - Identifikátor [N], jméno speakera, formát řádku.
    - Přesný počet řádků. Žádné slučování ani dělení segmentů.

    FORMÁT VÝSTUPU:
    Jen opravené řádky, jeden segment = jeden řádek. Žádný úvod, žádné komentáře, žádný markdown, \
    žádné backticks.

    KOMPLEXNÍ PŘÍKLAD:

    Vstup:
    [1] David: pošlu ti to na slack a pak udelame deploj
    [2] Lukáš: ten endpoint vraci 500 kdyz tam dam null
    [3] Mariana: já bysem to spíš zkusila přes git rebase
    [4] Petr: musíš odhlanit tu kacelař před tím než se to deplojne
    [5] David: ne bo svoji firmu, nebo svůj kacelař
    [6] Lukáš: stane vyměnil jenom tady jeden klíš
    [7] Speaker: Děkuji za sledování, nezapomeňte se přihlásit k odběru

    Výstup:
    [1] David: pošlu ti to na Slack a pak uděláme deploy
    [2] Lukáš: ten endpoint vrací 500, když tam dám null
    [3] Mariana: já bych to spíš zkusila přes git rebase
    [4] Petr: musíš odhlásit tu kancelář před tím, než se to deployne
    [5] David: nebo svoji firmu, nebo svoji kancelář
    [6] Lukáš: stačí vyměnit jenom tady tenhle klíč
    [7] Speaker:
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

    /// Parse the model's `[N] Speaker: text` response back into ordered texts. Returns one slot
    /// per expected segment: the new text if the line parsed cleanly, `nil` if that specific
    /// line was malformed (caller keeps the original for that index — per-segment graceful
    /// fallback so a single bad line doesn't void the whole chunk).
    private func parseResponse(_ response: String, expectedCount: Int) -> [String?] {
        var slots: [String?] = Array(repeating: nil, count: expectedCount)
        for rawLine in response.split(whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("["),
                  let close = line.firstIndex(of: "]") else { continue }
            let inside = line[line.index(after: line.startIndex)..<close]
            // Skip context-marker lines the model might echo back.
            guard inside != "ctx", let idx = Int(inside), idx >= 1, idx <= expectedCount else { continue }

            // After ']' the format is " SPEAKER: text". Mistral Nemo occasionally types ']'
            // instead of ':' (e.g. "[7] Speaker 1] nebo …") — accept either char as the
            // speaker→text separator so one malformed line doesn't waste the whole chunk's work.
            let afterBracket = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            guard let sep = afterBracket.firstIndex(where: { $0 == ":" || $0 == "]" }) else { continue }
            let text = afterBracket[afterBracket.index(after: sep)...].trimmingCharacters(in: .whitespaces)
            slots[idx - 1] = text
        }
        return slots
    }
}
