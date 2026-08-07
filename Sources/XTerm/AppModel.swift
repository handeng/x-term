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
    @Published var isSendingFile = false
    @Published var fileSendProgress = 0.0
    @Published var fileSendName = ""
    @Published var isRecordingLog = false
    @Published var recordingFileName = ""

    let store = SessionStore()
    private let serial = SerialPort()
    private var portRefreshTimer: Timer?
    private var autoCommandTimers: [UUID: Timer] = [:]
    private var autoCommandCounts: [UUID: Int] = [:]
    private var reconnectTask: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?
    private var fileSendTask: Task<Void, Never>?
    private var receiveBuffer = Data()
    private var triggerLastFired: [UUID: Date] = [:]
    private var manualDisconnect = false
    private var activeConnectionID: SerialPort.ConnectionID?
    private var cancellables: Set<AnyCancellable> = []
    private var terminalHandler: ((Data?) -> Void)?
    private let terminalTranscoder = TerminalTextTranscoder()
    private let logTextTranscoder = TerminalTextTranscoder()
    private let logRecorder = RealtimeLogRecorder()
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
        serial.onData = { [weak self] data, connectionID in
            guard let self,
                  self.isConnected,
                  self.activeConnectionID == connectionID else { return }
            self.handleReceived(data)
        }
        serial.onDisconnect = { [weak self] connectionID, error in
            guard let self, self.activeConnectionID == connectionID else { return }
            self.handleDisconnect(error, connectionID: connectionID)
        }
        serial.onReceiveOverflow = { [weak self] droppedBytes, connectionID in
            guard let self, self.activeConnectionID == connectionID else { return }
            self.append(.system("界面处理速度不足，已丢弃 \(droppedBytes) 字节接收数据以保护内存"))
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
        fileSendTask?.cancel()
        autoCommandTimers.values.forEach { $0.invalidate() }
        logRecorder.stop()
    }

    func addSession() { store.add() }

    func selectSession(_ id: UUID?) {
        guard store.selectedID != id else { return }
        if isRecordingLog { stopRealtimeLog() }
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
            let connectionID = try serial.open(session: session)
            activeConnectionID = connectionID
            isConnected = true
            isConnecting = false
            let stopBits = session.dataBits == 5 && session.stopBits == 2 ? "1.5" : "\(session.stopBits)"
            statusText = "已连接 · \(session.portPath) · \(session.baudRate) \(session.dataBits)\(parityLetter(session.parity))\(stopBits)"
            append(.system("已连接 \(session.portPath) @ \(session.baudRate) bps"))
            triggerLastFired.removeAll()
            terminalTranscoder.reset()
            startAutomation(session)
        } catch {
            isConnecting = false
            report(error.localizedDescription)
            scheduleReconnectIfNeeded(session)
        }
    }

    func disconnect() {
        manualDisconnect = true
        activeConnectionID = nil
        reconnectTask?.cancel()
        stopAutomation()
        cancelFileSend()
        serial.close()
        if isConnected { append(.system("连接已断开")) }
        isConnected = false
        isConnecting = false
        statusText = "未连接"
    }

    func shutdown() {
        disconnect()
        stopRealtimeLog()
    }

    func sendCurrent() {
        guard let session = selectedSession else { return }
        do {
            let payload = sendText
            let raw = try DataCodec.encode(payload, mode: session.sendMode, lineEnding: session.lineEnding,
                                           encoding: session.characterEncoding)
            let packet = Checksum.append(to: raw, kind: session.checksum, littleEndian: session.checksumLittleEndian)
            try send(packet, localEcho: session.localEcho)
            recordHistory(payload: payload, session: session)
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
        terminalTranscoder.reset()
        terminalHandler?(nil)
    }

    func restoreHistory(_ item: SendHistoryItem) {
        sendText = item.payload
        updateSelected {
            $0.sendMode = item.mode
            $0.lineEnding = item.lineEnding
            $0.checksum = item.checksum
        }
    }

    func clearSendHistory() {
        updateSelected { $0.sendHistory.removeAll() }
    }

    /// Attaches the visible VT terminal. Existing RX data is replayed so switching
    /// between HEX and terminal modes does not lose the current screen contents.
    func setTerminalHandler(_ handler: ((Data?) -> Void)?) {
        terminalHandler = handler
        guard let handler else { return }
        terminalTranscoder.reset()
        handler(nil)
        let encoding = selectedSession?.characterEncoding ?? .utf8
        for entry in logs where entry.direction == .received {
            handler(terminalTranscoder.transcode(entry.data, encoding: encoding))
        }
    }

    func copyLog() {
        guard let session = selectedSession else { return }
        let transcoder = TerminalTextTranscoder()
        let text = logs.map { entry -> String in
            let time = session.timestampEnabled ? "\(Self.timestamp.string(from: entry.timestamp)) " : ""
            if let message = entry.message { return "\(time)[\(entry.direction.rawValue)] \(message)" }
            return "\(time)[\(entry.direction.rawValue)] \(logValue(entry, session: session, transcoder: transcoder))"
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func exportLog() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "xterm-\(Self.fileTimestamp.string(from: Date())).log"
        guard panel.runModal() == .OK, let url = panel.url, let session = selectedSession else { return }
        let transcoder = TerminalTextTranscoder()
        let text = logs.map {
            "\(Self.timestamp.string(from: $0.timestamp)) [\($0.direction.rawValue)] \($0.message ?? logValue($0, session: session, transcoder: transcoder))"
        }.joined(separator: "\n")
        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { report("导出失败：\(error.localizedDescription)") }
    }

    func chooseAndSendFile() {
        guard isConnected else { report("请先连接串口"); return }
        guard !isSendingFile else { return }
        let panel = NSOpenPanel()
        panel.title = "选择要发送的文件"
        panel.message = "TXT、CSV 和二进制文件均按原始字节分块发送。"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        startFileSend(url)
    }

    func cancelFileSend() {
        fileSendTask?.cancel()
        fileSendTask = nil
        isSendingFile = false
        fileSendProgress = 0
        fileSendName = ""
    }

    func startRealtimeLog() {
        guard !isRecordingLog else { return }
        let panel = NSSavePanel()
        panel.title = "实时保存串口日志"
        panel.nameFieldStringValue = "xterm-\(Self.fileTimestamp.string(from: Date())).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            logTextTranscoder.reset()
            try logRecorder.start(url: url)
            isRecordingLog = true
            recordingFileName = url.lastPathComponent
            append(.system("开始实时保存日志：\(url.lastPathComponent)"))
        } catch {
            report("无法开始保存日志：\(error.localizedDescription)")
        }
    }

    func stopRealtimeLog() {
        guard isRecordingLog else { return }
        append(.system("实时日志保存结束"))
        isRecordingLog = false
        recordingFileName = ""
        logRecorder.stop()
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
            let session = selectedSession
            let raw = try DataCodec.encode(command.payload, mode: command.mode, lineEnding: command.lineEnding,
                                           encoding: session?.characterEncoding ?? .utf8)
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
        if let terminalHandler {
            terminalHandler(terminalTranscoder.transcode(
                data, encoding: selectedSession?.characterEncoding ?? .utf8
            ))
        }
        receiveBuffer.append(data)
        if receiveBuffer.count > maxReceiveBuffer {
            receiveBuffer.removeFirst(receiveBuffer.count - maxReceiveBuffer)
        }
        evaluateReceiveTriggers()
    }

    private func handleDisconnect(_ error: Error?, connectionID: SerialPort.ConnectionID) {
        guard activeConnectionID == connectionID, isConnected || isConnecting else { return }
        activeConnectionID = nil
        stopAutomation()
        cancelFileSend()
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
                    let data = try DataCodec.encode(step.send, mode: step.mode, lineEnding: step.lineEnding,
                                                    encoding: self.selectedSession?.characterEncoding ?? .utf8)
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
            let encoding = selectedSession?.characterEncoding ?? .utf8
            if DataCodec.display(receiveBuffer, mode: .ascii, encoding: encoding).contains(text) { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
            if Task.isCancelled { return false }
        }
        return false
    }

    func append(_ entry: LogEntry) {
        if isRecordingLog, let session = selectedSession {
            logRecorder.enqueue(csvLine(for: entry, session: session))
        }
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

    private func recordHistory(payload: String, session: SerialSession) {
        guard !payload.isEmpty else { return }
        let item = SendHistoryItem(timestamp: Date(), payload: payload, mode: session.sendMode,
                                   lineEnding: session.lineEnding, checksum: session.checksum)
        updateSelected {
            $0.sendHistory.removeAll {
                $0.payload == item.payload && $0.mode == item.mode &&
                    $0.lineEnding == item.lineEnding && $0.checksum == item.checksum
            }
            $0.sendHistory.insert(item, at: 0)
            if $0.sendHistory.count > 100 { $0.sendHistory.removeLast($0.sendHistory.count - 100) }
        }
    }

    private func startFileSend(_ url: URL) {
        guard let session = selectedSession else { return }
        let chunkSize = min(max(session.fileChunkSize, 64), 65_536)
        let delay = min(max(session.fileChunkDelayMilliseconds, 0), 60_000)
        isSendingFile = true
        fileSendProgress = 0
        fileSendName = url.lastPathComponent
        append(.system("开始发送文件：\(url.lastPathComponent)"))

        fileSendTask = Task { [weak self] in
            guard let self else { return }
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let total = try handle.seekToEnd()
                try handle.seek(toOffset: 0)
                var sent: UInt64 = 0
                while !Task.isCancelled, self.isConnected,
                      let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                    try await self.serial.writeAsync(chunk)
                    guard !Task.isCancelled else { throw CancellationError() }
                    sent += UInt64(chunk.count)
                    self.append(LogEntry(timestamp: Date(), direction: .sent, data: chunk, message: nil))
                    self.fileSendProgress = total == 0 ? 1 : Double(sent) / Double(total)
                    if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000) }
                }
                if Task.isCancelled || !self.isConnected {
                    self.append(.system("文件发送已取消：\(url.lastPathComponent)"))
                } else {
                    self.append(.system("文件发送完成：\(url.lastPathComponent)，共 \(sent) 字节"))
                }
            } catch is CancellationError {
                self.append(.system("文件发送已取消：\(url.lastPathComponent)"))
            } catch {
                self.report("文件发送失败：\(error.localizedDescription)")
            }
            self.fileSendTask = nil
            self.isSendingFile = false
            self.fileSendProgress = 0
            self.fileSendName = ""
        }
    }

    private func evaluateReceiveTriggers() {
        guard let session = selectedSession else { return }
        let now = Date()
        for rule in session.receiveTriggers where rule.enabled && !rule.matchPayload.isEmpty {
            do {
                let marker = try DataCodec.encode(rule.matchPayload, mode: rule.matchMode,
                                                  encoding: session.characterEncoding)
                guard !marker.isEmpty, receiveBuffer.suffix(marker.count) == marker else { continue }
                let cooldown = Double(max(0, rule.cooldownMilliseconds)) / 1_000
                if let last = triggerLastFired[rule.id], now.timeIntervalSince(last) < cooldown { continue }
                triggerLastFired[rule.id] = now
                let response = try DataCodec.encode(rule.responsePayload, mode: rule.responseMode,
                                                    lineEnding: rule.responseLineEnding,
                                                    encoding: session.characterEncoding)
                let packet = Checksum.append(to: response, kind: rule.checksum,
                                             littleEndian: session.checksumLittleEndian)
                try send(packet)
            } catch {
                report("触发规则“\(rule.name)”失败：\(error.localizedDescription)")
            }
        }
    }

    private func csvLine(for entry: LogEntry, session: SerialSession) -> Data {
        let mode: DataMode = entry.direction == .sent ? session.sendMode : session.receiveMode
        let value: String
        if let message = entry.message {
            value = message
        } else if entry.direction == .received, mode == .ascii {
            value = String(decoding: logTextTranscoder.transcode(
                entry.data, encoding: session.characterEncoding
            ), as: UTF8.self)
        } else {
            value = DataCodec.display(entry.data, mode: mode, encoding: session.characterEncoding)
        }
        let fields = [Self.csvTimestamp.string(from: entry.timestamp), entry.direction.rawValue,
                      entry.message == nil ? mode.rawValue : "文本", value]
        return Data((fields.map(csvEscape).joined(separator: ",") + "\n").utf8)
    }

    private func logValue(_ entry: LogEntry, session: SerialSession,
                          transcoder: TerminalTextTranscoder) -> String {
        let mode = entry.direction == .sent ? session.sendMode : session.receiveMode
        if entry.direction == .received, mode == .ascii {
            return String(decoding: transcoder.transcode(
                entry.data, encoding: session.characterEncoding
            ), as: UTF8.self)
        }
        return DataCodec.display(entry.data, mode: mode, encoding: session.characterEncoding)
    }

    private func csvEscape(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
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

    private static let csvTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
}
