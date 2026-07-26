import Foundation

enum CodecError: LocalizedError {
    case invalidHex(String)

    var errorDescription: String? {
        switch self {
        case .invalidHex(let token): return "无效 HEX 数据：\(token)。请输入成对十六进制字节，例如 01 03 00 FF。"
        }
    }
}

enum DataCodec {
    static func encode(_ text: String, mode: DataMode, lineEnding: LineEnding = .none) throws -> Data {
        var bytes: [UInt8]
        switch mode {
        case .ascii:
            bytes = Array(text.utf8)
        case .hex:
            let cleaned = text
                .replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
                .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",:-")))
                .filter { !$0.isEmpty }
                .joined()
            guard cleaned.count.isMultiple(of: 2) else { throw CodecError.invalidHex(cleaned) }
            bytes = try stride(from: 0, to: cleaned.count, by: 2).map { offset in
                let start = cleaned.index(cleaned.startIndex, offsetBy: offset)
                let end = cleaned.index(start, offsetBy: 2)
                let token = String(cleaned[start..<end])
                guard let value = UInt8(token, radix: 16) else { throw CodecError.invalidHex(token) }
                return value
            }
        }
        bytes.append(contentsOf: lineEnding.bytes)
        return Data(bytes)
    }

    static func display(_ data: Data, mode: DataMode) -> String {
        switch mode {
        case .ascii:
            return String(decoding: data, as: UTF8.self)
                .replacingOccurrences(of: "\0", with: "␀")
        case .hex:
            return data.map { String(format: "%02X", $0) }.joined(separator: " ")
        }
    }
}

enum Checksum {
    static func append(to data: Data, kind: ChecksumKind, littleEndian: Bool = true) -> Data {
        guard kind != .none else { return data }
        var result = data
        switch kind {
        case .none: break
        case .modbusCRC16:
            let value = crc16Modbus(data)
            result.append(littleEndian ? UInt8(value & 0xFF) : UInt8(value >> 8))
            result.append(littleEndian ? UInt8(value >> 8) : UInt8(value & 0xFF))
        case .crc16CCITT:
            let value = crc16CCITT(data)
            result.append(littleEndian ? UInt8(value & 0xFF) : UInt8(value >> 8))
            result.append(littleEndian ? UInt8(value >> 8) : UInt8(value & 0xFF))
        case .lrc:
            result.append(UInt8(truncatingIfNeeded: 0 &- data.reduce(UInt8(0), &+)))
        case .sum8:
            result.append(data.reduce(UInt8(0), &+))
        case .xor8:
            result.append(data.reduce(UInt8(0), ^))
        }
        return result
    }

    static func crc16Modbus(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in data {
            crc ^= UInt16(byte)
            for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1 }
        }
        return crc
    }

    static func crc16CCITT(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in data {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1 }
        }
        return crc
    }
}
