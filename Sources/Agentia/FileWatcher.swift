import Foundation
import CoreServices

/// Watches a single file for changes, surviving the way agents actually write.
///
/// The trap this exists to avoid: almost nothing writes a file in place. Editors
/// and agent harnesses write a temporary file and rename it over the target,
/// which replaces the inode. A `DispatchSource` attached to the original file
/// descriptor goes deaf after exactly one regeneration — precisely when live
/// reload is supposed to start earning its keep.
///
/// So the watch is on the **containing directory**, with file-level events, and
/// the callback filters for the path. That survives atomic replacement, and it
/// is the same stream the folder list needs anyway.
final class FileWatcher {

    /// Events are coalesced over this window. FSEvents can report a single save
    /// as several events, and a re-render per event would flicker.
    static let debounceInterval: TimeInterval = 0.06

    private let fileURL: URL
    private let directoryURL: URL
    private let onChange: () -> Void
    private let queue: DispatchQueue

    private var stream: FSEventStreamRef?
    private var debounceWorkItem: DispatchWorkItem?

    /// - Parameters:
    ///   - fileURL: the document to watch.
    ///   - onChange: called on the main queue, already debounced.
    init(fileURL: URL, onChange: @escaping () -> Void) {
        // Resolve once so comparisons later are between resolved paths — /tmp
        // is a symlink to /private/tmp on macOS and FSEvents reports the
        // resolved form.
        self.fileURL = fileURL.resolvingSymlinksInPath()
        self.directoryURL = self.fileURL.deletingLastPathComponent()
        self.onChange = onChange
        self.queue = DispatchQueue(label: "app.agentia.filewatcher", qos: .utility)
    }

    deinit {
        stop()
    }

    var isRunning: Bool { stream != nil }

    func start() {
        guard stream == nil else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagFileEvents
            // Without this, a rename-over is reported against the directory and
            // the specific path is lost.
            | kFSEventStreamCreateFlagNoDefer
        )

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            eventCallback,
            &context,
            [directoryURL.path as CFString] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.0, // latency: coalescing is handled here, not by FSEvents
            flags
        ) else {
            NSLog("Agentia: could not create FSEventStream for \(directoryURL.path)")
            return
        }

        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            NSLog("Agentia: could not start FSEventStream for \(directoryURL.path)")
            return
        }

        stream = created
    }

    func stop() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil

        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    // MARK: - Event handling

    fileprivate func handle(paths: [String]) {
        let target = fileURL.path
        let matches = paths.contains { path in
            // FSEvents may report either the file or, for some replacement
            // patterns, the directory holding it.
            path == target
                || URL(fileURLWithPath: path).resolvingSymlinksInPath().path == target
        }
        guard matches else { return }

        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // A rename-over is briefly visible as a missing file. Reporting a
            // change for a file that is not there yet would blank the view, so
            // wait for the next event instead.
            guard FileManager.default.fileExists(atPath: self.fileURL.path) else { return }
            self.onChange()
        }
        debounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceInterval, execute: work)
    }
}

/// C callback trampoline. `info` is an unretained pointer to the watcher, which
/// is valid because `stop()` runs from `deinit` before the object goes away.
private func eventCallback(
    stream: ConstFSEventStreamRef,
    info: UnsafeMutableRawPointer?,
    count: Int,
    paths: UnsafeMutableRawPointer,
    flags: UnsafePointer<FSEventStreamEventFlags>,
    ids: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()

    guard let cfPaths = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
    watcher.handle(paths: cfPaths)
}
