# Skribent

Lokální macOS aplikace pro přepis nahrávek (cs/en) s automatickou diarizací mluvčích a re-identifikací podle dříve uložených hlasových vzorků.

- **ASR:** [WhisperKit](https://github.com/argmaxinc/WhisperKit) (Whisper Turbo na Core ML)
- **Diarizace + speaker embedding:** [FluidAudio](https://github.com/FluidInference/FluidAudio) (pyannote na Core ML, native Swift)
- **UI:** SwiftUI, macOS 14+, Apple Silicon

Vše běží lokálně. Žádná data neopouštějí Mac.

## Požadavky

- macOS 14 (Sonoma) nebo novější
- Apple Silicon (M1+)
- Xcode 15+
- Homebrew (pro `xcodegen`)

## Instalace

```bash
git clone <repo> transcript-app
cd transcript-app
./setup.sh
open Skribent.xcodeproj
```

`setup.sh` udělá:
1. Nainstaluje `xcodegen` (přes Homebrew, pokud chybí).
2. Vygeneruje `Skribent.xcodeproj` z `project.yml`.

V Xcode pak ⌘R. **Při prvním spuštění** se na pozadí stáhnou modely:
- WhisperKit Whisper Turbo (~600 MB)
- FluidAudio pyannote diarizace (~50 MB)

Banner v okně ti ukáže průběh.

## Použití

1. **Nová nahrávka** — klikni na ➕ vlevo nahoře.
   - **Nahrát z mikrofonu** — start/stop, po stopu se spustí pipeline.
   - **Importovat soubor** — m4a, mp3, wav, flac, …
2. Pipeline projde fáze: **decode → transcribe → diarize → identify**. Indikátor postupu je nahoře.
3. V **detailu nahrávky** vidíš přepis se segmenty per mluvčí. Klik na timestamp přehraje danou pasáž.
4. Klik na **chip mluvčího** (Speaker 1, Speaker 2, …) → přejmenuj. Embeddingy se uloží do `~/Library/Application Support/Skribent/speakers.json`. Příští nahrávka rozpozná stejnou osobu automaticky.
5. **Export** TXT nebo JSON přes tlačítko v detailu.

## Datové úložiště

```
~/Library/Application Support/Skribent/
├── recordings/
│   └── <uuid>/
│       ├── audio.wav         # 16k mono PCM (zdroj pro pipeline)
│       ├── original.<ext>    # původní soubor (pokud import)
│       └── transcript.json   # segmenty + přiřazení mluvčích
└── speakers.json             # DB známých mluvčích + embeddingy
```

## Architektura

```
PipelineCoordinator
    ├─ AudioImporter / AudioRecorder   → 16k mono PCM
    ├─ WhisperKitTranscriber           → text + timestamps
    ├─ SherpaDiarizer                  → speaker turns (start, end, clusterId)
    ├─ SherpaEmbedder                  → embedding per turn
    └─ SpeakerIdentifier               → match s DB → name | "Speaker N"
```

Služby jsou za protokoly (`TranscriptionService`, `DiarizationService`, `SpeakerEmbeddingService`) — implementace lze vyměnit bez doteku UI.

## Práh pro re-identifikaci

Cosine similarity > **0.75** = match. Změnit lze v `SpeakerIdentifier.matchThreshold`. Vyšší = striktnější (méně falešných shod, víc nových `Speaker N`).

## Známá omezení

- WhisperKit při prvním spuštění **stahuje model** ze sítě (cca 1.5 GB). Pak vše offline.
- Diarizace pyannote má v dlouhých tichých pasážích občasné split/merge chyby — manuální merge mluvčích je v UI.
- Aplikace je v sandboxu — soubory mimo aplikační podporu otevírej přes file picker.

## Licence

MIT (autor projektu zvolí).
