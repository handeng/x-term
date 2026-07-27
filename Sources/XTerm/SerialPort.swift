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

final class SerialPort {
    var onData: ((Data) -> Void)?
    var onDisconnect: ((Error?) -> Void)?

    private let queue = DispatchQueue(label: "com.xterm.serial", qos: .userInitiated)
    private var descriptor: Int32 = -1
    private var readSource: DispatchSourceRead?
    private(set) var path: String?

    var isOpen: Bool { descriptor >= 0 }

    deinit {
        close(notify: false)
    }

    func open(session: SerialSession) throws {
        close(notify: false)
        let fd = Darwin.open(session.portPath, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw SerialError.openFailed(session.portPath, errno) }
        do {
            try configure(fd: fd, session: session)
        } catch {
            Darwin.close(fd)
            throw error
        }
        descriptor = fd
        path = session.portPath

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { Darwin.close(fd) }
        readSource = source
        source.resume()
    }

    func close(notify: Bool = false) {
        guard descriptor >= 0 else { return }
        let fd = descriptor
        let source = readSource
        readSource = nil
        descriptor = -1
        path = nil
        source?.cancel()
        if source == nil { Darwin.close(fd) }
        if notify { onDisconnect?(nil) }
    }

    func write(_ data: Data) throws {
        let fd = descriptor
        guard fd >= 0 else { throw SerialError.notConnected }
        var sent = 0
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            while sent < data.count {
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

    private func readAvailable() {
        let fd = descriptor
        guard fd >= 0 else { return }
        var bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            switch Self.readDisposition(count: count, error: errno) {
            case .data:
                onData?(Data(bytes.prefix(count)))
            case .drained:
                break
            case .retry:
                continue
            case .disconnected(let error):
                handleUnexpectedClose(SerialError.openFailed(path ?? "串口", error))
                break
            }
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

    private func handleUnexpectedClose(_ error: Error?) {
        close(notify: false)
        onDisconnect?(error)
    }

    private func configure(fd: Int32, session: SerialSession) throws {
        var options = termios()
        guard tcgetattr(fd, &options) == 0 else {
            throw SerialError.configureFailed(String(cString: strerror(errno)))
        }

        cfmakeraw(&options)
        options.c_cflag |= tcflag_t(CLOCAL | CREAD)
        options.c_cflag &= ~tcflag_t(CSIZE | PARENB | PARODD | CSTOPB | CRTSCTS)
        options.c_cflag |= session.dataBits == 7 ? tcflag_t(CS7) : tcflag_t(CS8)

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
