import Foundation
import MetricKit
import os

/// Receives Apple's MetricKit payloads and keeps the useful part.
///
/// MetricKit is the only free source of OOM kills, watchdog terminations and
/// hang diagnostics on macOS — data no in-process crash handler can see,
/// because the process is already gone by then. Payloads arrive from Apple at
/// most daily, and only from devices whose users share analytics with Apple.
///
/// This deliberately does not phone anything home: payloads are logged to the
/// unified log and archived under Application Support so a user (or a bug
/// report) can attach them. If remote crash reporting ever gets added, this
/// class is where the upload hook goes.
final class MetricsReporter: NSObject, MXMetricManagerSubscriber {

    private static let log = Logger(subsystem: "app.agentia", category: "metrics")

    /// Keep the newest diagnostics; older ones are deleted. Crash JSONs are
    /// small, but nothing bounds what Apple sends over an app's lifetime.
    /// ponytail: fixed cap of 20 files, raise if triage ever needs more history
    private static let maximumArchivedPayloads = 20

    static func start() {
        MXMetricManager.shared.add(MetricsReporter())
    }

    // MARK: - MXMetricManagerSubscriber

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            Self.log.info("received metrics payload covering \(payload.timeStampBegin, privacy: .public) – \(payload.timeStampEnd, privacy: .public)")
        }
        // Daily summaries have no actionable per-crash content; the log line is
        // enough until something specific hurts.
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let crashes = payload.crashDiagnostics?.count ?? 0
            let hangs = payload.hangDiagnostics?.count ?? 0
            let cpu = payload.cpuExceptionDiagnostics?.count ?? 0
            Self.log.fault("diagnostic payload: \(crashes) crashes, \(hangs) hangs, \(cpu) cpu exceptions")
            archive(payload)
        }
        pruneArchive()
    }

    // MARK: - Archive

    private var archiveDirectory: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                     in: .userDomainMask).first else { return nil }
        let dir = support.appendingPathComponent("Agentia/diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes the raw JSON so it can be attached to a bug report verbatim.
    private func archive(_ payload: MXDiagnosticPayload) {
        guard let dir = archiveDirectory else { return }
        let data = payload.jsonRepresentation()
        let stamp = ISO8601DateFormatter().string(from: payload.timeStampEnd)
            .replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("diagnostic-\(stamp).json")
        try? data.write(to: url, options: .atomic)
    }

    private func pruneArchive() {
        guard let dir = archiveDirectory,
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let jsons = files.filter { $0.pathExtension == "json" }
        guard jsons.count > Self.maximumArchivedPayloads else { return }
        let sorted = jsons.sorted(by: {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
                < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
        })
        for old in sorted.prefix(jsons.count - Self.maximumArchivedPayloads) {
            try? FileManager.default.removeItem(at: old)
        }
    }
}
