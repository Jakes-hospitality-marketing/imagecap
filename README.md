# ImageCap

Compress a batch of images so every one lands under a file size limit.

**→ [jakes-hospitality-marketing.github.io/imagecap](https://jakes-hospitality-marketing.github.io/imagecap/)**

Drop in images or a folder, pick a limit, download the results as a zip. Nothing to
install. Everything runs in the browser — images are never uploaded anywhere.

There is also a native macOS app in this repo, which came first. The web version
replaced it for day-to-day use; see [The Mac app](#the-mac-app) below.

## Why a size limit rather than a quality slider

Upload limits are hard ceilings — 2 MB here, 4 MB there — and a quality slider makes you
guess at them. ImageCap takes the ceiling as the input and works out the quality.

The presets sit just under the round numbers those limits are quoted as: **1.9 MB**,
**3.9 MB**, **900 KB**, **450 KB**. Platforms disagree about whether a megabyte is
1,000,000 or 1,048,576 bytes, so landing exactly on 2 MB risks a rejected upload. The
headroom costs nothing you can see. The custom field is taken literally — type 1.9, not 2.

## How it hits the size cap

Encoders take a *quality* number, not a byte target, so the app searches for the quality
that lands just under the cap. Size grows monotonically with quality, which makes this a
binary search — about eight encodes per image.

What gets sacrificed first depends on the image:

**JPEG, WebP, HEIC** — binary search on encoder quality at full resolution. If the cap
can't be met without dropping below the quality floor (0.40), the image is scaled down
and the search runs again. Past that floor, a smaller clean image reads better than a
full-size smeared one.

**PNG** is lossless, so quality isn't a dial. Two strategies, chosen by inspecting the
image:

- *Flat artwork* (logos, menus, screenshots, charts) — reduce the number of distinct
  colours and keep every pixel. A menu graphic survives this almost invisibly.
- *Photographs* — downscale instead. Posterising a photo bands badly on gradients, so
  pixels are the cheaper thing to give up.

The two are told apart by counting distinct colours in a sample: artwork reuses a small
set of colours, photographs almost never repeat one.

**The cap is a hard promise.** If an image is extreme enough that even a small version
can't meet it at decent quality, the quality floor is dropped rather than the file
failing.

## Formats

| Format | Read | Write |
|---|---|---|
| JPEG, PNG, WebP | ✅ | ✅ |
| GIF | ✅ | → PNG |
| AVIF, BMP, TIFF | ✅ | → JPEG |
| HEIC | Safari natively; elsewhere via a converter (see below) | → JPEG |

**HEIC** is Apple's iPhone photo format and only Safari decodes it directly. When another
browser meets one, ImageCap says so and offers two ways on: hand the page to Safari, or
convert in place. Converting pulls in a 1.3 MB WebAssembly decoder — loaded only at that
moment, so nobody who never touches a HEIC pays for it. It works, but it is markedly
slower than Safari's native path.

## Behaviour worth knowing

- **Originals are never touched.** Results download as a separate zip.
- **Already-small images pass through untouched** rather than being re-encoded, which
  would only lose quality for no gain.
- **EXIF rotation is baked into the pixels**, so phone photos don't come out sideways.
- **Transparency survives** resizing. Anything converted to JPEG is flattened onto white
  first, since JPEG has no alpha channel.
- **A resize is only reported when it's real.** The scale search keeps as many pixels as
  will fit, so it often lands a fraction under full size — 8126px becoming 8064px. That's
  a rounding artefact, not a downgrade, and it isn't labelled as one.

## Speed

Compression runs in Web Workers, four images at a time. This matters twice over: canvas
encoding is synchronous, so on the main thread it blocks the browser from painting and
the page appears frozen — no progress spinner could animate either, because it would
freeze along with everything else.

Measured on the live site: five 10 MB photos in **7.2 seconds**, with 871 animation
frames rendered during the run.

## The Mac app

A native SwiftUI app, in `Sources/`. Same algorithm, and still works — it's faster on very
large batches, reads HEIC without a converter, and can write AVIF and TIFF, none of which
browsers can do.

It is no longer the recommended way to use ImageCap, because getting an unsigned Mac app
onto other people's machines is genuinely awkward. That story, and the Gatekeeper
mechanics behind it, are in [DISTRIBUTION.md](DISTRIBUTION.md).

```bash
./build.sh        # universal .app in build/, needs only Xcode Command Line Tools
./release.sh 1.1  # build, tag, package, publish a GitHub release
```

The app checks GitHub for updates on launch and can replace itself. It references the
repository by its permanent numeric ID rather than `owner/name`: a renamed account frees
its old username for anyone to register, and an updater that replaces the running app
from a named URL would hand control of every installation to whoever claimed it.

## Layout

```
docs/
  index.html        the web app — UI, worker pool, zip download
  worker.js         the compression engine (format policy, searches, HEIC)
  heic2any.min.js   HEIC decoder, vendored, loaded only on demand
Sources/ImageCap/
  Engine.swift      format policy, quality/scale search, per-file pipeline
  Quantizer.swift   median-cut palette reduction, flat-artwork detection
  Models.swift      settings, results, formatting
  Batch.swift       parallel batch runner
  ContentView.swift UI
  Updater.swift     self-update against GitHub Releases
  App.swift         entry point
build.sh            builds the .app bundle
release.sh          cuts a release
install.sh          installs the Mac app from the latest release
```

`docs/` is served by GitHub Pages. Pushing to `main` deploys it; there is no build step.

## Licence

MIT. See [LICENSE](LICENSE).
