# QingTing (清听)

English | [简体中文](README.zh-CN.md)

<img src="Design/AppIcon-mac-1024.png" width="128" alt="QingTing icon">

QingTing captures sound with the microphone of a Mac or an iPhone, removes noise in real time so that mostly speech is left, and streams the result to MFi hearing aids over Bluetooth. It was built for sitting in a classroom and listening to a teacher who is far away.

All processing happens on the device. Nothing is sent over the network.

> QingTing is not a medical device. It does not replace a hearing aid fitting and makes no promise of improving hearing. The output is limited, but start at a low volume.

The app's user interface is in Chinese.

## Features

- **Choice of noise reduction engines**: DeepFilterNet 3 (default, works for distant speech), a low-latency DeepFilterNet variant, RNNoise, Apple voice isolation (two modes), or none
- **Auto tuning**: once a second it analyzes the last 8 seconds of capture, estimates the speech SNR and the high-frequency balance, and sets noise reduction strength and clarity
- **Auto volume**: measures loudness only while someone is speaking and evens out speech that gets louder and quieter, without boosting the noise floor during pauses
- **Clarity**: emphasizes consonants above 2 kHz
- **Save the last 30 seconds**: stores both the raw capture and the processed audio for troubleshooting
- **iPhone app**: keeps working with the screen locked; shows the listening state in the Dynamic Island and on the Lock Screen with a Stop button; stops automatically when the hearing aids disconnect so the speaker cannot howl
- **Offline comparison tool**: runs a recording through every engine and outputs audio files and metrics

## Signal path

```
microphone -> 250 Hz low cut -> noise reduction -> clarity EQ -> auto volume -> compressor -> limiter -> hearing aids
```

- When capture is not at 48 kHz (some iPhones only deliver 16 kHz once hearing aids are connected), the audio is upsampled by an integer factor to 48 kHz before noise reduction
- Noise reduction runs on its own real-time priority thread, connected to the audio device callbacks through lock-free ring buffers whose margin adapts to dropouts

## Layout

| Path | Contents |
|---|---|
| `Sources/Shared` | Shared by both platforms: engine wrappers, processing chain, auto volume, scene analysis, ring buffer, waveform view |
| `Sources/Mac` | Mac app: audio devices, two-engine pipeline, UI, offline tool |
| `Sources/iOS` | iPhone app: audio session, pipeline, UI, Live Activity control |
| `Sources/Widget`, `Sources/LiveActivity` | Dynamic Island / Lock Screen Live Activity |
| `Patches` | Changes to DeepFilterNet (as a patch) and the pinned dependency versions |
| `Design` | The icon and the code that draws it |

## Building

Requires an Apple silicon Mac, Xcode, Rust (`rustup`) and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
# 1. Prepare the third-party noise reduction libraries (download, patch, build; once; about 3 GB)
./setup-deps.sh

# 2. Mac app, output in build/清听.app
./build.sh

# 3. iPhone app: put your developer team ID in local.env first
echo 'QINGTING_TEAM_ID=<your team ID>' > local.env
./install-ios.sh      # builds and installs on the connected iPhone
```

Notes for the iPhone app:

- Sign in with your Apple ID under Xcode > Settings > Accounts. Apps signed with a free account have to be reinstalled every 7 days
- After the phone has been paired once over USB, it can also be installed wirelessly when the Mac and the phone are on the same local network (for example the phone's Personal Hotspot)
- The bundle identifier is set in `project.yml` (`PRODUCT_BUNDLE_IDENTIFIER`); change it to your own

## Command line

The Mac executable has two modes that need no UI:

```bash
APP=build/清听.app/Contents/MacOS/QingTing

# Offline comparison: process a recording with each engine, write WAV files and print metrics
$APP --offline recording.wav --out outdir [--mode classroom] [--strength 0.5] [--engines deepFilter,rnnoise]

# Live self-test: run for a few seconds and print levels, buffering and glitch counts (plays audio to the output device)
$APP --selftest 5 [--engine deepFilter] [--in "microphone name"] [--out "output device name"]
```

Logs: `~/Library/Logs/QingTing.log` on the Mac; on the iPhone, in the Files app under On My iPhone > 清听.

## Known limitations

- Latency: about 120-130 ms on the Mac and 80-100 ms on the iPhone (omnidirectional microphone). If the hearing aids' own microphones are also active, the two copies of the sound overlap; lowering the ambient microphone level during streaming in the hearing aid app helps
- Single-microphone noise reduction mostly improves listening comfort. With a distant teacher in a noisy room, the gain in intelligibility is limited
- Directional microphone modes on the iPhone measured quieter and duller, with about 30 ms more latency; they are off by default
- The waveform in the Dynamic Island refreshes once a second (the system does not allow third-party apps to animate continuously there)

## Third-party

- [DeepFilterNet](https://github.com/Rikorose/DeepFilterNet) (MIT / Apache-2.0): noise reduction model and inference library; this project adds a gain release smoothing patch
- [RNNoise](https://github.com/xiph/rnnoise) (BSD-3-Clause)
- Apple `AUSoundIsolation`: the system voice isolation unit

## License

The code of this project is released under the [MIT License](LICENSE). Third-party libraries are used under their own licenses, listed above.
