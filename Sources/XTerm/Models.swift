import Foundation

enum Parity: String, Codable, CaseIterable, Identifiable {
    case none = "无"
    case odd = "奇校验"
    case even = "偶校验"
    var id: String { rawValue }
}

enum FlowControl: String, Codable, CaseIterable, Identifiable {
    case none = "无"
    case hardware = "RTS/CTS"
    case software = "XON/XOFF"
    var id: String { rawValue }
}

enum DataMode: String, Codable, CaseIterable, Identifiable {
    case ascii = "ASCII"
    case hex = "HEX"
    var id: String { rawValue }
}

enum LineEnding: String, Codable, CaseIterable, Identifiable {
    case none = "无"
    case cr = "CR"
    case lf = "LF"
    case crlf = "CRLF"
    var id: String { rawValue }

    var bytes: [UInt8] {
        switch self {
        case .none: return []
        case .cr: return [0x0D]
        case .lf: return [0x0A]
        case .crlf: return [0x0D, 0x0A]
        }
    }
}

enum ChecksumKind: String, Codable, CaseIterable, Identifiable {
    case none = "无"
    case modbusCRC16 = "CRC-16/Modbus"
    case crc16CCITT = "CRC-16/CCITT-FALSE"
    case lrc = "LRC"
    case sum8 = "SUM8"
    case xor8 = "XOR8"
    var id: String { rawValue }
}

struct AutoLoginStep: Codable, Identifiable, Hashable {
    var id = UUID()
    var waitFor: String = ""
    var send: String = ""
    var timeoutSeconds: Double = 5
    var delayMilliseconds: Int = 100
    var mode: DataMode = .ascii
    var lineEnding: LineEnding = .crlf
    var secret = false
}

struct AutoCommand: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = "定时命令"
    var payload = ""
    var mode: DataMode = .ascii
    var lineEnding: LineEnding = .crlf
    var checksum: ChecksumKind = .none
    var intervalMilliseconds = 1000
    var repeatCount = 0
    var enabled = false
}

struct SerialSession: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = "新会话"
    var portPath = ""
    var baudRate = 115_200
    var dataBits = 8
    var stopBits = 1
    var parity: Parity = .none
    var flowControl: FlowControl = .none
    var autoReconnect = true
    var reconnectDelaySeconds: Double = 2
    var localEcho = false
    var receiveMode: DataMode = .ascii
    var sendMode: DataMode = .ascii
    var lineEnding: LineEnding = .crlf
    var checksum: ChecksumKind = .none
    var checksumLittleEndian = true
    var timestampEnabled = true
    var autoLoginEnabled = false
    var loginSteps: [AutoLoginStep] = []
    var autoCommands: [AutoCommand] = []
}

struct SerialPortInfo: Identifiable, Hashable {
    let path: String
    let displayName: String
    var id: String { path }
}

enum LogDirection: String {
    case received = "RX"
    case sent = "TX"
    case system = "SYS"
}

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let direction: LogDirection
    let data: Data
    let message: String?

    static func system(_ message: String) -> LogEntry {
        LogEntry(timestamp: Date(), direction: .system, data: Data(), message: message)
    }
}
