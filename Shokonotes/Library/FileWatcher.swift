import Foundation
#if os(macOS)
import CoreServices
#endif

/// FSEvents on a folder tree. Callbacks hop to the main queue; the library
/// coalesces bursts itself. On iOS the same type exists with `start` / `stop`
/// no-ops: iCloud is eventual, and the UI rescans on `scenePhase` active.
final class FileWatcher {
    #if os(macOS)
    private var stream: FSEventStreamRef?
    private let handler: @Sendable () -> Void
    private let latency: CFTimeInterval
    #endif

    init(latency: CFTimeInterval = 0.3, handler: @escaping @Sendable () -> Void) {
        #if os(macOS)
        self.latency = latency
        self.handler = handler
        #else
        _ = latency
        _ = handler
        #endif
    }

    func start(paths: [String]) {
        #if os(macOS)
        stop()
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { info in
                _ = Unmanaged<FileWatcher>.fromOpaque(info!).retain()
                return info
            },
            release: { info in
                Unmanaged<FileWatcher>.fromOpaque(info!).release()
            },
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.handler()
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        self.stream = stream
        #else
        _ = paths
        #endif
    }

    func stop() {
        #if os(macOS)
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        #endif
    }

    deinit {
        stop()
    }
}
