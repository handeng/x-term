import Foundation
import Darwin

enum SerialError: LocalizedError {
    case openFailed(String, Int32)
    case configureFailed(String)
    case notConnected
    case writeFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .openFailed(let path, let code): return "无法打开 \(path)：\(String(cString: strerror(code)))"
        case .configureFailed(let reason): return "串口配置失败：\(reason)"
        case .notConnected: return "串口尚未连接"
        case .writeFailed(let code): return "发送失败：\(String(cString: strerror(code)))"
        }
    }
}

final class SerialPort: @unchecked Sendable {
    typealias ConnectionID = UUID

    var onData: (@MainActor (Data, ConnectionID) -> Void)?
    var onDisconnect: (@MainActor (ConnectionID, Error?) -> Void)?
    var onReceiveOverflow: (@MainActor (Int, ConnectionID) -> Void)?

    private let queue = DispatchQueue(label: "com.xterm.serial", qos: .userInitiated)
    private let stateLock = NSLock()
    private var descriptor: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var connectionID: ConnectionID?
    private let deliveryLock = NSLock()
    private var pendingDelivery = Data()
    private var pendingDeliveryID: ConnectionID?
    private var deliveryScheduled = false
    private var pendingDroppedBytes = 0
    private let maxPendingDeliveryBytes = 4 * 1024 * 1024

