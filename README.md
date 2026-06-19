# Voice Studio

An iOS voice recording & post-production studio built with **Swift, SwiftUI and
AVFoundation (AVAudioEngine)**. Designed for vocalists, Islamic poem reciters
(Anasheed) and Qur'anic-recitation *soundscape* emulation.

Targets **iOS 16+, iPhone + iPad**.

## Features

- **High-fidelity capture** — low-latency recording to 24-bit/48 kHz WAV with a
  real-time rolling waveform and a live monitoring path.
- **Cleanup** — low-cut/high-pass (80–100 Hz) and a configurable noise gate.
- **DSP effect presets** in four tuned categories:
  - *General* — parametric EQ (warmth/presence/air) + de-esser.
  - *Singers* — smooth compression, plate reverb, stereo delay.
  - *Anasheed* — lush hall reverb with subtle ensemble doubling.
  - *Qur'an (Grand Mosque)* — long "Haram" reverb with pre-delay, multi-tap echo,
    and mid-range clarity EQ so recitation stays legible through the space.
- **Wet/dry + intensity** controls; per-stage enable toggles.
- **Dual-track montage timeline** — vocal + background bed, non-destructive
  trim/split/rearrange, per-track volume/mute/solo, importable background audio.
- **Mixdown & export** — offline render of the exact effect graph to **WAV** or
  **M4A (AAC)**, with reverb tails preserved, plus system share sheet.

## Architecture

The single source of truth is the Codable `Project` (`Track` → `Clip` →
`AudioSource`) and each track's `EffectChainSpec`. Views and view models never
touch `AVAudioNode`s — they mutate the spec and call services. `ChainBuilder`
turns one spec into fresh node graphs for each of three engine modes (live
monitor, playback, offline mixdown), guaranteeing identical processing in
preview and export.

```
Models / EffectChainSpec  ──►  ChainBuilder  ──►  AVAudioEngine graphs
        (source of truth)                          (live / playback / offline)
```

Effects are pluggable `AudioProcessingNode`s in an ordered chain. The mapping of
each effect to its concrete `AVAudioUnit` (and the native-gap workarounds for
de-esser / convolution reverb / multi-tap delay / formant pitch) lives in
`Audio/Nodes/`.

### Phase-2 ML voice conversion (extension point)

Every preset reserves a disabled **`PassthroughNode`** at the
`.mlVoiceConversion` slot (after the noise gate, before tonal EQ). To add neural
voice conversion later, implement an `MLVoiceConversionNode: AudioProcessingNode`
that exposes a `renderBlock` (bridging a CoreML model via `AVAudioSourceNode`)
and swap it in at that slot — no other code changes required. The recorded source
is kept clean (effects are non-destructive), so it can be re-processed by the ML
stage at any time.

## Project layout

```
VoiceStudio/
  App/            entry point, DI container, project-editing operations
  Audio/Engine/   session, engine controller, ChainBuilder, recording, playback, mixdown
  Audio/Nodes/    AudioProcessingNode protocol + concrete effect nodes + ML slot
  Audio/Effects/  EffectChainSpec, PresetLibrary
  Audio/Analysis/ waveform sampling + analysis
  Models/         Project, Track, Clip, AudioSource
  Persistence/    ProjectStore (JSON)
  ViewModels/     Recorder, Timeline
  Views/          Recorder, Timeline, Effects, Export, Components
VoiceStudioTests/ model & preset unit tests
```

## Build & run

The Xcode project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
xcodegen generate
open VoiceStudio.xcodeproj
```

Or from the command line:

```bash
# Build
xcodebuild -project VoiceStudio.xcodeproj -scheme VoiceStudio \
  -destination 'platform=iOS Simulator,name=iPhone 16' build

# Test
xcodebuild -project VoiceStudio.xcodeproj -scheme VoiceStudio \
  -destination 'platform=iOS Simulator,name=iPhone 16' test
```

> Note: microphone input on the Simulator uses the Mac's mic; test true capture
> latency and effects on a physical device.

## Known native-API limitations (Phase-2 candidates)

AVFoundation has no native de-esser, convolution/IR reverb, multi-tap delay, or
formant-preserving pitch. Phase 1 bridges these (narrow dynamic cut, cathedral +
pre-delay, feedback delay, TimePitch). Phase 2 can replace them with custom AUv3
units (e.g. a Haram impulse-response convolution reverb) — again, just new
`AudioProcessingNode` conformers.
# Audio-Studio
