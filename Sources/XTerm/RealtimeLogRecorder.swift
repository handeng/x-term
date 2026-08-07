import Foundation

/// A bounded, batched writer for long-running capture sessions.
///
/// Serial callbacks never wait for disk I/O. Pending output is capped so a slow
/// or unavailable disk cannot turn log recording into an application memory leak.
final class RealtimeLogRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.xterm.log-recorder", qos: .utility)
    private let lock = NSLock()
    private var handle: FileHandle?
    private var pending = Data()
    private var drainScheduled = false
    private var droppedBytes = 0
    private let maxPendingBytes = 4 * 1024 * 1024

    func start(url: URL) throws {
        stop()
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let newHandle = try FileHandle(forWritingTo: url)
        try newHandle.truncate(atOffset: 0)
        try newHandle.write(contentsOf: Data("timestamp,direction,mode,data\n".utf8))
        lock.lock()
        handle = newHandle
        pending = Data()
        droppedBytes = 0
        drainScheduled = false
        lock.unlock()
    }

    func enqueue(_ line: Data) {
        lock.lock()
        guard handle != nil else { lock.unlock(); return }
        guard pending.count + line.count <= maxPendingBytes else {
            droppedBytes += line.count
            lock.unlock()
            return
        }
        pending.append(line)
        if drainScheduled {
            lock.unlock()
            return
        }
        drainScheduled = true
        lock.unlock()
        queue.async { [weak self] in self?.drain() }
    }

    func stop() {
        lock.lock()
        let finalHandle = handle
        handle = nil
        let finalData = pending
        pending = Data()
        let dropped = droppedBytes
        droppedBytes = 0
        lock.unlock()

        guard let finalHandle else { return }
        queue.sync {
            try? finalHandle.write(contentsOf: finalData)
            if dropped > 0 {
                let warning = "\n,,SYS,\"日志写入队列过载，丢弃 \(dropped) 字节\"\n"
                try? finalHandle.write(contentsOf: Data(warning.utf8))
            }
            try? finalHandle.synchronize()
            try? finalHandle.close()
        }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let currentHandle = handle else {
                drainScheduled = false
                lock.unlock()
                return
            }
            guard !pending.isEmpty || droppedBytes > 0 else {
                drainScheduled = false
                lock.unlock()
                return
            }
            let data = pending
            pending = Data()
            let dropped = droppedBytes
            droppedBytes = 0
            lock.unlock()

            try? currentHandle.write(contentsOf: data)
            if dropped > 0 {
                let warning = "\n,,SYS,\"日志写入队列过载，丢弃 \(dropped) 字节\"\n"
                try? currentHandle.write(contentsOf: Data(warning.utf8))
            }
        }
    }
}
