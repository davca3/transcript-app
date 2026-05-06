# Skribent

Lokální macOS aplikace pro přepis nahrávek (cs/en) s automatickou diarizací mluvčích a re-identifikací podle dříve uložených hlasových vzorků.

- **ASR:** [WhisperKit](https://github.com/argmaxinc/WhisperKit) (Whisper large-v3 na Core ML)
- **Diarizace + speaker embedding:** [FluidAudio](https://github.com/FluidInference/FluidAudio) (pyannote na Core ML, native Swift)
- **LLM cleanup:** [MLX Swift](https://github.com/ml-explore/mlx-swift-lm) s lokálním Qwen 3.5 9B
- **UI:** SwiftUI, Apple Silicon, macOS deployment target nastaven v `project.yml`

Vše běží lokálně. Žádná data neopouštějí Mac.

## Požadavky

- Apple Silicon Mac (M1+) s ≥ 16 GB RAM
- Xcode 15 nebo novější
- Homebrew (kvůli `xcodegen`)

## Instalace

```bash
git clone https://github.com/davca3/transcript-app.git
cd transcript-app
./setup.sh
open Skribent.xcodeproj
```

`setup.sh` udělá:
1. Nainstaluje `xcodegen` přes Homebrew, pokud chybí.
2. Vygeneruje `Skribent.xcodeproj` z `project.yml`.

V Xcode pak ⌘R. **Při prvním spuštění** se na pozadí stáhnou modely:
- WhisperKit large-v3 (~1.5 GB)
- FluidAudio pyannote diarizace (~50 MB)
- Qwen 3.5 9B OptiQ 4-bit (~6 GB) — stáhne se až při prvním kliknutí na **Vyčistit přepis**

Banner v okně ukazuje průběh stahování.

## Build & test z příkazové řádky

```bash
# Vygenerovat projekt po změně project.yml
xcodegen generate

# Build
xcodebuild -project Skribent.xcodeproj -scheme Skribent -destination 'platform=macOS' build

# Spustit unit testy
xcodebuild -project Skribent.xcodeproj -scheme Skribent -destination 'platform=macOS' test
```

Test target `SkribentTests` pokrývá `Cosine`, `Clustering`, `SpeakerIdentifier`,
`RecordingArtifact.displayNames` a integration test pro `PipelineCoordinator`
(s mock `TranscriptionService` / `DiarizationService`).

## Použití

1. **Nová nahrávka** — klikni na ➕ vlevo nahoře.
   - **Nahrát z mikrofonu** — start/stop, po stopu se spustí pipeline.
   - **Nahrát i systémový zvuk** — vyžaduje povolení Screen Recording (TCC prompt při prvním zapnutí).
   - **Importovat soubor** — m4a, mp3, wav, flac, …
2. Pipeline projde fáze: **decode → enhance → transcribe + diarize (paralelně) → identify**. Indikátor postupu je nahoře v detailu.
3. V **detailu nahrávky** vidíš přepis se segmenty per mluvčí. Klik na timestamp přehraje danou pasáž.
4. Klik na **chip mluvčího** (Speaker 1, Speaker 2, …) → přejmenuj. Embeddingy se uloží do `~/Library/Application Support/Skribent/speakers.json`. Příští nahrávka rozpozná stejnou osobu automaticky.
5. **Vyčistit přepis** — pustí lokální Qwen 3.5 nad přepisem a opraví zjevné chyby rozpoznávání.
6. **Export** TXT / JSON / WAV přes tlačítko v detailu.

## Datové úložiště

```
~/Library/Application Support/Skribent/
├── recordings/
│   └── <uuid>/
│       ├── audio.wav         # 48k mono PCM, HPF + loudness-normalized
│       └── transcript.json   # segmenty + přiřazení mluvčích + per-cluster embeddingy
├── recordings.json           # index nahrávek
└── speakers.json             # DB známých mluvčích + embeddingy
```

Modely WhisperKitu cachovány v `~/Documents/huggingface/`, Qwen v `~/Library/Caches/huggingface/hub/`.

## Architektura

```
PipelineCoordinator
    ├─ AudioUtils.loadAndResample        → 48k mono Float32
    ├─ AudioUtils.applyHighPassFilter +
       AudioUtils.loudnessNormalize       → cleaned WAV (uloží se na disk)
    ├─ AudioUtils.trimToSpeech            → speech-only samples + offset map
    ├─ WhisperKitTranscriber  ─┐
                               ├─ paralelně, async let
    ├─ FluidAudioDiarizer     ─┘
    ├─ FluidAudioDiarizer.embed           → embedding per turn (cluster centroid)
    └─ SpeakerIdentifier                  → match s DB → name | "Speaker N"
```

Služby jsou za protokoly (`TranscriptionService`, `DiarizationService`,
`SpeakerEmbeddingService`) — implementace lze vyměnit zvenku přes
`AppState.init(pipelineTranscriber:pipelineDiarizer:pipelineEmbedder:)`.

## Práh pro re-identifikaci

Cosine similarity ≥ **0.55** = match. Změnit lze v `SpeakerIdentifier.matchThreshold`. Vyšší = striktnější (méně falešných shod, víc nových `Speaker N`).

## Logy

Aplikace loguje přes `os.Logger` se subsystémem `com.skribent.app` a kategoriemi
`pipeline`, `recorder`, `transcriber`, `diarizer`, `refiner`, `store`, `speaker`,
`app`, `player`, `systemAudio`. V Console.app filtruj `subsystem == com.skribent.app`.

## Známá omezení

- WhisperKit při prvním spuštění **stahuje model** ze sítě (~1.5 GB). Pak vše offline.
- Diarizace pyannote má v dlouhých tichých pasážích občasné split/merge chyby — manuální merge mluvčích je v UI (kliknutí na chip → vybrat existujícího mluvčího).
- LLM cleanup (Qwen 3.5 9B) má jednorázový download ~6 GB. Přeskočitelné, dokud uživatel neklikne **Vyčistit přepis**.
- Aplikace je v sandboxu — soubory mimo aplikační podporu otevírej přes file picker.

## Licence

MIT.
