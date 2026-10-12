import AppKit
import Darwin
import Foundation

private struct ArchiveJob {
    let folder: URL
    let archive: URL
    let estimatedBytes: Int64
}

private enum ArchiveError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}

private final class ArchiveEngine {
    private let fileManager = FileManager.default
    private let processLock = NSLock()
    private var activeProcesses: [Process] = []
    private var cancellationRequested = false

    var isCancelled: Bool {
        processLock.lock()
        defer { processLock.unlock() }
        return cancellationRequested
    }

    func cancel() {
        processLock.lock()
        cancellationRequested = true
        let processes = activeProcesses
        processLock.unlock()
        for process in processes where process.isRunning {
            process.terminate()
        }
    }

    private func setActiveProcesses(_ processes: [Process]) {
        processLock.lock()
        activeProcesses = processes
        let shouldCancel = cancellationRequested
        processLock.unlock()
        if shouldCancel {
            for process in processes where process.isRunning {
                process.terminate()
            }
        }
    }

    private func pvPath() throws -> String {
        let pathEntries = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        let candidates = ["/opt/homebrew/bin/pv", "/usr/local/bin/pv"]
            + pathEntries.map { $0 + "/pv" }
        if let path = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return path
        }
        throw ArchiveError.message("The pv utility is required. Install it with: brew install pv")
    }

    private func pathExists(_ path: String) -> Bool {
        if fileManager.fileExists(atPath: path) { return true }
        return (try? fileManager.destinationOfSymbolicLink(atPath: path)) != nil
    }

    private func unusedArchiveURL(for folder: URL) -> URL {
        let base = folder.path
        var candidate = URL(fileURLWithPath: base + ".tar.gz")
        var suffix = 2
        while pathExists(candidate.path) {
            candidate = URL(fileURLWithPath: base + "-\(suffix).tar.gz")
            suffix += 1
        }
        return candidate
    }

    private func estimatedTarBytes(for folder: URL) throws -> Int64 {
        var total: Int64 = 1_536 // Root directory header and two end blocks.
        func add(_ value: Int64) throws {
            let (sum, overflow) = total.addingReportingOverflow(value)
            if overflow { throw ArchiveError.message("Folder is too large to estimate.") }
            total = sum
        }
        var scanError: Error?
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, error in
                scanError = error
                return false
            }
        ) else {
            throw ArchiveError.message("Cannot read folder: \(folder.path)")
        }

        for case let item as URL in enumerator {
            if isCancelled { throw ArchiveError.message("Cancelled") }
            let values = try item.resourceValues(forKeys: Set(keys))
            try add(512)
            if values.isRegularFile == true {
                let size = Int64(values.fileSize ?? 0)
                if size > Int64.max - 511 {
                    throw ArchiveError.message("File is too large to estimate: \(item.lastPathComponent)")
                }
                let padded = ((size + 511) / 512) * 512
                try add(padded)
            }
        }
        if let scanError { throw scanError }
        return max(total, 1)
    }

    func prepare(paths: [String]) throws -> [ArchiveJob] {
        guard !paths.isEmpty else {
            throw ArchiveError.message("Select a folder in Finder, then choose Create tar.gz with Progress.")
        }
        return try paths.map { path in
            let folder = URL(fileURLWithPath: path).standardizedFileURL
            if folder.path == "/" {
                throw ArchiveError.message("Select a folder rather than the startup volume.")
            }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw ArchiveError.message("Not a folder: \(folder.path)")
            }
            return ArchiveJob(
                folder: folder,
                archive: unusedArchiveURL(for: folder),
                estimatedBytes: try estimatedTarBytes(for: folder)
            )
        }
    }

    func create(
        jobs: [ArchiveJob],
        onStatus: @escaping (String) -> Void,
        onProgress: @escaping (Int64, Int64) -> Void
    ) throws -> ([URL], Int64) {
        let pv = try pvPath()
        let totalEstimate = jobs.reduce(Int64(0)) { $0 + $1.estimatedBytes }
        var completedActual: Int64 = 0
        var results: [URL] = []

        for job in jobs {
            if isCancelled { throw ArchiveError.message("Cancelled") }
            onStatus("Compressing \(job.folder.lastPathComponent)")
            let actualBytes = try createOne(job: job, pv: pv) { bytes in
                onProgress(completedActual + bytes, totalEstimate)
            }
            completedActual += actualBytes
            onProgress(completedActual, totalEstimate)
            results.append(job.archive)
        }
        return (results, completedActual)
    }

    private func createOne(
        job: ArchiveJob,
        pv: String,
        onBytes: @escaping (Int64) -> Void
    ) throws -> Int64 {
        let partial = job.archive.deletingLastPathComponent()
            .appendingPathComponent(".\(job.archive.lastPathComponent).partial-\(UUID().uuidString)")
        let errorLog = fileManager.temporaryDirectory
            .appendingPathComponent("tar-utility-\(UUID().uuidString).log")
        guard fileManager.createFile(atPath: partial.path, contents: nil) else {
            throw ArchiveError.message("Cannot create the archive beside \(job.folder.lastPathComponent).")
        }
        defer {
            try? fileManager.removeItem(at: partial)
            try? fileManager.removeItem(at: errorLog)
            setActiveProcesses([])
        }
        guard fileManager.createFile(atPath: errorLog.path, contents: nil) else {
            throw ArchiveError.message("Cannot create a temporary error log.")
        }

        let outputHandle = try FileHandle(forWritingTo: partial)
        let errorHandle = try FileHandle(forWritingTo: errorLog)
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
        }

        let tarToPv = Pipe()
        let pvToGzip = Pipe()
        let progressPipe = Pipe()

        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-cf", "-", "-C", job.folder.deletingLastPathComponent().path,
                         "./" + job.folder.lastPathComponent]
        tar.standardOutput = tarToPv
        tar.standardError = errorHandle

        let meter = Process()
        meter.executableURL = URL(fileURLWithPath: pv)
        meter.arguments = ["--numeric", "--bytes", "--interval", "0.25"]
        meter.standardInput = tarToPv
        meter.standardOutput = pvToGzip
        meter.standardError = progressPipe

        let gzip = Process()
        gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gzip.arguments = ["-c"]
        gzip.standardInput = pvToGzip
        gzip.standardOutput = outputHandle
        gzip.standardError = errorHandle

        var started: [Process] = []
        do {
            try gzip.run(); started.append(gzip)
            try meter.run(); started.append(meter)
            try tar.run(); started.append(tar)
        } catch {
            for process in started where process.isRunning { process.terminate() }
            for process in started { process.waitUntilExit() }
            throw error
        }
        setActiveProcesses([tar, meter, gzip])

        tarToPv.fileHandleForWriting.closeFile()
        tarToPv.fileHandleForReading.closeFile()
        pvToGzip.fileHandleForWriting.closeFile()
        pvToGzip.fileHandleForReading.closeFile()
        progressPipe.fileHandleForWriting.closeFile()

        var latestBytes: Int64 = 0
        var pending = Data()
        let reader = progressPipe.fileHandleForReading
        var buffer = [UInt8](repeating: 0, count: 4096)
        var readFailed = false
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(reader.fileDescriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                readFailed = true
                for process in [tar, meter, gzip] where process.isRunning {
                    process.terminate()
                }
                break
            }
            pending.append(contentsOf: buffer.prefix(count))
            while let newline = pending.firstIndex(of: 10) {
                let line = pending.prefix(upTo: newline)
                pending.removeSubrange(...newline)
                if let text = String(data: line, encoding: .utf8),
                   let bytes = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    latestBytes = bytes
                    onBytes(bytes)
                }
            }
        }
        reader.closeFile()

        tar.waitUntilExit()
        meter.waitUntilExit()
        gzip.waitUntilExit()
        if isCancelled { throw ArchiveError.message("Cancelled") }
        if readFailed { throw ArchiveError.message("Could not read progress updates.") }
        guard tar.terminationStatus == 0,
              meter.terminationStatus == 0,
              gzip.terminationStatus == 0 else {
            let details = (try? String(contentsOf: errorLog, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ArchiveError.message(details.isEmpty ? "Archive creation failed." : details)
        }

        if pathExists(job.archive.path) {
            throw ArchiveError.message("Archive appeared while processing: \(job.archive.lastPathComponent)")
        }
        try fileManager.moveItem(at: partial, to: job.archive)
        return latestBytes
    }
}

