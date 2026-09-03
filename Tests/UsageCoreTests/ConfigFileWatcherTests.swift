import Darwin
import Foundation
import Testing
@testable import UsageCore

@Suite struct ConfigFileWatcherTests {
    @Test func testAtomicReplaceNotifies() async throws {
        let (root, file) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let hits = HitCounter()
        let watcher = ConfigFileWatcher(fileURL: file, delay: 0.05) {
            Task { await hits.increment() }
        }
        watcher.start()
        try await Task.sleep(nanoseconds: 80_000_000)

        try atomicWrite(Data(#"[{"id":"grok","provider":"xai"}]"#.utf8), to: file)

        let seen = await wait(for: hits, atLeast: 1)
        watcher.stop()
        #expect(seen >= 1)
    }

    @Test func testUnrelatedDirectoryActivityDoesNotNotify() async throws {
        let (root, file) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let hits = HitCounter()
        let watcher = ConfigFileWatcher(fileURL: file, delay: 0.05) {
            Task { await hits.increment() }
        }
        watcher.start()
        try await Task.sleep(nanoseconds: 80_000_000)

        try Data("noise".utf8).write(to: root.appendingPathComponent("notes.txt"))
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(await hits.value == 0)

        try atomicWrite(Data(#"[{"id":"claude"}]"#.utf8), to: file)
        let seen = await wait(for: hits, atLeast: 1)
        watcher.stop()
        #expect(seen >= 1)
    }

    @Test func testInPlaceWriteNotifies() async throws {
        let (root, file) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let hits = HitCounter()
        let watcher = ConfigFileWatcher(fileURL: file, delay: 0.05) {
            Task { await hits.increment() }
        }
        watcher.start()
        try await Task.sleep(nanoseconds: 80_000_000)

        try inPlaceWrite(Data(#"[{"id":"claude"},{"id":"grok","provider":"xai"}]"#.utf8),
                         to: file)

        let seen = await wait(for: hits, atLeast: 1)
        watcher.stop()
        #expect(seen >= 1)
    }

    @Test func testInPlaceWriteAfterAnAtomicReplaceStillNotifies() async throws {
        let (root, file) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let hits = HitCounter()
        let watcher = ConfigFileWatcher(fileURL: file, delay: 0.05) {
            Task { await hits.increment() }
        }
        watcher.start()
        try await Task.sleep(nanoseconds: 80_000_000)

        try atomicWrite(Data(#"[{"id":"claude"}]"#.utf8), to: file)
        #expect(await wait(for: hits, atLeast: 1) >= 1)

        try inPlaceWrite(Data(#"[{"id":"claude"},{"id":"codex","provider":"openai"}]"#.utf8),
                         to: file)

        let seen = await wait(for: hits, atLeast: 2)
        watcher.stop()
        #expect(seen >= 2)
    }

    @Test func testStartStopDoesNotLeakDescriptors() async throws {
        let (root, file) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let before = openDescriptorCount()
        for _ in 0..<32 {
            let watcher = ConfigFileWatcher(fileURL: file, delay: 0.01) {}
            watcher.start()
            watcher.stop()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let after = openDescriptorCount()
        // Process-wide count, and suites run in parallel, so unrelated pipes
        // come and go. A watcher that leaked would show 32 iterations times
        // its two descriptors, well past this bound.
        #expect(after <= before + 16)
    }
}

private actor HitCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private func makeRoot() throws -> (URL, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("llm-usage-bar-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("profiles.json")
    try Data("[]".utf8).write(to: file)
    return (root, file)
}

private func atomicWrite(_ data: Data, to file: URL) throws {
    let staged = file.deletingLastPathComponent()
        .appendingPathComponent(file.lastPathComponent + ".tmp")
    try data.write(to: staged)
    _ = try FileManager.default.replaceItemAt(file, withItemAt: staged)
}

/// What an editor that saves without a temporary file does: same inode,
/// truncated and rewritten. The containing directory never changes.
private func inPlaceWrite(_ data: Data, to file: URL) throws {
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    try handle.truncate(atOffset: 0)
    try handle.write(contentsOf: data)
    try handle.synchronize()
}

private func wait(for hits: HitCounter, atLeast minimum: Int) async -> Int {
    var seen = 0
    for _ in 0..<40 {
        seen = await hits.value
        if seen >= minimum { break }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return seen
}

private func openDescriptorCount() -> Int {
    (0..<512).reduce(0) { count, fd in
        fcntl(Int32(fd), F_GETFD) != -1 ? count + 1 : count
    }
}
