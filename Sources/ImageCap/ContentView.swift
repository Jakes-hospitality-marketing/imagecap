import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var batch = Batch()
    @State private var customMB: String = ""
    @State private var limitDimension = false
    @State private var dimensionText = "2400"
    @State private var isTargeted = false
    @State private var update: Updater.Release?
    @State private var updating = false
    @State private var updateError: String?

    var body: some View {
        VStack(spacing: 0) {
            if let update { updateBanner(update) }
            settingsBar
            Divider()
            mainArea
            Divider()
            bottomBar
        }
        .frame(minWidth: 860, minHeight: 560)
        .onAppear {
            if batch.outputDir == nil {
                batch.outputDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            }
            Task { update = await Updater.checkForUpdate() }
        }
    }

    // MARK: - Update banner

    private func updateBanner(_ release: Updater.Release) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.white)
            Text("Version \(release.version) is available")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)

            if let updateError {
                Text("· \(updateError)")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.85))
            }

            Spacer()

            if updating {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                Text("Updating…")
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
            } else {
                Button("Update & Relaunch") {
                    updating = true
                    updateError = nil
                    Task {
                        do {
                            _ = try await Updater.apply(release)
                        } catch {
                            updating = false
                            updateError = error.localizedDescription
                        }
                    }
                }
                Button {
                    update = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.8))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Color.accentColor)
        .disabled(batch.isRunning)
    }

    // MARK: - Settings

    private var settingsBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text("Size limit")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                Picker("", selection: Binding(
                    get: { batch.settings.maxBytes },
                    set: { batch.settings.maxBytes = $0; customMB = "" }
                )) {
                    ForEach(Settings.presets, id: \.1) { name, bytes in
                        Text(name).tag(bytes)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
                .disabled(batch.isRunning)

                HStack(spacing: 6) {
                    Text("or")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    TextField("custom", text: $customMB)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                        .onChange(of: customMB) { v in
                            if let mb = Double(v), mb > 0 {
                                batch.settings.maxBytes = Int(mb * 1_000_000)
                            }
                        }
                    Text("MB")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .disabled(batch.isRunning)

                Spacer()
            }

            HStack(spacing: 14) {
                Toggle(isOn: $limitDimension) {
                    Text("Also limit longest edge to")
                        .font(.system(size: 12))
                }
                .toggleStyle(.checkbox)

                TextField("", text: $dimensionText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .disabled(!limitDimension)
                Text("px")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Spacer()

                Text("Save to")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Button {
                    batch.chooseOutputDir()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "folder")
                        Text(batch.outputDir?.lastPathComponent ?? "Choose folder…")
                            .lineLimit(1)
                    }
                }
                .disabled(batch.isRunning)
            }
            .disabled(batch.isRunning)
            .onChange(of: limitDimension) { _ in syncDimension() }
            .onChange(of: dimensionText) { _ in syncDimension() }
        }
        .padding(16)
    }

    private func syncDimension() {
        batch.settings.maxDimension = limitDimension ? Int(dimensionText).flatMap { $0 > 0 ? $0 : nil } : nil
    }

    // MARK: - Main area

    @ViewBuilder
    private var mainArea: some View {
        ZStack {
            if !batch.results.isEmpty {
                resultsList
            } else if batch.queued.isEmpty {
                dropZone
            } else {
                queueList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .dropDestination(for: URL.self) { urls, _ in
            batch.add(urls)
            return true
        } isTargeted: { isTargeted = $0 }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(6)
            }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Drop images or folders here")
                .font(.system(size: 17, weight: .medium))
            Text("JPEG · PNG · HEIC · TIFF · GIF · WebP · AVIF")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button("Choose files…") { chooseFiles() }
                .padding(.top, 4)
            if let err = batch.lastError {
                Text(err)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
        }
    }

    private var queueList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(batch.queued.count) image\(batch.queued.count == 1 ? "" : "s") ready")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Clear") { batch.clear() }
                    .buttonStyle(.link)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            List(batch.queued, id: \.self) { url in
                HStack {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                    Text(url.lastPathComponent)
                        .font(.system(size: 12))
                    Spacer()
                    Text(url.deletingLastPathComponent().lastPathComponent)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .listStyle(.plain)
        }
    }

    private var resultsList: some View {
        VStack(spacing: 0) {
            HStack {
                if let dir = batch.lastRunDir {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.secondary)
                    Text(dir.lastPathComponent)
                        .font(.system(size: 12, weight: .semibold))
                } else {
                    Text("Results")
                        .font(.system(size: 12, weight: .semibold))
                }
                Spacer()
                if let dir = batch.lastRunDir {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([dir])
                    }
                    .buttonStyle(.link)
                }
                Button("Start over") { batch.clear() }
                    .buttonStyle(.link)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            List(batch.results) { r in
                ResultRow(result: r)
            }
            .listStyle(.plain)
        }
    }

    // MARK: - Bottom

    private var bottomBar: some View {
        HStack(spacing: 14) {
            if batch.isRunning {
                ProgressView(value: batch.progress)
                    .frame(width: 180)
                Text("\(batch.completed) of \(batch.total)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else if !batch.results.isEmpty {
                Text("\(formatBytes(batch.totalOriginalBytes)) → \(formatBytes(batch.totalFinalBytes))")
                    .font(.system(size: 12, weight: .medium))
                if batch.overallSaved > 0 {
                    Text("saved \(Int(batch.overallSaved * 100))%")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                }
                let over = batch.results.filter { $0.treatment == .failed }.count
                if over > 0 {
                    Text("· \(over) failed")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }
            }

            Spacer()

            Button {
                batch.run()
            } label: {
                Text(batch.isRunning ? "Compressing…" : "Compress \(batch.queued.count) image\(batch.queued.count == 1 ? "" : "s")")
                    .frame(minWidth: 150)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(batch.isRunning || batch.queued.isEmpty || batch.outputDir == nil)
        }
        .padding(16)
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { batch.add(panel.urls) }
    }
}

// MARK: - Row

struct ResultRow: View {
    let result: Result

    private var tint: Color {
        switch result.treatment {
        case .failed:    return .red
        case .resized:   return .orange
        case .converted: return .blue
        default:         return .green
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: result.treatment == .failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.source.lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(result.treatment.label)
                    if result.finalPixels != result.originalPixels && result.treatment != .failed {
                        Text("· \(result.originalPixels.w)×\(result.originalPixels.h) → \(result.finalPixels.w)×\(result.finalPixels.h)")
                    }
                    if let n = result.note {
                        Text("· \(n)")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()

            if result.treatment != .failed {
                HStack(spacing: 8) {
                    Text(formatBytes(result.originalBytes))
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text(formatBytes(result.finalBytes))
                        .fontWeight(.semibold)
                    if result.saved > 0.005 {
                        Text("−\(Int(result.saved * 100))%")
                            .foregroundStyle(.green)
                            .frame(width: 44, alignment: .trailing)
                    } else {
                        Text("").frame(width: 44)
                    }
                }
                .font(.system(size: 12).monospacedDigit())
            }
        }
        .padding(.vertical, 3)
    }
}
