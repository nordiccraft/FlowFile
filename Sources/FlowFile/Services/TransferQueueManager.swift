import Foundation
import Observation

enum TransferOperationType: String {
    case copy = "Kopiering"
    case move = "Flytting"
}

enum TransferJobStatus: Equatable {
    case queued
    case running
    case paused
    case completed
    case cancelled
    case failed(String)

    var label: String {
        switch self {
        case .queued: return "I kø"
        case .running: return "Kjører"
        case .paused: return "Pauset"
        case .completed: return "Fullført"
        case .cancelled: return "Avbrutt"
        case .failed(let msg): return "Feilet: \(msg)"
        }
    }
}

@Observable
final class TransferJob: Identifiable {
    let id = UUID()
    let operation: TransferOperationType
    let sourceURLs: [URL]
    let destinationDirectory: URL
    let createdAt = Date()

    var totalItems: Int
    var completedItems: Int = 0
    var currentFileName: String = ""
    var status: TransferJobStatus = .queued
    var createdDestinations: [URL] = []

    var progress: Double {
        guard totalItems > 0 else { return 1.0 }
        return min(1.0, Double(completedItems) / Double(totalItems))
    }

    init(operation: TransferOperationType, sourceURLs: [URL], destinationDirectory: URL) {
        self.operation = operation
        self.sourceURLs = sourceURLs
        self.destinationDirectory = destinationDirectory
        self.totalItems = sourceURLs.count
    }
}

@Observable
final class TransferQueueManager {
    var jobs: [TransferJob] = []
    var dropShelfItems: [URL] = []
    private var isProcessingQueue: Bool = false

    var activeJobsCount: Int {
        jobs.filter { $0.status == .running || $0.status == .queued || $0.status == .paused }.count
    }

    var onJobFinished: (([URL], URL) -> Void)?

    // MARK: - Drop Shelf ("Midlertidig kurv")

    func addToDropShelf(_ urls: [URL]) -> Int {
        var added = 0
        for url in urls.map(\.standardizedFileURL) {
            if !dropShelfItems.contains(url) && FileManager.default.fileExists(atPath: url.path) {
                dropShelfItems.append(url)
                added += 1
            }
        }
        return added
    }

    func removeFromDropShelf(_ url: URL) {
        dropShelfItems.removeAll(where: { $0 == url.standardizedFileURL })
    }

    func clearDropShelf() {
        dropShelfItems.removeAll()
    }

    // MARK: - Transfer Queue

    func enqueue(
        operation: TransferOperationType,
        urls: [URL],
        to destinationDirectory: URL
    ) {
        let validURLs = urls.map(\.standardizedFileURL)
        guard !validURLs.isEmpty else { return }
        let job = TransferJob(
            operation: operation,
            sourceURLs: validURLs,
            destinationDirectory: destinationDirectory.standardizedFileURL
        )
        jobs.insert(job, at: 0)
        processNextIfNeeded()
    }

    func togglePause(_ job: TransferJob) {
        if job.status == .running {
            job.status = .paused
        } else if job.status == .paused {
            job.status = .queued
            processNextIfNeeded()
        }
    }

    func cancel(_ job: TransferJob) {
        if job.status == .running || job.status == .queued || job.status == .paused {
            job.status = .cancelled
        }
    }

    func clearCompletedJobs() {
        jobs.removeAll { job in
            switch job.status {
            case .completed, .cancelled, .failed:
                return true
            default:
                return false
            }
        }
    }

    private func processNextIfNeeded() {
        guard !isProcessingQueue else { return }
        guard let nextJob = jobs.last(where: { $0.status == .queued }) else { return }

        isProcessingQueue = true
        nextJob.status = .running

        Task { @MainActor in
            await runJob(nextJob)
            self.isProcessingQueue = false
            self.processNextIfNeeded()
        }
    }

    @MainActor
    private func runJob(_ job: TransferJob) async {
        let startIdx = job.completedItems
        guard startIdx < job.sourceURLs.count else {
            job.status = .completed
            onJobFinished?(job.createdDestinations, job.destinationDirectory)
            return
        }

        for idx in startIdx..<job.sourceURLs.count {
            if job.status == .cancelled {
                return
            }
            if job.status == .paused {
                return
            }

            let src = job.sourceURLs[idx]
            job.currentFileName = src.lastPathComponent
            let destDir = job.destinationDirectory
            let op = job.operation

            do {
                let resultingURL = try await Task.detached(priority: .userInitiated) { () -> URL in
                    let fm = FileManager.default
                    if op == .move && src.deletingLastPathComponent().standardizedFileURL == destDir.standardizedFileURL {
                        return src
                    }
                    let target = FileSystemService.uniqueDestinationURL(for: src, in: destDir)
                    switch op {
                    case .copy:
                        try fm.copyItem(at: src, to: target)
                    case .move:
                        try fm.moveItem(at: src, to: target)
                    }
                    return target
                }.value

                job.createdDestinations.append(resultingURL)
                job.completedItems = idx + 1
            } catch {
                job.status = .failed(error.localizedDescription)
                return
            }
        }

        if job.status == .running {
            job.currentFileName = ""
            job.status = .completed
            onJobFinished?(job.createdDestinations, job.destinationDirectory)
        }
    }
}
