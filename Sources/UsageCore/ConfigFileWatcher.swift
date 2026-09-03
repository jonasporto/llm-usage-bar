import Darwin
import Foundation

/// Two kqueues: one on the config directory, which catches the temporary-file
/// dance of an editor that saves atomically, and one on `profiles.json`
/// itself, which catches an editor that truncates and rewrites in place — that
/// leaves the directory untouched, so the directory watch alone never fires.
/// Either way the change is confirmed against the file (mtime + size) before
/// the handler runs. Start/stop are synchronous so no descriptor outlives the
/// watcher.
public final class ConfigFileWatcher: @unchecked Sendable {
    private static let queue = DispatchQueue(
        label: "llm-usage-bar.config-watcher", qos: .utility)

    private let fileURL: URL
    private let delay: TimeInterval
    private let handler: @Sendable () -> Void
    private let lock = NSLock()
    private var source: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var debounce: DispatchWorkItem?
    private var stamp: Stamp?

    public init(fileURL: URL, delay: TimeInterval = 0.25,
                handler: @escaping @Sendable () -> Void) {
        self.fileURL = fileURL
        self.delay = delay
        self.handler = handler
    }

    public func start() {
        lock.lock()
        openLocked()
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        closeLocked()
        lock.unlock()
    }

    deinit {
        lock.lock()
        closeLocked()
        lock.unlock()
    }

    private func openLocked() {
        closeLocked()
        let directory = fileURL.deletingLastPathComponent()
        guard Self.isDirectory(directory) else { return }
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: Self.queue)
        source.setEventHandler { [weak self] in self?.schedule() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        stamp = Self.stamp(of: fileURL)
        openFileSourceLocked()
    }

    /// Watched separately from the directory, and re-opened after every
    /// confirmed change: an atomic replace leaves this descriptor pointing at
    /// the old inode, which would never report another edit.
    private func openFileSourceLocked() {
        fileSource?.cancel()
        fileSource = nil
        let fd = open(fileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete, .revoke],
            queue: Self.queue)
        source.setEventHandler { [weak self] in self?.schedule() }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileSource = source
    }

    private func closeLocked() {
        debounce?.cancel()
        debounce = nil
        source?.cancel()
        source = nil
        fileSource?.cancel()
        fileSource = nil
    }

    private func schedule() {
        lock.lock()
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fire() }
        debounce = work
        lock.unlock()
        Self.queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func fire() {
        lock.lock()
        debounce = nil
        let next = Self.stamp(of: fileURL)
        let changed = next != stamp
        if changed {
            stamp = next
            openFileSourceLocked()
        } else if fileSource == nil {
            openFileSourceLocked()
        }
        lock.unlock()
        if changed { handler() }
    }

    private struct Stamp: Equatable {
        var size: off_t
        var sec: time_t
        var nsec: Int
    }

    private static func stamp(of url: URL) -> Stamp? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        return Stamp(size: st.st_size, sec: st.st_mtimespec.tv_sec, nsec: st.st_mtimespec.tv_nsec)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR
    }
}
