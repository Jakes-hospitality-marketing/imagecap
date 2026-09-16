import Foundation
import AppKit

/// Self-update against GitHub Releases.
///
/// The point of doing this in-app rather than telling people to re-download: the
/// quarantine flag that makes macOS block unsigned apps is applied by the *downloading*
/// application. Browsers, Mail and AirDrop set it; URLSession does not. So an update the
/// app fetches for itself is never flagged in the first place, and opens normally.
///
/// Note that nothing here strips quarantine from anything — it relies only on never
/// acquiring it. A copy someone downloads through a browser is still flagged, and still
/// needs System Settings → Privacy & Security, which is why install.sh exists.
enum Updater {

    /// Set this to your GitHub repo once it exists, as "owner/name".
    /// Updates are disabled while it is empty.
    static let repo = "Jakes-hospitality-marketing/imagecap"

    static var isConfigured: Bool { !repo.isEmpty }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    struct Release {
        let version: String
        let zipURL: URL
        let notes: String
    }

    // MARK: - Checking

    static func checkForUpdate() async -> Release? {
        guard isConfigured,
              let api = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")
        else { return nil }

        var req = URLRequest(url: api)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10

        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String
        else { return nil }

        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard isNewer(latest, than: currentVersion) else { return nil }

        // Prefer a .zip asset; that is what release.sh uploads.
        let assets = json["assets"] as? [[String: Any]] ?? []
        guard let asset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
              let urlString = asset["browser_download_url"] as? String,
              let zipURL = URL(string: urlString)
        else { return nil }

        return Release(version: latest, zipURL: zipURL, notes: json["body"] as? String ?? "")
    }

    /// Numeric component-wise comparison, so 1.10 correctly beats 1.9.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Applying

    enum UpdateError: LocalizedError {
        case download, unpack, notFound, swap

        var errorDescription: String? {
            switch self {
            case .download: return "Could not download the update."
            case .unpack:   return "The downloaded update could not be opened."
            case .notFound: return "The update did not contain an app."
            case .swap:     return "Could not replace the installed app."
            }
        }
    }

    /// Download, unpack, then hand off to a detached script that swaps the bundle once
    /// this process has exited — an app cannot replace itself while it is running.
    static func apply(_ release: Release) async throws -> Never {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("ImageCapUpdate-\(UUID().uuidString)")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)

        guard let (tmp, response) = try? await URLSession.shared.download(from: release.zipURL),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { throw UpdateError.download }

        let zip = work.appendingPathComponent("update.zip")
        try? fm.moveItem(at: tmp, to: zip)

        // ditto handles the archive format Finder and `zip -y` produce, preserving symlinks.
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, work.path]
        try? unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw UpdateError.unpack }

        let contents = (try? fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)) ?? []
        guard let newApp = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.notFound
        }

        let installed = Bundle.main.bundleURL
        let script = work.appendingPathComponent("swap.sh")
        let body = """
        #!/bin/bash
        # Wait for the running app to exit, then swap the bundle and relaunch.
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(installed.path)"
        mv "\(newApp.path)" "\(installed.path)"
        open "\(installed.path)"
        rm -rf "\(work.path)"
        """
        guard (try? body.write(to: script, atomically: true, encoding: .utf8)) != nil else {
            throw UpdateError.swap
        }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let run = Process()
        run.executableURL = URL(fileURLWithPath: "/bin/bash")
        run.arguments = [script.path]
        guard (try? run.run()) != nil else { throw UpdateError.swap }

        await MainActor.run { NSApp.terminate(nil) }
        // NSApp.terminate does not return, but the compiler needs a Never-typed tail.
        while true { try? await Task.sleep(nanoseconds: 1_000_000_000) }
    }
}
