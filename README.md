# ImageCap

A Mac app that compresses batches of images to a hard file-size limit.

Drop in images or folders, set a cap (1.9 MB, 3.9 MB, or custom), pick a destination.
Each run creates its own folder there — `Compressed 1.9 MB/` — containing the results.
Every image comes out under the cap at the highest quality that fits. Originals are
never modified.

The presets sit just under the round numbers those limits are quoted as. An upload cap
of "2 MB" is a hard ceiling, and platforms disagree about whether a megabyte is
1,000,000 or 1,048,576 bytes, so landing at exactly 2 MB risks a rejected upload. The
headroom costs nothing visible. The custom field is taken literally — type 1.9, not 2.

## Building

```bash
./build.sh
```

Requires only the Xcode Command Line Tools — no Node, no Homebrew, no dependencies.
Produces a universal `build/ImageCap.app` (~1 MB) that runs on Apple Silicon and Intel.

## Installing on a teammate's Mac

The app is ad-hoc signed, not notarized. macOS 15+ blocks unsigned apps that carry the
`com.apple.quarantine` flag, and the old right-click-to-Open bypass no longer exists —
the only way through is System Settings → Privacy & Security → "Open Anyway", per
person, per update.

The way around this costs nothing: **quarantine is applied by the downloading app, not
by macOS universally.** Browsers, Mail and Slack set it; `curl` and URLSession do not.
An app installed by script therefore opens normally, even though `spctl` would reject
it. So don't email the app around — install it with the one-liner in
[DISTRIBUTION.md](DISTRIBUTION.md), which fetches the latest release, installs it to
`/Applications` and opens it. Re-running the same command updates it.

Set `REPO` in `install.sh` and `Updater.repo` in `Sources/ImageCap/Updater.swift` to
your GitHub repo first — update checks stay disabled until you do.

## Shipping an update

```bash
./release.sh 1.1
```

Builds, tags, zips and publishes a GitHub release (uses `gh` if installed, otherwise it
prints the manual upload steps). Everyone running the app sees a banner on next launch
and clicks "Update & Relaunch" — the app downloads the new version itself, so there is
no quarantine flag and no Gatekeeper prompt.

## How it hits the size cap

Encoders take a *quality* setting, not a byte target, so the app searches for the
quality that lands just under the cap. Size increases monotonically with quality, which
makes this a binary search — about 8 encodes per image.

The order in which quality is sacrificed depends on the image:

**JPEG, HEIC, AVIF** — binary search on encoder quality at full resolution. If the cap
can't be met without dropping below the quality floor (default 0.40), the image is
scaled down instead and the search runs again. Past that floor a smaller clean image
looks better than a full-size smeared one.

**PNG** is lossless, so quality isn't a dial. Two different strategies, chosen by
inspecting the image:

- *Flat artwork* (logos, menus, screenshots, charts) — reduce the colour palette via
  median-cut quantisation, keeping every pixel. A 256-colour menu graphic is visually
  identical to the original and a fraction of the size.
- *Photographs* — downscale instead. Posterising a photo causes obvious banding on
  gradients, so pixels are the cheaper thing to give up.

The two are told apart by counting distinct colours in a sample: artwork reuses a small
set of colours, photographs almost never repeat one.

**TIFF, GIF** — lossless re-encode, then downscale if needed.

**WebP** — macOS can decode WebP but cannot encode it. These come out as JPEG, or PNG if
the image has transparency, and are flagged in the results list.

## Behaviour worth knowing

- **Originals are never touched.** Output always goes to the folder you choose.
- **Nothing is overwritten.** A name collision becomes `photo-2.jpg`, and a second run
  at the same cap creates `Compressed 1.9 MB 2/` rather than merging into the first.
- **Already-small images are copied through** untouched rather than re-encoded, which
  would only lose quality for no gain.
- **EXIF rotation is baked into the pixels.** Metadata is stripped on write, so phone
  photos would otherwise come out sideways.
- **Transparency is preserved** through resizing. JPEG can't carry alpha, so any image
  converted to JPEG is flattened onto white first.
- **The cap is a hard promise.** If an image is extreme enough that even a small version
  can't meet the cap at decent quality, the quality floor is dropped rather than failing.

## Layout

```
Sources/ImageCap/
  Engine.swift      format policy, quality/scale search, per-file pipeline
  Quantizer.swift   median-cut palette reduction, flat-artwork detection
  Models.swift      settings, results, formatting
  Batch.swift       parallel batch runner (capped at 4 concurrent decodes)
  ContentView.swift UI
  App.swift         entry point
build.sh            builds the .app bundle
```

`Engine` and `Quantizer` have no UI dependencies, so the same compression logic can be
reused by a CLI or a Slack bot later without changes.
