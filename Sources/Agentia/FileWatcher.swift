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

    /// `stream` and `debounceWorkItem` are touched from the watcher queue (via
    /// the callback) and from the main thread (start/stop), so they need a lock
    /// rather than bare access.
    private let stateLock = NSLock()
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

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stream != nil
    }

    func start() {
        stateLock.lock()
        let alreadyRunning = stream != nil
        stateLock.unlock()
        guard !alreadyRunning else { return }

        // The stream retains a small box, not the watcher.
        //
        // passUnretained(self) was unsafe: callbacks arrive asynchronously on a
        // background queue and FSEventStreamInvalidate does not join one that
        // is already executing, so the callback could resurrect a deallocating
        // object. passRetained(self) fixes that but creates a cycle — the
        // stream would keep the watcher alive and deinit could never run.
        //
        // A box retained by the stream and holding the watcher weakly gets
        // both: deinit still fires, and a callback racing with deallocation
        // reads a weak reference that Swift has already zeroed, so it sees nil
        // and returns.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(WatcherBox(self)).toOpaque(),
            retain: nil,
            release: { pointer in
                guard let pointer else { return }
                Unmanaged<WatcherBox>.fromOpaque(pointer).release()
            },
            copyDescription: nil
        )

        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
            // FileEvents is what yields per-file paths rather than directory
            // granularity — without it a rename-over is reported against the
            // directory and the specific path is lost.
            | kFSEventStreamCreateFlagFileEvents
            // NoDefer makes the first event in a burst fire immediately rather
            // than after the latency timer. Latency is 0 here and coalescing is
            // done in handle(paths:), so this only removes a needless delay.
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

        stateLock.lock()
        stream = created
        stateLock.unlock()
    }

    func stop() {
        stateLock.lock()
        let doomed = stream
        stream = nil
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        stateLock.unlock()

        guard let doomed else { return }
        FSEventStreamStop(doomed)
        // Detach the queue before invalidating so no further callbacks are
        // scheduled while teardown is in progress.
        FSEventStreamSetDispatchQueue(doomed, nil)
        FSEventStreamInvalidate(doomed)
        FSEventStreamRelease(doomed)
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

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // A rename-over is briefly visible as a missing file. Reporting a
            // change for a file that is not there yet would blank the view, so
            // wait for the next event instead.
            guard FileManager.default.fileExists(atPath: self.fileURL.path) else { return }
            self.onChange()
        }

        stateLock.lock()
        debounceWorkItem?.cancel()
        debounceWorkItem = work
        stateLock.unlock()

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceInterval, execute: work)
    }
}

/// Retained by the FSEvents stream so the callback always has a valid pointer,
/// while holding the watcher weakly so the stream does not keep it alive.
private final class WatcherBox {
    weak var watcher: FileWatcher?
    init(_ watcher: FileWatcher) { self.watcher = watcher }
}

/// C callback trampoline. `info` is a retained `WatcherBox`, released by the
/// stream's own release callback.
private func eventCallback(
    stream: ConstFSEventStreamRef,
    info: UnsafeMutableRawPointer?,
    count: Int,
    paths: UnsafeMutableRawPointer,
    flags: UnsafePointer<FSEventStreamEventFlags>,
    ids: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    let box = Unmanaged<WatcherBox>.fromOpaque(info).takeUnretainedValue()
    guard let watcher = box.watcher else { return }

    // kFSEventStreamCreateFlagUseCFTypes means `paths` is a CFArrayRef. Taking
    // it through Unmanaged is the checked form of the widely-copied
    // unsafeBitCast idiom.
    guard let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue()
        as? [String] else { return }
    watcher.handle(paths: array)
}
