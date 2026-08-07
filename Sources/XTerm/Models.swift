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

enum CharacterEncoding: String, Codable, CaseIterable, Identifiable {
    case utf8
    case ascii
    case gb18030
    case latin1

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .utf8: return "UTF-8"
        case .ascii: return "ASCII（7 位）"
        case .gb18030: return "GB18030 / GBK"
        case .latin1: return "ISO-8859-1"
        }
    }
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

struct ReceiveTrigger: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = "接收触发"
    var enabled = false
    var matchPayload = ""
    var matchMode: DataMode = .ascii
    var responsePayload = ""
    var responseMode: DataMode = .ascii
    var responseLineEnding: LineEnding = .crlf
    var checksum: ChecksumKind = .none
    var cooldownMilliseconds = 250
}

struct SendHistoryItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var timestamp = Date()
    var payload = ""
    var mode: DataMode = .ascii
    var lineEnding: LineEnding = .none
    var checksum: ChecksumKind = .none
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
    var characterEncoding: CharacterEncoding = .utf8
    var lineEnding: LineEnding = .crlf
    var checksum: ChecksumKind = .none
    var checksumLittleEndian = true
    var timestampEnabled = true
    var autoLoginEnabled = false
    var loginSteps: [AutoLoginStep] = []
    var autoCommands: [AutoCommand] = []
    var receiveTriggers: [ReceiveTrigger] = []
    var sendHistory: [SendHistoryItem] = []
    var fileChunkSize = 4_096
    var fileChunkDelayMilliseconds = 5

    private enum CodingKeys: String, CodingKey {
        case id, name, portPath, baudRate, dataBits, stopBits, parity, flowControl
        case autoReconnect, reconnectDelaySeconds, localEcho, receiveMode, sendMode
        case characterEncoding, lineEnding, checksum, checksumLittleEndian, timestampEnabled
        case autoLoginEnabled, loginSteps, autoCommands, receiveTriggers, sendHistory
        case fileChunkSize, fileChunkDelayMilliseconds
    }

    /// Decode every property with a default so sessions saved by earlier releases
    /// remain usable as new options are introduced.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "新会话"
        portPath = try values.decodeIfPresent(String.self, forKey: .portPath) ?? ""
        baudRate = try values.decodeIfPresent(Int.self, forKey: .baudRate) ?? 115_200
        dataBits = try values.decodeIfPresent(Int.self, forKey: .dataBits) ?? 8
        stopBits = try values.decodeIfPresent(Int.self, forKey: .stopBits) ?? 1
        parity = try values.decodeIfPresent(Parity.self, forKey: .parity) ?? .none
        flowControl = try values.decodeIfPresent(FlowControl.self, forKey: .flowControl) ?? .none
        autoReconnect = try values.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? true
        reconnectDelaySeconds = try values.decodeIfPresent(Double.self, forKey: .reconnectDelaySeconds) ?? 2
        localEcho = try values.decodeIfPresent(Bool.self, forKey: .localEcho) ?? false
        receiveMode = try values.decodeIfPresent(DataMode.self, forKey: .receiveMode) ?? .ascii
        sendMode = try values.decodeIfPresent(DataMode.self, forKey: .sendMode) ?? .ascii
        characterEncoding = try values.decodeIfPresent(CharacterEncoding.self, forKey: .characterEncoding) ?? .utf8
        lineEnding = try values.decodeIfPresent(LineEnding.self, forKey: .lineEnding) ?? .crlf
        checksum = try values.decodeIfPresent(ChecksumKind.self, forKey: .checksum) ?? .none
        checksumLittleEndian = try values.decodeIfPresent(Bool.self, forKey: .checksumLittleEndian) ?? true
        timestampEnabled = try values.decodeIfPresent(Bool.self, forKey: .timestampEnabled) ?? true
        autoLoginEnabled = try values.decodeIfPresent(Bool.self, forKey: .autoLoginEnabled) ?? false
        loginSteps = try values.decodeIfPresent([AutoLoginStep].self, forKey: .loginSteps) ?? []
        autoCommands = try values.decodeIfPresent([AutoCommand].self, forKey: .autoCommands) ?? []
        receiveTriggers = try values.decodeIfPresent([ReceiveTrigger].self, forKey: .receiveTriggers) ?? []
        sendHistory = try values.decodeIfPresent([SendHistoryItem].self, forKey: .sendHistory) ?? []
        fileChunkSize = try values.decodeIfPresent(Int.self, forKey: .fileChunkSize) ?? 4_096
        fileChunkDelayMilliseconds = try values.decodeIfPresent(Int.self, forKey: .fileChunkDelayMilliseconds) ?? 5
    }

    init() {}
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
