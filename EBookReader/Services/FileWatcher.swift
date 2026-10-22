import Foundation
import os

/// One FSEvents item event from a watched folder.
struct FileEvent: Sendable, Hashable {
    let path: String
    let flags: FSEventStreamEventFlags
    /// The item's inode, as reported by FSEvents. Both halves of a rename
    /// carry the same value, which is how a disappeared book file is matched
    /// to where it went. Nil when FSEvents doesn't supply it.
    let fileID: UInt64?

    init(path: String, flags: FSEventStreamEventFlags = 0, fileID: UInt64? = nil) {
        self.path = path
        self.flags = flags
        self.fileID = fileID
    }
}

final class FileWatcher: @unchecked Sendable {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "EBookReader",
        category: "FileWatcher"
    )

    private var streams: [String: FSEventStreamRef] = [:]
    private let queue = DispatchQueue(label: "com.ebookreader.filewatcher", qos: .utility)
    private let lock = NSLock()
    private var onChange: (@Sendable ([FileEvent]) -> Void)?

    /// Callback receives the batch of item events, in the order FSEvents reported them.
    func setChangeHandler(_ handler: @escaping @Sendable ([FileEvent]) -> Void) {
        onChange = handler
    }

    func startWatching(path: String) {
        lock.lock()
        let alreadyWatching = streams[path] != nil
        lock.unlock()
        guard !alreadyWatching else { return }

        let pathsToWatch = [path] as CFArray
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        guard let stream = FSEventStreamCreate(
            nil,
            { (_, info, numEvents, eventPaths, eventFlags, _) in
                guard let info = info else { return }
                let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()

                // With UseExtendedData each entry is a dictionary holding the
                // path and the inode ("fileID"); plain paths are handled too.
                let entries = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray
                var events: [FileEvent] = []
                events.reserveCapacity(numEvents)
                for i in 0..<min(numEvents, entries.count) {
                    let entry = entries[i]
                    if let dict = entry as? NSDictionary, let path = dict["path"] as? String {
                        let fileID = (dict["fileID"] as? NSNumber)?.uint64Value
                        events.append(FileEvent(path: path, flags: eventFlags[i], fileID: fileID))
                    } else if let path = entry as? String {
                        events.append(FileEvent(path: path, flags: eventFlags[i]))
                    }
                }

                watcher.handleEvents(events)
            },
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            2.0, // 2 second latency for debouncing
            UInt32(
                kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagUseCFTypes
                    | kFSEventStreamCreateFlagUseExtendedData
            )
        ) else {
            logger.error("Failed to create FSEventStream for \(path)")
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        lock.lock()
        streams[path] = stream
        lock.unlock()
        logger.info("Started watching: \(path)")
    }

    func stopWatching(path: String) {
        lock.lock()
        guard let stream = streams.removeValue(forKey: path) else { lock.unlock(); return }
        lock.unlock()
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        logger.info("Stopped watching: \(path)")
    }

    func stopAll() {
        lock.lock()
        let allPaths = Array(streams.keys)
        lock.unlock()
        for path in allPaths {
            stopWatching(path: path)
        }
        onChange = nil
    }

    private func handleEvents(_ events: [FileEvent]) {
        guard !events.isEmpty else { return }
        onChange?(events)
    }

    deinit {
        stopAll()
    }
}
