# Shrink

[![CI](https://github.com/mattonik/shrink/actions/workflows/ci.yml/badge.svg)](https://github.com/mattonik/shrink/actions/workflows/ci.yml)

A small macOS app that turns big videos into small MP4s and big PDFs into small
PDFs. Drop files in, pick a size, click Shrink.

It is a thin native front end over `ffmpeg` and Ghostscript. The point is to do
HandBrake's everyday job, and Preview's "Reduce File Size" job properly, on a
machine where you cannot install HandBrake.

## Install

Shrink needs ffmpeg for videos and Ghostscript for PDFs. Either one on its own
is enough for that kind of file:

```bash
brew install ffmpeg ghostscript
```

**From a release:** download `Shrink.zip` from
[Releases](https://github.com/mattonik/shrink/releases), unzip it and move
`Shrink.app` to the Applications folder in your home folder. Releases are signed
with a Developer ID and notarised by Apple, so Gatekeeper opens them normally.

**From source:** needs Xcode or the Swift toolchain.

```bash
./build.sh
```

This builds, signs ad-hoc, and installs to `~/Applications`; pass a folder to
install somewhere else. An app compiled on your own Mac never gets the
quarantine flag that Gatekeeper checks, and `~/Applications` is your own folder,
so no admin password is involved at any point. Use this if your Mac's
management blocks downloaded apps. A copy built this way updates itself by
building each new release from source.

## Using it

Drop files onto the window, onto Shrink's Dock icon, or use **Open With →
Shrink** in the Finder, or press ⌘O. Each file shows its size before you start.
Pick your settings and click **Shrink**. Converted files land **next to the
originals** with the settings in the name, and originals are never touched.

### Videos

`demo.mp4` becomes `demo-720p.mp4`, or `demo-720p-muted.mp4` with sound off.

| Control        | What it does                                                        |
| -------------- | ------------------------------------------------------------------- |
| **Resolution** | Keep original, 1080p, 720p, 480p, or 75% / 50%. Never upscales.      |
| *(portrait)*   | Presets size the **shorter** side, so 720p is 1280×720 landscape or 720×1280 portrait. |
| **Quality**    | Smallest / Balanced / High: a CRF ladder, constant quality per frame. |
| **Keep sound** | Off drops the audio track entirely (`-an`).                          |
| **HEVC**       | H.265 instead of H.264: roughly 30–50% smaller, needs a recent player. |

For screen recordings, **720p + Balanced** is usually the sweet spot: text stays
readable and files come out several times smaller. Leave **HEVC off** if you are
sending the file to someone and do not know what they will open it with.

A video that is already compact can come out barely smaller, or even bigger,
and the re-encode still costs quality. So, as with PDFs, **a result that saves
less than 10% is thrown away** and the row says "Kept original". A copy with the
sound turned off is always kept, because the original still has its sound.

### PDFs

`report.pdf` becomes `report-ebook.pdf`. The **Images** preset sets the
resolution embedded images are downsampled to: Screen 72 dpi, Ebook 150 dpi or
Print 300 dpi.

Savings depend on what is inside. Scans and image-heavy decks shrink a lot. A
real 18-page report went from 8.1 MB to 745 KB with no visible difference on
screen. PDFs exported from Word are mostly text and barely shrink, so **a result
that saves less than 10% is thrown away** and the row says "Kept original".

Some PDFs are left untouched, and Shrink says why on the row:

- **Digitally signed:** any rewrite would invalidate the signature.
- **Password-protected:** the copy would lose its protection.
- **With fillable form fields:** Ghostscript deletes them outright.

If Ghostscript had to repair a damaged file, the result is kept but flagged
with a warning to check it before sending it on.

Conversions run one at a time. x264 and Ghostscript already use the machine
well, so a queue finishes sooner than running them all at once. **Cancel** stops
the current file and leaves nothing half-written behind. A file that already has
the output's name is only ever replaced by a finished result, so a cancelled or
failed run leaves it alone.

Closing the window mid-run keeps Shrink converting, and the Dock icon brings the
window back. Quitting mid-run asks first, then stops the current file properly.
While converting, Shrink keeps the Mac from going to sleep on its own.

## Updates

Shrink checks GitHub at most once a day and shows a banner when a newer release
is out. **Shrink → Check for Updates…** asks on demand. **Update & Relaunch**
updates a copy the same way it was installed. Both ways follow published
releases, not every commit to `main`, so a copy only ever updates to code that
passed CI.

### A downloaded release

It downloads the next release and installs it only after all of these checks
pass:

1. The download matches its published SHA-256.
2. It has the same bundle ID, the version the release claims, and is newer than
   what is installed.
3. It carries a valid Developer ID signature from the team in `release.conf`,
   checked against Apple's own Developer ID requirement.
4. Gatekeeper accepts it, which for a Developer ID app means Apple has
   notarised it.

The checksum only proves the download is intact, since it comes from the same
place as the zip. Proving that the build came from this project is the job of
the signature and notarisation checks. If any check fails, nothing is changed.

### A copy you built with `build.sh`

It builds the next release on your Mac, as `git pull && ./build.sh` would, and
downloads nothing pre-built, so it works wherever building by hand works:

1. It fetches the release's tag into its own clone in
   `~/Library/Application Support/Shrink/Source`. Your own checkout is never
   touched.
2. It runs that tag's `build.sh` into a scratch folder.
3. It swaps the result in only if it is Shrink at the version the release
   names.

It needs Xcode or the Command Line Tools, and a build takes seconds rather than
minutes. The clone and its build cache take about 75 MB. A failed build changes
nothing. **Details…** on the banner shows everything the build printed, which is
also kept in `update-build.log` next to the clone. There is
no signature to check: as when building by hand, you are trusting what the tag
contains.

`build.sh` records which kind of copy it made: an ad-hoc signed build updates
from source, and a Developer ID build downloads. To build a copy that never
checks for updates, leave `REPOSITORY` empty in `release.conf`.

## Releasing

Pushing a `v*` tag makes the CI workflow:

1. Run the full test suite.
2. Sign the app with your Developer ID and the hardened runtime.
3. Notarise and staple it.
4. Run the updater's own verifier against that exact build.
5. Publish `Shrink.zip` and its checksum as a GitHub release.

```bash
git tag v1.0.0
git push origin v1.0.0
```

### One-time setup

1. **Team ID.** Set `TEAM_ID` in `release.conf` to the 10-character ID shown at
   developer.apple.com → Account → Membership. It is public; it appears in
   every app the team signs.
2. **Developer ID certificate.** Create one in Xcode → Settings → Accounts →
   Manage Certificates → **+** → *Developer ID Application*. Then export it with
   its private key from Keychain Access as a `.p12` with a password.
3. **Notarisation key.** In App Store Connect → Users and Access → Integrations
   → Team Keys, generate a key with *Developer* access and download the `.p8`.
   It can only be downloaded once.
4. **Repository secrets.** Add these under Settings → Secrets and variables →
   Actions. `base64 -i <file> | pbcopy` puts a file on the clipboard.

   | Secret                      | Value                                     |
   | --------------------------- | ----------------------------------------- |
   | `DEVELOPER_ID_P12_BASE64`   | the `.p12`, base64-encoded                |
   | `DEVELOPER_ID_P12_PASSWORD` | the password you exported it with         |
   | `NOTARY_KEY_P8_BASE64`      | the `.p8`, base64-encoded                 |
   | `NOTARY_KEY_ID`             | the key's ID, from App Store Connect      |
   | `NOTARY_ISSUER_ID`          | the Issuer ID shown above the keys table  |

The secrets are only exposed to the release job, which only runs for tags
pushed to this repository. Pull requests from forks never see them.

## How it works

**Video:** `ffmpeg -crf` is a constant-quality encode. The bitrate floats so
every frame hits the same quality target, which suits screen recordings where
long stretches barely change. The app also:

- refuses to upscale, and rounds both axes to even numbers so `yuv420p` chroma
  subsampling is valid. That includes a size it keeps: a recording of part of
  the screen can be 1437×899, and x264 refuses odd sides outright.
- reads the rotation from a file's display matrix and sizes from the dimensions
  you actually see. Phones store portrait video as landscape frames plus a 90°
  flag, and ffmpeg applies that rotation before any filter runs, so sizing from
  the stored dimensions would squash portrait clips into a landscape frame.
- tags HEVC output as `hvc1`, without which QuickTime and Safari will not play it
- writes `+faststart` so the file can start playing before it has fully
  downloaded
- keeps text subtitle tracks the source carried, such as SRT or WebVTT. The
  picture subtitles on DVDs and Blu-rays can't become MP4 text, so those are
  left out rather than failing the whole file.

**PDF:** Ghostscript's `pdfwrite` with `-dPDFSETTINGS` presets, plus:

- `-dAutoRotatePages=/None`, because by default pdfwrite turns pages to match
  their text direction and can flip a landscape table onto its side
- `%` doubled in the output path. Ghostscript reads a bare `%d` as a
  page-number template and would split the document into one file per page.
- output written to a scratch file first, replacing the destination only once
  the result is kept, so a rejected, failed or cancelled run never touches a
  file already there
- stderr checked for repairs, because Ghostscript exits successfully even after
  rebuilding a damaged file

Both tools are found in `/opt/homebrew/bin` and `/usr/local/bin` explicitly. An
app launched from the Finder gets a minimal `PATH` that contains neither.

## Development

```bash
swift build          # debug build
swift test           # unit and integration tests (real ffmpeg and Ghostscript)
swift run Shrink     # run without installing
./build.sh           # release build, bundle, install to ~/Applications
./build.sh dist      # the same, into ./dist, as CI does
./make-icon.swift    # regenerate Resources/AppIcon.icns
```

- `Sources/ShrinkCore`: video and PDF engines, the process runner and both
  updaters. No UI.
- `Sources/Shrink`: the SwiftUI app, the conversion queue and the update banner.
- `Sources/ShrinkTestSupport`: generates real test videos and PDFs, including
  signed, password-protected, form and damaged ones. Never linked into the app.

The integration tests convert real files and then inspect the output, rather
than trusting argument strings. They skip themselves when the tool they need
isn't installed. Every safeguard has a test that was checked to fail when the
safeguard was removed.

Updating from source is tested against a local git repository with a stand-in
`build.sh`. One test builds the real app from a tagged clone of this
repository, in the bare environment an app opened from the Finder gets. It
compiles everything from scratch, so it only runs when asked, and only sees
committed changes:

```bash
SHRINK_SOURCE_BUILD=1 swift test --filter buildsTheRealAppFromSource
```
