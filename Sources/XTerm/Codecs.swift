import Foundation
import CoreFoundation

enum CodecError: LocalizedError {
    case invalidHex(String)
    case textCannotBeEncoded(CharacterEncoding)

    var errorDescription: String? {
        switch self {
        case .invalidHex(let token): return "无效 HEX 数据：\(token)。请输入成对十六进制字节，例如 01 03 00 FF。"
        case .textCannotBeEncoded(let encoding):
            return "内容包含无法用 \(encoding.displayName) 表示的字符，请更换字符编码或修改内容。"
        }
    }
}

extension CharacterEncoding {
    var foundationEncoding: String.Encoding {
        switch self {
        case .utf8: return .utf8
        case .ascii: return .ascii
        case .gb18030:
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            ))
        case .latin1: return .isoLatin1
        }
    }
}

enum DataCodec {
    static func encode(_ text: String, mode: DataMode, lineEnding: LineEnding = .none,
                       encoding: CharacterEncoding = .utf8) throws -> Data {
        var bytes: [UInt8]
        switch mode {
        case .ascii:
            guard let data = text.data(using: encoding.foundationEncoding, allowLossyConversion: false) else {
                throw CodecError.textCannotBeEncoded(encoding)
            }
            bytes = Array(data)
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

    static func display(_ data: Data, mode: DataMode,
                        encoding: CharacterEncoding = .utf8) -> String {
        switch mode {
        case .ascii:
            let decoded = String(data: data, encoding: encoding.foundationEncoding)
                ?? String(decoding: data, as: UTF8.self)
            return decoded
                .replacingOccurrences(of: "\0", with: "␀")
        case .hex:
            return data.map { String(format: "%02X", $0) }.joined(separator: " ")
        }
    }
}

/// Converts serial text to UTF-8 while retaining up to three trailing bytes
/// when a UTF-8 or GB18030 character is split across read callbacks.
final class TerminalTextTranscoder {
    private var pending = Data()
    private var activeEncoding: CharacterEncoding = .utf8

    func reset() {
        pending.removeAll(keepingCapacity: true)
        activeEncoding = .utf8
    }

    func transcode(_ data: Data, encoding: CharacterEncoding) -> Data {
        if encoding != activeEncoding {
            pending.removeAll(keepingCapacity: true)
            activeEncoding = encoding
        }
        if encoding == .ascii {
            return Data(data.flatMap { byte in
                byte < 0x80 ? [byte] : Array("�".utf8)
            })
        }
        if encoding == .latin1 {
            return Data((String(data: data, encoding: .isoLatin1) ?? "").utf8)
        }

        pending.append(data)
        let maximumTail = min(3, pending.count)
        for tailCount in 0...maximumTail {
            let prefixCount = pending.count - tailCount
            guard prefixCount > 0 else { continue }
            let prefix = pending.prefix(prefixCount)
            if let text = String(data: prefix, encoding: encoding.foundationEncoding) {
                pending = Data(pending.suffix(tailCount))
                return Data(text.utf8)
            }
        }

        // Malformed input must not grow the carry buffer forever. Preserve a
        // possible trailing character and render the invalid prefix visibly.
        guard pending.count > 4 else { return Data() }
        let invalid = pending.prefix(pending.count - 3)
        pending = Data(pending.suffix(3))
        return Data(String(decoding: invalid, as: UTF8.self).utf8)
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
