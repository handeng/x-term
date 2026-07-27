import XCTest
import Darwin
@testable import XTerm

final class CodecTests: XCTestCase {
    func testHexParsingAcceptsCommonFormats() throws {
        XCTAssertEqual(try DataCodec.encode("01 03 00 FF", mode: .hex), Data([0x01, 0x03, 0x00, 0xFF]))
        XCTAssertEqual(try DataCodec.encode("0x01,0x03:00-ff", mode: .hex), Data([0x01, 0x03, 0x00, 0xFF]))
    }

    func testHexParsingRejectsOddNibble() {
        XCTAssertThrowsError(try DataCodec.encode("ABC", mode: .hex))
    }

    func testLineEndings() throws {
        XCTAssertEqual(try DataCodec.encode("AT", mode: .ascii, lineEnding: .crlf), Data([0x41, 0x54, 0x0D, 0x0A]))
    }

    func testModbusCRCVector() {
        let request = Data([0x01, 0x03, 0x00, 0x00, 0x00, 0x0A])
        XCTAssertEqual(Checksum.crc16Modbus(request), 0xCDC5)
        XCTAssertEqual(Checksum.append(to: request, kind: .modbusCRC16),
                       Data([0x01, 0x03, 0x00, 0x00, 0x00, 0x0A, 0xC5, 0xCD]))
    }

    func testCCITTVector() {
        XCTAssertEqual(Checksum.crc16CCITT(Data("123456789".utf8)), 0x29B1)
    }

    func testLRC() {
        let packet = Checksum.append(to: Data([0x01, 0x03, 0x00, 0x00, 0x00, 0x0A]), kind: .lrc)
        XCTAssertEqual(packet.reduce(UInt8(0), &+), 0)
    }

    func testSerialZeroLengthReadMeansInputDrainedNotDisconnected() {
        XCTAssertEqual(SerialPort.readDisposition(count: 0, error: 0), .drained)
        XCTAssertEqual(SerialPort.readDisposition(count: -1, error: EAGAIN), .drained)
        XCTAssertEqual(SerialPort.readDisposition(count: -1, error: EINTR), .retry)
        XCTAssertEqual(SerialPort.readDisposition(count: -1, error: EIO), .disconnected(EIO))
    }

    @MainActor
    func testLogRetentionIsBoundedByPayloadBytes() {
        let model = AppModel()
        let payload = Data(repeating: 0xA5, count: 64 * 1024)
        for _ in 0..<200 {
            model.append(LogEntry(timestamp: Date(), direction: .received, data: payload, message: nil))
        }

        XCTAssertLessThanOrEqual(model.retainedLogBytes, 8 * 1024 * 1024)
        XCTAssertLessThan(model.logs.count, 200)
        model.clearLog()
        XCTAssertEqual(model.retainedLogBytes, 0)
    }
}
