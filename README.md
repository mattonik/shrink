# Shrink

A small macOS app that turns big videos into small MP4s. Drop files in, pick a
size, click Shrink.

It is a thin native front end over `ffmpeg` — the point is to get HandBrake's
everyday job done on a machine where you cannot install HandBrake.

## Why this builds when HandBrake will not install

Apps downloaded from the internet get a `com.apple.quarantine` flag, and
Gatekeeper blocks them unless they are notarised and you have the rights to
approve them. An app you compile yourself never gets that flag, and
`~/Applications` is your own folder, so no admin password is involved anywhere.

## Install

Needs Xcode (or the Swift toolchain) and ffmpeg:

```bash
brew install ffmpeg
```

Then build and install to `~/Applications`:

```bash
./build.sh
```

Open it from Spotlight or the Finder, and drag it to the Dock if you want it
there. To install somewhere else, pass a folder: `./build.sh /Applications`.

## Using it

Drop videos onto the window (or press ⌘O). For each file it shows resolution,
length and current size. Pick your settings, click **Shrink**, and the converted
files land **next to the originals** with the settings in the name —
`demo.mp4` becomes `demo-720p.mp4`, or `demo-720p-muted.mp4` with sound off.
Originals are never touched.

| Control        | What it does                                                        |
| -------------- | ------------------------------------------------------------------- |
| **Resolution** | Keep original, 1080p, 720p, 480p, or 75% / 50%. Never upscales.      |
| *(portrait)*   | Presets size the **shorter** side, so 720p is 1280×720 landscape or 720×1280 portrait. |
| **Quality**    | Smallest / Balanced / High — a CRF ladder, constant quality per frame. |
| **Keep sound** | Off drops the audio track entirely (`-an`).                          |
| **HEVC**       | H.265 instead of H.264: roughly 30–50% smaller, needs a recent player. |

Conversions run one at a time — x264 already uses every core, so a queue is
faster than fighting over the CPU. **Cancel** stops the current file and deletes
its half-written output.

### Which settings should I use?

For screen recordings and instructional videos, **720p + Balanced** is usually
the sweet spot: large text stays readable and files come out several times
smaller. Drop to **480p** for something that only needs to play in a small
embedded player. Leave **HEVC off** if you are sending the file to someone else
and do not know what they will open it with.

## How it works

`ffmpeg -crf` is a constant-quality encode: the bitrate floats so every frame
hits the same quality target, which suits screen recordings where long stretches
barely change. The app also:

- refuses to upscale, and rounds both axes to even numbers so `yuv420p` chroma
  subsampling is valid
- reads the rotation from a file's display matrix and sizes from the dimensions
  you actually see. Phones store portrait video as landscape frames plus a 90°
  flag, and ffmpeg applies that rotation before any filter runs — sizing from
  the stored dimensions squashes portrait clips into a landscape frame. The
  rotation is baked into the output pixels, so the result needs no flag to
  display correctly anywhere
- tags HEVC output as `hvc1`, without which QuickTime and Safari will not play it
- writes `+faststart` so the file can begin playing before it is fully downloaded
- keeps any soft subtitle track that the source carried
- looks for ffmpeg in `/opt/homebrew/bin` and `/usr/local/bin` explicitly,
  because an app launched from the Finder gets a minimal `PATH` that has neither

## Development

```bash
swift build          # debug build
swift test           # unit + real-ffmpeg integration tests
swift run Shrink     # run without installing
./build.sh           # release build, bundle, install to ~/Applications
./make-icon.swift    # regenerate Resources/AppIcon.icns
```

- `Sources/ShrinkCore` — settings, ffmpeg argument building, probing, progress
  parsing. No UI, fully covered by tests.
- `Sources/Shrink` — SwiftUI app and the conversion queue.

The integration tests generate real clips with ffmpeg and convert them, then
re-probe the output to confirm the resolution and audio really changed. They
skip themselves automatically when ffmpeg is not installed.
