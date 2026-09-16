import Foundation
import SwiftUI
import AppKit

@MainActor
final class Batch: ObservableObject {
    @Published var queued: [URL] = []
    @Published var results: [Result] = []
    @Published var isRunning = false
    @Published var completed = 0
    @Published var outputDir: URL?
    @Published var settings = Settings()
    @Published var lastError: String?

    /// The folder actually created for the most recent run, inside `outputDir`.
    @Published var lastRunDir: URL?

    var total: Int { queued.count }

    var progress: Double {
        total == 0 ? 0 : Double(completed) / Double(total)
    }

    var totalOriginalBytes: Int { results.reduce(0) { $0 + $1.originalBytes } }
    var totalFinalBytes: Int { results.reduce(0) { $0 + $1.finalBytes } }

    var overallSaved: Double {
        let o = totalOriginalBytes
        guard o > 0 else { return 0 }
        return max(0, 1.0 - Double(totalFinalBytes) / Double(o))
    }

    func add(_ urls: [URL]) {
        let found = Engine.expand(urls)
        guard !found.isEmpty else {
            lastError = "No supported images found in what you dropped."
            return
        }
        lastError = nil
        var seen = Set(queued.map(\.standardized.path))
        for u in found where seen.insert(u.standardized.path).inserted {
            queued.append(u)
        }
    }

    func clear() {
        queued = []
        results = []
        completed = 0
        lastError = nil
        lastRunDir = nil
    }

    func run() {
        guard !isRunning, !queued.isEmpty, let parent = outputDir else { return }

        // Each run gets its own folder inside the chosen destination, named for the cap it
        // used. Keeps repeat runs from mingling, and means the user hands off one folder.
        let label = "Compressed \(formatBytes(settings.maxBytes))"
        guard let outDir = Engine.makeUniqueDirectory(in: parent, named: label) else {
            lastError = "Could not create a folder in \(parent.lastPathComponent)."
            return
        }

        isRunning = true
        lastRunDir = outDir
        results = []
        completed = 0
        lastError = nil

        let files = queued
        let settings = self.settings

        Task.detached(priority: .userInitiated) {
            // Large images are memory-hungry — a 36-megapixel decode is ~150 MB of RGBA —
            // so cap parallelism rather than letting every core hold one at once.
            let lanes = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))

            await withTaskGroup(of: Result.self) { group in
                var next = 0
                var running = 0

                func launch(_ i: Int) {
                    group.addTask {
                        Engine.process(files[i], settings: settings, outputDir: outDir)
                    }
                }

                while next < files.count && running < lanes {
                    launch(next); next += 1; running += 1
                }

                while let r = await group.next() {
                    await MainActor.run {
                        self.results.append(r)
                        self.completed += 1
                    }
                    if next < files.count {
                        launch(next); next += 1
                    }
                }
            }

            await MainActor.run {
                // Surface the images that needed the most destructive treatment.
                self.results.sort { $0.treatment > $1.treatment }
                self.isRunning = false
            }
        }
    }

    func chooseOutputDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Where should the compressed images go?"
        if panel.runModal() == .OK { outputDir = panel.url }
    }
}
