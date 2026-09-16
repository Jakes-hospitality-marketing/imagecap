# Storing and distributing ImageCap

Everything here is free.

## Where the code and builds live

**A GitHub repository, with builds attached to Releases.** Free, unlimited private
repos, 2 GB per release asset, full version history, and a stable download URL the app
can check against. Nothing else free gives you versioning, a changelog and a machine
-readable "what's the latest version" endpoint in one place.

Make the repo **public** if you want the install command to work without anyone signing
in. A private repo works too, but every download then needs a GitHub token, which is
more friction than this app is worth. There is nothing sensitive in the source.

Google Drive or Dropbox also work for handing out the file, but they give you no version
history, no release notes and no way for the app to know an update exists — and files
downloaded from them are quarantined (see below). Use GitHub.

## The Gatekeeper problem, and why the install method matters

The app is ad-hoc signed rather than notarized, because notarizing requires an Apple
Developer account at $99/yr.

macOS blocks unsigned apps, but **only when the file carries the `com.apple.quarantine`
extended attribute.** That flag is not applied by macOS to every download — it is
applied by the *downloading application*. Browsers, Mail, Messages, Slack and Google
Drive all set it. `curl` and URLSession do not.

Verified on macOS 26.6: `spctl -a -t exec` **rejects** this app bundle, and it still
launches normally after a `curl` + `ditto` round trip, because no quarantine flag was
ever attached.

Nothing in this project strips the quarantine flag from anything — the approach relies
only on never acquiring it. That is a deliberate line: stripping it would disable a real
protection for any file, including ones that should be blocked, whereas choosing a
transport that never sets it changes nothing about how macOS treats other software.

This matters more than it sounds, because on macOS 15+ Apple removed the old
right-click → Open bypass. A quarantined unsigned app now requires a trip through
System Settings → Privacy & Security → "Open Anyway" — **for every person, on every
update.** Installing by script skips that permanently.

The upshot is that *how* the app reaches a Mac matters more than anything about the app
itself. The options below are ordered by how little your team has to do.

## Getting it onto your team's Macs

### Best: deploy it through MDM (nobody touches anything)

If the Macs are centrally managed, this is the easiest route by a distance. Software
installed by an MDM system is installed by its management agent as root rather than
downloaded by a user, so the quarantine flag is never applied and Gatekeeper never
appears — even though the app is unsigned.

Hand whoever administers it the `ImageCap.pkg` that `./release.sh` produces. Most MDM
products take a `.pkg` under a "custom app" or "managed software" section.

The app appears in Applications. People open it. That is the whole experience.

If they would rather run a script than host a package, most MDM systems can execute a
shell script on enrolled Macs — `install.sh` does the job unchanged.

### DIY: shared folder plus a one-time unlock

Put `ImageCap.app` and `Install ImageCap - Read Me.txt` in a shared Google Drive folder.
Teammates drag the app to Applications, hit the Gatekeeper block once, and clear it
through System Settings → Privacy & Security → "Open Anyway". The read-me walks them
through it in plain language.

**Tested 2026-09-16: Google Drive does apply the quarantine flag.** Synced folders were
a plausible exception to that — apps copied from USB sticks and network shares are
[documented as unflagged](https://derflounder.wordpress.com/2012/11/20/clearing-the-quarantine-extended-attribute-from-downloaded-applications/)
— but Drive behaves like a download, so the block appears. Assume Dropbox does too
unless someone tests it.

What makes this acceptable anyway is that **the unlock is once per person, ever.** Future
versions arrive through the in-app updater, which fetches them with URLSession and is
therefore never flagged, so the block never reappears.

Two things that will trip people up:

- There is a **one-hour window**. "Open Anyway" only appears in System Settings for an
  hour after the blocked message. Miss it and they have to double-click the app again to
  re-trigger it.
- It must be the **desktop sync folder in Finder**. Downloading from drive.google.com in
  a browser works the same way but is a separate download, so they would hit the block
  again on a file they then have to find.

This only stays a one-time cost if `Updater.repo` is configured in the build you hand
out — see the ordering note below.

### If MDM is not an option: install it yourself, once per Mac

Copy `ImageCap.app` from your machine to theirs and drag it into `/Applications`. A copy
that travels by USB stick or a file share carries no quarantine flag, because your local
build never had one, so it opens by double-click with no warning. After that the app
updates itself and you never repeat this.

### What not to do

**Do not email, Slack, AirDrop, or link the app for download.** All of those apply the
quarantine flag, which on macOS 15+ means each person has to visit System Settings →
Privacy & Security → "Open Anyway", individually, on every update. AirDrop is included
here — it tags what it receives with `sharingd` and is treated exactly like a browser
download.

### The Terminal route (still available, for you)

```bash
curl -fsSL https://raw.githubusercontent.com/Jakes-hospitality-marketing/imagecap/main/install.sh | bash
```

Fetches the latest release, installs to `/Applications`, opens it. Useful on your own
machine and for anyone comfortable with it, but not something to ask a non-technical
team to do.

## Updates after that

Run `./release.sh 1.1` on your machine. Nothing is required of your team: the app checks
GitHub on launch, shows a banner when a newer version exists, and downloads and swaps
itself when they click **Update & Relaunch**. Because the app fetches the update itself,
no quarantine flag is applied and no prompt appears.

This is why the self-updater is worth having even with MDM in the picture — you can ship
a fix without filing a ticket with IT every time. Use MDM for the initial rollout, and
the in-app updater for everything after.

`release.sh` still produces a fresh `.pkg` each time, so you can also hand IT a new one
for anyone who joins later.

## Order matters: never hand out a build that cannot update itself

A build with `Updater.repo` empty **never checks for updates**. Distribute one of those
and the copies are frozen — the only way onto a version that self-updates is to hand the
app out a second time, and to make everyone repeat the Gatekeeper unlock.

The repo is now set to `Jakes-hospitality-marketing/imagecap`, so any build made from here on is
fine. The rule still applies to anything built before that.

## Rollout checklist

1. `./release.sh 1.0` — builds, tags, packages, publishes the release
2. Copy the fresh `build/ImageCap.app` and `Install ImageCap - Read Me.txt` into the
   shared Drive folder
3. Team drags the app to Applications and does the one-time unlock
4. From then on, `./release.sh 1.2` is the whole update process

## If you ever want to spend the $99

An Apple Developer account lets you sign with a Developer ID and notarize, after which
the app opens by double-click from any source, including email and Drive, with no
Terminal and no banner caveats. That is the only thing the money buys here — the app
itself would not change.