    var isOpen: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return descriptor >= 0
    }

    deinit {
        close(notify: false)
    }

    @discardableResult
    func open(session: SerialSession) throws -> ConnectionID {
        close(notify: false)
        let fd = Darwin.open(session.portPath, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw SerialError.openFailed(session.portPath, errno) }
        do {
            try configure(fd: fd, session: session)
        } catch {
            Darwin.close(fd)
            throw error
        }
        let id = ConnectionID()
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let source else { return }
            self?.readAvailable(source: source, fd: fd, connectionID: id, path: session.portPath)
        }
        source.setCancelHandler { Darwin.close(fd) }

        stateLock.lock()
        descriptor = fd
        connectionID = id
        readSource = source
        stateLock.unlock()
        source.resume()
        return id
    }

    func close(notify: Bool = false) {
        stateLock.lock()
        guard descriptor >= 0 else {
            stateLock.unlock()
            return
        }
        let source = readSource
        let id = connectionID
        readSource = nil
        descriptor = -1
        connectionID = nil
        stateLock.unlock()

        source?.cancel()
        if let id { discardPendingDelivery(for: id) }
        if notify, let id {
            Task { @MainActor [weak self] in self?.onDisconnect?(id, nil) }
        }
    }

    func write(_ data: Data) throws {
        stateLock.lock()
        let fd = descriptor
        let id = connectionID
        stateLock.unlock()
        guard fd >= 0 else { throw SerialError.notConnected }

        try queue.sync {
            try writeOnQueue(data, fd: fd, connectionID: id)
        }
    }

    /// Writes without blocking the main actor. Large file transfers use this path
    /// so a slow serial peer cannot freeze the window for the poll timeout.
    func writeAsync(_ data: Data) async throws {
        let (fd, id) = connectionSnapshot()
        guard fd >= 0 else { throw SerialError.notConnected }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: SerialError.notConnected)
                    return
                }
                do {
                    try self.writeOnQueue(data, fd: fd, connectionID: id)
                    continuation.resume(returning: ())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func connectionSnapshot() -> (Int32, ConnectionID?) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (descriptor, connectionID)
    }

    private func writeOnQueue(_ data: Data, fd: Int32, connectionID id: ConnectionID?) throws {
        guard isCurrent(id) else { throw SerialError.notConnected }
        var sent = 0
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            while sent < data.count {
                guard isCurrent(id) else { throw SerialError.notConnected }
                let count = Darwin.write(fd, base.advanced(by: sent), data.count - sent)
                if count > 0 { sent += count; continue }
                if count < 0 && errno == EINTR { continue }
                if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    var writable = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let result = Darwin.poll(&writable, 1, 2_000)
                    if result > 0 { continue }
                    if result < 0 && errno == EINTR { continue }
                    throw SerialError.writeFailed(result == 0 ? ETIMEDOUT : errno)
                }
                throw SerialError.writeFailed(errno)
            }
        }
    }

    private func readAvailable(source: DispatchSourceRead, fd: Int32,
                               connectionID id: ConnectionID, path: String) {
        guard !source.isCancelled, isCurrent(id) else { return }
        var bytes = [UInt8](repeating: 0, count: 8192)
        var batch = Data()
        batch.reserveCapacity(min(Int(source.data), 256 * 1024))
        var reads = 0
        var terminalError: Error?

        // Bound each handler invocation so cancellation and writes cannot be
        // starved by a continuously producing device.
        while reads < 32, batch.count < 256 * 1024,
              !source.isCancelled, isCurrent(id) {
            reads += 1
            let capacity = min(bytes.count, 256 * 1024 - batch.count)
            let count = Darwin.read(fd, &bytes, capacity)
            switch Self.readDisposition(count: count, error: errno) {
            case .data:
                batch.append(contentsOf: bytes.prefix(count))
            case .drained:
                reads = 32
            case .retry:
                continue
            case .disconnected(let error):
                terminalError = SerialError.openFailed(path, error)
                reads = 32
            }
        }

        if !batch.isEmpty, !source.isCancelled, isCurrent(id) {
            enqueueDelivery(batch, connectionID: id)
        }
        if let terminalError, !source.isCancelled {
            handleUnexpectedClose(connectionID: id, terminalError)
        }
    }

    enum ReadDisposition: Equatable {
        case data
        case drained
        case retry
        case disconnected(Int32)
    }

    /// POSIX serial ports configured with VMIN=0 may legally return zero when
    /// their input queue is drained. It is not an EOF indication.
    static func readDisposition(count: Int, error: Int32) -> ReadDisposition {
        if count > 0 { return .data }
        if count == 0 || error == EAGAIN || error == EWOULDBLOCK { return .drained }
        if error == EINTR { return .retry }
        return .disconnected(error)
    }

    private func handleUnexpectedClose(connectionID id: ConnectionID, _ error: Error?) {
        stateLock.lock()
        guard connectionID == id else {
            stateLock.unlock()
            return
        }
        let source = readSource
        readSource = nil
        descriptor = -1
        connectionID = nil
        stateLock.unlock()

        source?.cancel()
        discardPendingDelivery(for: id)
        Task { @MainActor [weak self] in self?.onDisconnect?(id, error) }
    }

    /// Coalesces background serial reads into at most one pending MainActor job.
    /// This prevents an unbounded queue of Data-capturing tasks when rendering is
    /// temporarily slower than the device. The buffer itself has a hard cap.
    private func enqueueDelivery(_ data: Data, connectionID id: ConnectionID) {
        deliveryLock.lock()
        if pendingDeliveryID != id {
            pendingDelivery.removeAll(keepingCapacity: false)
            pendingDroppedBytes = 0
            pendingDeliveryID = id
            deliveryScheduled = false
        }
        let available = max(0, maxPendingDeliveryBytes - pendingDelivery.count)
        if available > 0 {
            pendingDelivery.append(data.prefix(available))
        }
        if data.count > available {
            pendingDroppedBytes += data.count - available
        }
        let shouldSchedule = !deliveryScheduled
        deliveryScheduled = true
        deliveryLock.unlock()

        guard shouldSchedule else { return }
        Task { @MainActor [weak self] in
            self?.drainPendingDelivery(for: id)
        }
    }

    @MainActor
    private func drainPendingDelivery(for id: ConnectionID) {
        deliveryLock.lock()
        guard pendingDeliveryID == id else {
            deliveryLock.unlock()
            return
        }
        let data = pendingDelivery
        let droppedBytes = pendingDroppedBytes
        pendingDelivery = Data()
        pendingDroppedBytes = 0
        pendingDeliveryID = nil
        deliveryScheduled = false
        deliveryLock.unlock()

        guard isCurrent(id) else { return }
        if !data.isEmpty { onData?(data, id) }
        if droppedBytes > 0 { onReceiveOverflow?(droppedBytes, id) }
    }

    private func discardPendingDelivery(for id: ConnectionID) {
        deliveryLock.lock()
        if pendingDeliveryID == id {
            pendingDelivery = Data()
            pendingDroppedBytes = 0
            pendingDeliveryID = nil
            deliveryScheduled = false
        }
        deliveryLock.unlock()
    }

    private func isCurrent(_ id: ConnectionID?) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return id != nil && connectionID == id && descriptor >= 0
    }

    private func configure(fd: Int32, session: SerialSession) throws {
        var options = termios()
        guard tcgetattr(fd, &options) == 0 else {
            throw SerialError.configureFailed(String(cString: strerror(errno)))
        }

        cfmakeraw(&options)
        options.c_cflag |= tcflag_t(CLOCAL | CREAD)
        options.c_cflag &= ~tcflag_t(CSIZE | PARENB | PARODD | CSTOPB | CRTSCTS)
        switch session.dataBits {
        case 5: options.c_cflag |= tcflag_t(CS5)
        case 6: options.c_cflag |= tcflag_t(CS6)
        case 7: options.c_cflag |= tcflag_t(CS7)
        case 8: options.c_cflag |= tcflag_t(CS8)
        default: throw SerialError.configureFailed("数据位必须为 5、6、7 或 8")
        }

        // POSIX represents 1.5 stop bits as CSTOPB with a 5-bit word.
        if session.stopBits == 2 { options.c_cflag |= tcflag_t(CSTOPB) }
        switch session.parity {
        case .none: break
        case .odd: options.c_cflag |= tcflag_t(PARENB | PARODD)
        case .even: options.c_cflag |= tcflag_t(PARENB)
        }
        options.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        switch session.flowControl {
        case .none: break
        case .hardware: options.c_cflag |= tcflag_t(CRTSCTS)
        case .software: options.c_iflag |= tcflag_t(IXON | IXOFF)
        }
        // Reads are driven by DispatchSource on a nonblocking descriptor.
        options.c_cc.16 = 0 // VMIN
        options.c_cc.17 = 0 // VTIME

        let speed = Self.speedConstant(session.baudRate) ?? speed_t(B9600)
        guard cfsetispeed(&options, speed) == 0,
              cfsetospeed(&options, speed) == 0,
              tcsetattr(fd, TCSANOW, &options) == 0 else {
            throw SerialError.configureFailed(String(cString: strerror(errno)))
        }
        if Self.speedConstant(session.baudRate) == nil {
            guard (50...4_000_000).contains(session.baudRate) else {
                throw SerialError.configureFailed("自定义波特率必须在 50～4,000,000 之间")
            }
            var customSpeed = speed_t(session.baudRate)
            // IOSSIOSPEED = _IOW('T', 2, speed_t), required for non-POSIX baud rates on macOS.
            let iosSIOSpeed: UInt = 0x8008_5402
            guard ioctl(fd, iosSIOSpeed, &customSpeed) == 0 else {
                throw SerialError.configureFailed("设备不支持 \(session.baudRate) bps：\(String(cString: strerror(errno)))")
            }
        }
        tcflush(fd, TCIOFLUSH)
    }

    private static func speedConstant(_ baud: Int) -> speed_t? {
        switch baud {
        case 50: return speed_t(B50)
        case 75: return speed_t(B75)
        case 110: return speed_t(B110)
        case 134: return speed_t(B134)
        case 150: return speed_t(B150)
        case 200: return speed_t(B200)
        case 300: return speed_t(B300)
        case 600: return speed_t(B600)
        case 1200: return speed_t(B1200)
        case 1800: return speed_t(B1800)
        case 2400: return speed_t(B2400)
        case 4800: return speed_t(B4800)
        case 9600: return speed_t(B9600)
        case 19200: return speed_t(B19200)
        case 38400: return speed_t(B38400)
        case 57600: return speed_t(B57600)
        case 115200: return speed_t(B115200)
        case 230400: return speed_t(B230400)
        default: return nil
        }
    }

    static func availablePorts() -> [SerialPortInfo] {
        let directory = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return directory
            .filter { $0.hasPrefix("cu.") && !$0.contains("Bluetooth-Incoming-Port") }
            .sorted()
            .map {
                let name = String($0.dropFirst(3))
                return SerialPortInfo(path: "/dev/\($0)", displayName: name)
            }
    }
}
