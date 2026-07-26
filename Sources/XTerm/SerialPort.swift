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

    func open(session: SerialSession) throws {
        close(notify: false)
        let fd = Darwin.open(session.portPath, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw SerialError.openFailed(session.portPath, errno) }
        do {
            try configure(fd: fd, session: session)
            if fcntl(fd, F_SETFL, 0) < 0 {
                throw SerialError.configureFailed("无法切换为阻塞写入模式")
            }
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
            if count > 0 {
                onData?(Data(bytes.prefix(count)))
            } else if count == 0 {
                handleUnexpectedClose(nil)
                break
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                break
            } else if errno != EINTR {
                handleUnexpectedClose(SerialError.openFailed(path ?? "串口", errno))
                break
            }
        }
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
        options.c_cc.16 = 0 // VMIN
        options.c_cc.17 = 1 // VTIME, 100 ms

        let speed = Self.speedConstant(session.baudRate)
        guard cfsetispeed(&options, speed) == 0,
              cfsetospeed(&options, speed) == 0,
              tcsetattr(fd, TCSANOW, &options) == 0 else {
            throw SerialError.configureFailed(String(cString: strerror(errno)))
        }
        tcflush(fd, TCIOFLUSH)
    }

    private static func speedConstant(_ baud: Int) -> speed_t {
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
        default: return speed_t(B115200)
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
