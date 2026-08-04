import XCTest
import Darwin
@testable import XTerm

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    init(_ value: Bool) { self.value = value }

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Bool) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}

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

    func testClosingSerialPortStopsCallbacksDuringContinuousInput() throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        XCTAssertEqual(openpty(&master, &slave, nil, nil, nil), 0)
        guard master >= 0, slave >= 0, let deviceName = ttyname(slave) else {
            XCTFail("无法创建伪终端")
            return
        }
        let devicePath = String(cString: deviceName)
        Darwin.close(slave)
        _ = fcntl(master, F_SETFL, O_NONBLOCK)

        let port = SerialPort()
        let firstReceive = expectation(description: "收到伪终端数据")
        firstReceive.assertForOverFulfill = false
        let counterLock = NSLock()
        var callbackCount = 0
        port.onData = { @MainActor _, _ in
            counterLock.lock()
            callbackCount += 1
            counterLock.unlock()
            firstReceive.fulfill()
        }

        var session = SerialSession()
        session.portPath = devicePath
        _ = try port.open(session: session)

        let keepWriting = LockedFlag(true)
        let writerDone = expectation(description: "写入线程停止")
        DispatchQueue.global(qos: .userInitiated).async {
            let payload = [UInt8](repeating: 0x55, count: 8192)
            while keepWriting.get() {
                payload.withUnsafeBytes { buffer in
                    if let base = buffer.baseAddress {
                        _ = Darwin.write(master, base, buffer.count)
                    }
                }
            }
            writerDone.fulfill()
        }

        wait(for: [firstReceive], timeout: 2)
        port.close()
        counterLock.lock()
        let countAtClose = callbackCount
        counterLock.unlock()

        keepWriting.set(false)
        wait(for: [writerDone], timeout: 2)
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))

        counterLock.lock()
        let countAfterClose = callbackCount
        counterLock.unlock()
        Darwin.close(master)
        XCTAssertEqual(countAfterClose, countAtClose,
                       "关闭串口后不应继续投递接收回调")
    }
}
