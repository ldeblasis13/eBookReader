import Foundation
import os

final class FileWatcher: @unchecked Sendable {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "EBookReader",
        category: "FileWatcher"
    )

    private var streams: [String: FSEventStreamRef] = [:]
    private let queue = DispatchQueue(label: "com.ebookreader.filewatcher", qos: .utility)
    private let lock = NSLock()
    private var onChange: (@Sendable (Set<String>) -> Void)?

    /// Callback receives the set of changed paths.
    func setChangeHandler(_ handler: @escaping @Sendable (Set<String>) -> Void) {
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
            { (_, info, numEvents, eventPaths, _, _) in
                guard let info = info else { return }
                let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()

                let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
                var changedPaths = Set<String>()
                for i in 0..<numEvents {
                    if let path = unsafeBitCast(CFArrayGetValueAtIndex(paths, i), to: CFString?.self) {
                        changedPaths.insert(path as String)
                    }
                }

                watcher.handleEvents(changedPaths)
            },
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            2.0, // 2 second latency for debouncing
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
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

    private func handleEvents(_ paths: Set<String>) {
        onChange?(paths)
    }

    deinit {
        stopAll()
    }
}
