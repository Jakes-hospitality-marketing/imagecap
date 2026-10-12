# Distributing ImageCap

## The web app

Nothing to do. `docs/` is served by GitHub Pages, so pushing to `main` deploys it:

**https://jakes-hospitality-marketing.github.io/imagecap/**

Send people the link. There is no install, no version to chase, no per-machine setup —
everyone has the current build the moment you push one. Free, and the images never leave
the user's device, so there is no hosting cost or privacy question either.

If Pages ever needs re-enabling: repo **Settings → Pages → Deploy from a branch →
`main` / `/docs`**.

Deploys take a minute or two. Verify with the files, not just the page, since a stale
cache can serve an old `index.html` against new assets:

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://jakes-hospitality-marketing.github.io/imagecap/worker.js
```

---

The rest of this file is about the **native Mac app**, which the web version replaced.
It is kept because the app still exists and the Gatekeeper mechanics were expensive to
work out — but none of it applies to the web app, and none of it is work your team has
to do any more.

## Why distributing the Mac app is hard

The app is ad-hoc signed rather than notarized, because notarizing requires an Apple
Developer account at $99/yr.

macOS blocks unsigned apps, but **only when the file carries the `com.apple.quarantine`
extended attribute** — and that flag is applied by the *downloading application*, not by
macOS universally. Browsers, Mail, Slack, AirDrop and Google Drive all set it. `curl`,
URLSession, MDM agents and plain file copies do not.

Verified on macOS 26.6: `spctl -a -t exec` **rejects** the bundle, and it still launches
normally after a `curl` + `ditto` round trip, because no quarantine flag was ever
attached.

Nothing in this project strips the flag from anything — the approach relies only on never
acquiring it. Stripping it would disable a real protection for every file, including ones
that should be blocked; choosing a transport that never sets it changes nothing about how
macOS treats other software.

This matters because macOS 15 removed the old right-click → Open bypass. A quarantined
unsigned app now needs System Settings → Privacy & Security → "Open Anyway", **per
person, per download**.

## What we learned the hard way

Three rollout attempts failed, and none of them were the app's fault:

- **Never put a raw `.app` in Google Drive.** A Mac application is a directory, so Drive
  syncs it as a browsable folder. A teammate opened `Info.plist` from inside the bundle
  and got a screen of XML. Ship a **zip**: one file, which expands back into a working
  bundle with permissions and signature intact.
- **The Gatekeeper dialog has two variants.** A Chrome download produces "cannot be opened
  because it is from an unidentified developer" with a single **OK** button — not the
  "Apple could not verify…" / Done / Move to Trash dialog in Apple's documentation.
  Instructions that name the wrong button stop people cold.
- **Don't name the instructions file "Install …"** — it reads as an installer and gets
  double-clicked first, which opens a text editor and looks like a failure.
- Finder sync folder versus browser download makes **no difference**; Drive quarantines
  either way.
- There is a **one-hour window** on the "Open Anyway" button after the blocked message.

## Routes that work

**MDM**, if the Macs are centrally managed — software installed by a management agent as
root is never quarantined, so Gatekeeper never appears. Hand whoever administers it the
`ImageCap.pkg` from `./release.sh`.

**A copy you make yourself**, from a USB stick or a file share. A copy of a build that was
never quarantined has no flag to inherit, so it opens with no warning at all.

**The install script**, for anyone comfortable in a terminal. It fetches the release with
`curl`, so the result is unflagged:

```bash
curl -fsSL https://raw.githubusercontent.com/Jakes-hospitality-marketing/imagecap/main/install.sh | bash
```

**A zip plus written instructions**, as a last resort — workable, but it costs each person
a one-time trip through System Settings.

**Don't** email, Slack, AirDrop or link the `.app` for download. All of those quarantine it.

## Updates to the Mac app

`./release.sh 1.1` builds, tags, packages and publishes. Installed copies see a banner and
replace themselves. Because the app fetches the update itself, no quarantine flag is
applied and no prompt appears — which is what kept the Gatekeeper unlock a one-time cost
rather than a recurring one.

A build with no repository configured never checks for updates, so never hand one out.

## If you ever want to spend the $99

An Apple Developer account allows signing with a Developer ID and notarizing, after which
the app opens by double-click from any source with no warnings and no instructions. That
is the only thing the money buys — the app itself would not change.

With the web version in place, there is no longer much reason to.