private final class TarUtilityApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let engine = ArchiveEngine()
    private let paths = Array(CommandLine.arguments.dropFirst())
    private var window: NSWindow!
    private var titleLabel: NSTextField!
    private var detailLabel: NSTextField!
    private var processedLabel: NSTextField!
    private var etaLabel: NSTextField!
    private var progressBar: NSProgressIndicator!
    private var actionButton: NSButton!
    private var finished = false
    private var lastSample: (bytes: Int64, time: TimeInterval)?
    private var smoothedRate = 0.0

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            runArchives()
        }
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 246),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Create tar.gz"
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        let content = window.contentView!

        titleLabel = NSTextField(labelWithString: "Preparing archive…")
        titleLabel.font = NSFont.boldSystemFont(ofSize: 16)
        titleLabel.frame = NSRect(x: 24, y: 191, width: 492, height: 24)
        content.addSubview(titleLabel)

        detailLabel = NSTextField(labelWithString: "Scanning selected folders")
        detailLabel.frame = NSRect(x: 24, y: 163, width: 492, height: 20)
        detailLabel.lineBreakMode = .byTruncatingMiddle
        content.addSubview(detailLabel)

        progressBar = NSProgressIndicator(frame: NSRect(x: 24, y: 128, width: 492, height: 20))
        progressBar.isIndeterminate = true
        progressBar.style = .bar
        progressBar.startAnimation(nil)
        content.addSubview(progressBar)

        processedLabel = NSTextField(labelWithString: "Calculating data size…")
        processedLabel.frame = NSRect(x: 24, y: 95, width: 492, height: 20)
        content.addSubview(processedLabel)

        etaLabel = NSTextField(labelWithString: "Time remaining: calculating…")
        etaLabel.frame = NSRect(x: 24, y: 70, width: 492, height: 20)
        content.addSubview(etaLabel)

        actionButton = NSButton(title: "Cancel", target: self, action: #selector(buttonPressed))
        actionButton.frame = NSRect(x: 420, y: 20, width: 96, height: 30)
        content.addSubview(actionButton)
    }

    private func runArchives() {
        do {
            let jobs = try engine.prepare(paths: paths)
            DispatchQueue.main.async { [self] in
                progressBar.stopAnimation(nil)
                progressBar.isIndeterminate = false
                progressBar.minValue = 0
                progressBar.maxValue = 100
                progressBar.doubleValue = 0
                titleLabel.stringValue = jobs.count == 1 ? "Creating archive" : "Creating \(jobs.count) archives"
            }
            let (archives, processedBytes) = try engine.create(
                jobs: jobs,
                onStatus: { [self] status in
                    DispatchQueue.main.async { [self] in detailLabel.stringValue = status }
                },
                onProgress: { [self] bytes, total in
                    DispatchQueue.main.async { [self] in updateProgress(bytes: bytes, total: total) }
                }
            )
            DispatchQueue.main.async { [self] in
                finished = true
                progressBar.doubleValue = 100
                titleLabel.stringValue = "Archive complete"
                detailLabel.stringValue = archives.count == 1
                    ? archives[0].lastPathComponent
                    : "\(archives.count) archives created beside their folders"
                processedLabel.stringValue = "100% • \(formatBytes(processedBytes)) processed"
                etaLabel.stringValue = "Time remaining: 0 seconds"
                actionButton.title = "Done"
            }
        } catch {
            DispatchQueue.main.async { [self] in
                finished = true
                progressBar.stopAnimation(nil)
                progressBar.isIndeterminate = false
                titleLabel.stringValue = engine.isCancelled ? "Cancelled" : "Archive failed"
                detailLabel.stringValue = error.localizedDescription
                processedLabel.stringValue = "No incomplete archive was kept."
                etaLabel.stringValue = ""
                actionButton.title = "Close"
                actionButton.isEnabled = true
            }
        }
    }

    private func updateProgress(bytes: Int64, total: Int64) {
        guard !finished else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let prior = lastSample, now > prior.time, bytes > prior.bytes {
            let instantRate = Double(bytes - prior.bytes) / (now - prior.time)
            smoothedRate = smoothedRate == 0 ? instantRate : (smoothedRate * 0.7 + instantRate * 0.3)
        }
        lastSample = (bytes, now)

        let fraction = total > 0 ? min(Double(bytes) / Double(total), 0.99) : 0
        progressBar.doubleValue = max(0, fraction * 100)
        processedLabel.stringValue = "\(Int(fraction * 100))% • \(formatBytes(bytes)) processed of about \(formatBytes(total))"
        let remaining = max(total - bytes, 0)
        if smoothedRate > 0 && remaining > 0 {
            etaLabel.stringValue = "Estimated time remaining: \(formatDuration(Double(remaining) / smoothedRate))"
        } else if remaining == 0 {
            etaLabel.stringValue = "Finalizing archive…"
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(bytes, 0), countStyle: .file)
    }

    private func formatDuration(_ duration: Double) -> String {
        let seconds = Int(max(1, min(duration.rounded(.up), 359_999)))
        if seconds < 60 { return seconds == 1 ? "1 second" : "\(seconds) seconds" }
        if seconds < 3_600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m"
    }

    @objc private func buttonPressed() {
        if finished {
            NSApp.terminate(nil)
        } else {
            actionButton.isEnabled = false
            detailLabel.stringValue = "Cancelling…"
            engine.cancel()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if finished { return true }
        buttonPressed()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }
}

if CommandLine.arguments.dropFirst().first == "--headless" {
    let engine = ArchiveEngine()
    do {
        let jobs = try engine.prepare(paths: Array(CommandLine.arguments.dropFirst(2)))
        let (archives, _) = try engine.create(
            jobs: jobs,
            onStatus: { print($0) },
            onProgress: { _, _ in }
        )
        for archive in archives { print(archive.path) }
        Darwin.exit(0)
    } catch {
        fputs(error.localizedDescription + "\n", stderr)
        Darwin.exit(1)
    }
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = TarUtilityApp()
    app.delegate = delegate
    app.run()
}
