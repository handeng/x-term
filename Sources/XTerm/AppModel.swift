import Foundation
import AppKit
import Combine

@MainActor
final class AppModel: ObservableObject {
    @Published var ports: [SerialPortInfo] = []
    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var logs: [LogEntry] = []
    @Published var sendText = ""
    @Published var lastError: String?
    @Published var statusText = "未连接"

    let store = SessionStore()
    private let serial = SerialPort()
    private var portRefreshTimer: Timer?
    private var autoCommandTimers: [UUID: Timer] = [:]
    private var autoCommandCounts: [UUID: Int] = [:]
    private var reconnectTask: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?
    private var receiveBuffer = Data()
    private var manualDisconnect = false
    private var cancellables: Set<AnyCancellable> = []
    private var terminalHandler: ((Data?) -> Void)?
    private(set) var retainedLogBytes = 0
    private let maxLogEntries = 4_000
    private let targetLogEntries = 3_000
    private let maxLogBytes = 8 * 1024 * 1024
    private let targetLogBytes = 6 * 1024 * 1024
    private let maxReceiveBuffer = 64 * 1024

    var selectedSession: SerialSession? {
        guard let id = store.selectedID else { return nil }
        return store.sessions.first { $0.id == id }
    }

    init() {
        store.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        serial.onData = { [weak self] data in
            Task { @MainActor in self?.handleReceived(data) }
        }
        serial.onDisconnect = { [weak self] error in
            Task { @MainActor in self?.handleDisconnect(error) }
        }
        refreshPorts()
        portRefreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPorts() }
        }
    }

    deinit {
        portRefreshTimer?.invalidate()
        reconnectTask?.cancel()
        loginTask?.cancel()
        autoCommandTimers.values.forEach { $0.invalidate() }
    }

    func addSession() { store.add() }

    func selectSession(_ id: UUID?) {
        guard store.selectedID != id else { return }
        if isConnected { disconnect() }
        store.selectedID = id
    }

    func updateSelected(_ mutate: (inout SerialSession) -> Void) {
        guard var session = selectedSession else { return }
        mutate(&session)
        store.update(session)
        objectWillChange.send()
    }

    func refreshPorts() {
        ports = SerialPort.availablePorts()
        if var session = selectedSession, session.portPath.isEmpty, let first = ports.first {
            session.portPath = first.path
            store.update(session)
        }
    }

    func toggleConnection() {
        isConnected ? disconnect() : connect()
    }

    func connect() {
        guard let session = selectedSession else { return }
        guard !session.portPath.isEmpty else {
            report("请选择串口设备")
            return
        }
        manualDisconnect = false
        reconnectTask?.cancel()
        isConnecting = true
        do {
            try serial.open(session: session)
            isConnected = true
            isConnecting = false
            statusText = "已连接 · \(session.portPath) · \(session.baudRate) \(session.dataBits)\(parityLetter(session.parity))\(session.stopBits)"
            append(.system("已连接 \(session.portPath) @ \(session.baudRate) bps"))
            startAutomation(session)
        } catch {
            isConnecting = false
            report(error.localizedDescription)
            scheduleReconnectIfNeeded(session)
        }
    }

    func disconnect() {
        manualDisconnect = true
        reconnectTask?.cancel()
        stopAutomation()
        serial.close()
        if isConnected { append(.system("连接已断开")) }
        isConnected = false
        isConnecting = false
        statusText = "未连接"
    }

    func sendCurrent() {
        guard let session = selectedSession else { return }
        do {
            let raw = try DataCodec.encode(sendText, mode: session.sendMode, lineEnding: session.lineEnding)
            let packet = Checksum.append(to: raw, kind: session.checksum, littleEndian: session.checksumLittleEndian)
            try send(packet, localEcho: session.localEcho)
            sendText = ""
        } catch {
            report(error.localizedDescription)
        }
    }

    func send(_ data: Data, localEcho: Bool = false) throws {
        try serial.write(data)
        append(LogEntry(timestamp: Date(), direction: .sent, data: data, message: nil))
        if localEcho {
            append(LogEntry(timestamp: Date(), direction: .received, data: data, message: nil))
        }
    }

    func clearLog() {
        logs.removeAll(keepingCapacity: false)
        retainedLogBytes = 0
        receiveBuffer.removeAll(keepingCapacity: true)
        terminalHandler?(nil)
    }

    /// Attaches the visible VT terminal. Existing RX data is replayed so switching
    /// between HEX and terminal modes does not lose the current screen contents.
    func setTerminalHandler(_ handler: ((Data?) -> Void)?) {
        terminalHandler = handler
        guard let handler else { return }
        handler(nil)
        for entry in logs where entry.direction == .received {
            handler(entry.data)
        }
    }

    func copyLog() {
        guard let session = selectedSession else { return }
        let text = logs.map { entry -> String in
            let time = session.timestampEnabled ? "\(Self.timestamp.string(from: entry.timestamp)) " : ""
            if let message = entry.message { return "\(time)[\(entry.direction.rawValue)] \(message)" }
            return "\(time)[\(entry.direction.rawValue)] \(DataCodec.display(entry.data, mode: session.receiveMode))"
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func exportLog() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "xterm-\(Self.fileTimestamp.string(from: Date())).log"
        guard panel.runModal() == .OK, let url = panel.url, let session = selectedSession else { return }
        let text = logs.map {
            "\(Self.timestamp.string(from: $0.timestamp)) [\($0.direction.rawValue)] \($0.message ?? DataCodec.display($0.data, mode: session.receiveMode))"
        }.joined(separator: "\n")
        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { report("导出失败：\(error.localizedDescription)") }
    }

    func runAutoCommand(_ command: AutoCommand) {
        guard isConnected else { report("请先连接串口"); return }
        stopAutoCommand(command.id)
        autoCommandCounts[command.id] = 0
        let interval = max(50, command.intervalMilliseconds)
        let timer = Timer.scheduledTimer(withTimeInterval: Double(interval) / 1000, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                self.sendAutoCommand(command)
            }
        }
        autoCommandTimers[command.id] = timer
        sendAutoCommand(command)
    }

    func stopAutoCommand(_ id: UUID) {
        autoCommandTimers.removeValue(forKey: id)?.invalidate()
        autoCommandCounts.removeValue(forKey: id)
    }

    func isAutoCommandRunning(_ id: UUID) -> Bool { autoCommandTimers[id] != nil }

    private func sendAutoCommand(_ command: AutoCommand) {
        do {
            let raw = try DataCodec.encode(command.payload, mode: command.mode, lineEnding: command.lineEnding)
            let session = selectedSession
            let packet = Checksum.append(to: raw, kind: command.checksum,
                                         littleEndian: session?.checksumLittleEndian ?? true)
            try send(packet)
            let count = (autoCommandCounts[command.id] ?? 0) + 1
            autoCommandCounts[command.id] = count
            if command.repeatCount > 0 && count >= command.repeatCount { stopAutoCommand(command.id) }
        } catch {
            stopAutoCommand(command.id)
            report("自动发送停止：\(error.localizedDescription)")
        }
    }

    private func handleReceived(_ data: Data) {
        append(LogEntry(timestamp: Date(), direction: .received, data: data, message: nil))
        terminalHandler?(data)
        receiveBuffer.append(data)
        if receiveBuffer.count > maxReceiveBuffer {
            receiveBuffer.removeFirst(receiveBuffer.count - maxReceiveBuffer)
        }
    }

    private func handleDisconnect(_ error: Error?) {
        guard isConnected || isConnecting else { return }
        stopAutomation()
        isConnected = false
        isConnecting = false
        statusText = "连接意外断开"
        append(.system(error.map { "连接中断：\($0.localizedDescription)" } ?? "连接中断"))
        if let session = selectedSession { scheduleReconnectIfNeeded(session) }
    }

    private func scheduleReconnectIfNeeded(_ session: SerialSession) {
        guard session.autoReconnect, !manualDisconnect else { return }
        reconnectTask?.cancel()
        statusText = "等待重连…"
        reconnectTask = Task { [weak self] in
            let delay = UInt64(max(0.5, session.reconnectDelaySeconds) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    private func startAutomation(_ session: SerialSession) {
        if session.autoLoginEnabled, !session.loginSteps.isEmpty { startAutoLogin(session.loginSteps) }
        for command in session.autoCommands where command.enabled { runAutoCommand(command) }
    }

    private func stopAutomation() {
        loginTask?.cancel()
        loginTask = nil
        autoCommandTimers.values.forEach { $0.invalidate() }
        autoCommandTimers.removeAll()
        autoCommandCounts.removeAll()
    }

    private func startAutoLogin(_ steps: [AutoLoginStep]) {
        loginTask?.cancel()
        loginTask = Task { [weak self] in
            guard let self else { return }
            self.append(.system("开始自动登录"))
            for step in steps {
                guard !Task.isCancelled, self.isConnected else { return }
                if !step.waitFor.isEmpty {
                    let found = await self.waitForText(step.waitFor, timeout: step.timeoutSeconds)
                    if !found {
                        self.report("自动登录超时：未收到“\(step.waitFor)”")
                        return
                    }
                }
                if step.delayMilliseconds > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(step.delayMilliseconds) * 1_000_000)
                }
                do {
                    let data = try DataCodec.encode(step.send, mode: step.mode, lineEnding: step.lineEnding)
                    try self.serial.write(data)
                    self.append(LogEntry(timestamp: Date(), direction: .sent, data: data,
                                         message: step.secret ? "••••••（敏感命令）" : nil))
                } catch {
                    self.report("自动登录失败：\(error.localizedDescription)")
                    return
                }
            }
            self.append(.system("自动登录完成"))
        }
    }

    private func waitForText(_ text: String, timeout: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(max(0.1, timeout))
        while Date() < deadline {
            if String(decoding: receiveBuffer, as: UTF8.self).contains(text) { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
            if Task.isCancelled { return false }
        }
        return false
    }

    func append(_ entry: LogEntry) {
        retainedLogBytes += logCost(entry)
        logs.append(entry)
        guard logs.count > maxLogEntries || retainedLogBytes > maxLogBytes else { return }

        // Trim in batches to avoid O(n) removeFirst work on every high-rate
        // serial read after reaching the limit.
        var removeCount = 0
        var removedBytes = 0
        while logs.count - removeCount > 1,
              logs.count - removeCount > targetLogEntries ||
                retainedLogBytes - removedBytes > targetLogBytes {
            removedBytes += logCost(logs[removeCount])
            removeCount += 1
        }
        if removeCount > 0 {
            logs.removeFirst(removeCount)
            retainedLogBytes -= removedBytes
        }
    }

    private func logCost(_ entry: LogEntry) -> Int {
        entry.data.count + (entry.message?.utf8.count ?? 0) + 128
    }

    private func report(_ message: String) {
        lastError = message
        append(.system(message))
    }

    private func parityLetter(_ parity: Parity) -> String {
        switch parity { case .none: return "N"; case .odd: return "O"; case .even: return "E" }
    }

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private static let fileTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
