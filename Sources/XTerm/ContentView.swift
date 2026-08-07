import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingConfiguration = false
    @State private var showingAutomation = false

    var body: some View {
        NavigationSplitView {
            SessionSidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            if model.selectedSession != nil {
                TerminalView(showingConfiguration: $showingConfiguration,
                             showingAutomation: $showingAutomation)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "cable.connector").font(.system(size: 38)).foregroundStyle(.secondary)
                    Text("没有会话").font(.title2)
                    Text("请在左侧新建串口会话").foregroundStyle(.secondary)
                }
            }
        }
        .alert("XTerm", isPresented: Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.lastError = nil } }
        )) {
            Button("好") { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
        .sheet(isPresented: $showingConfiguration) {
            SessionConfigurationView()
                .environmentObject(model)
                .frame(minWidth: 620, minHeight: 560)
        }
        .sheet(isPresented: $showingAutomation) {
            AutomationView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 600)
        }
        .onDisappear {
            // A serial session must not continue receiving after its window is closed.
            model.shutdown()
        }
    }
}

private struct SessionSidebar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            List(selection: Binding(
                get: { model.store.selectedID },
                set: { model.selectSession($0) }
            )) {
                ForEach(model.store.sessions) { session in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Circle()
                                .fill(model.isConnected && model.store.selectedID == session.id ? .green : .secondary.opacity(0.4))
                                .frame(width: 8, height: 8)
                            Text(session.name).fontWeight(.medium).lineLimit(1)
                        }
                        Text(session.portPath.isEmpty ? "未选择端口" : "\(session.portPath) · \(session.baudRate)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 4)
                    .tag(session.id)
                    .contextMenu {
                        Button("复制会话") { model.store.duplicate(session.id) }
                        Divider()
                        Button("删除", role: .destructive) { model.store.remove(session.id) }
                    }
                }
            }
            Divider()
            HStack {
                Button { model.addSession() } label: { Image(systemName: "plus") }
                    .help("新建会话")
                Button {
                    if let id = model.store.selectedID { model.store.remove(id) }
                } label: { Image(systemName: "minus") }
                .disabled(model.store.selectedID == nil)
                .help("删除会话")
                Spacer()
                Button { model.refreshPorts() } label: { Image(systemName: "arrow.clockwise") }
                    .help("刷新串口")
            }
            .buttonStyle(.borderless)
            .padding(10)
        }
        .navigationTitle("串口会话")
    }
}

private struct TerminalView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var showingConfiguration: Bool
    @Binding var showingAutomation: Bool
    @State private var followTail = true

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            logArea
            Divider()
            sendArea
        }
        .navigationTitle(model.selectedSession?.name ?? "XTerm")
        .toolbar {
            ToolbarItemGroup {
                Button { showingConfiguration = true } label: { Label("串口配置", systemImage: "slider.horizontal.3") }
                Button { showingAutomation = true } label: { Label("自动化", systemImage: "clock.arrow.2.circlepath") }
                Button { model.toggleConnection() } label: {
                    Label(model.isConnected ? "断开" : "连接",
                          systemImage: model.isConnected ? "cable.connector.slash" : "cable.connector")
                }
                .buttonStyle(.borderedProminent)
                .tint(model.isConnected ? .red : .accentColor)
                .disabled(model.isConnecting)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Circle().fill(model.isConnected ? .green : model.isConnecting ? .orange : .secondary)
                .frame(width: 9, height: 9)
            Text(model.statusText).font(.caption).foregroundStyle(.secondary)
            if model.isRecordingLog {
                Label(model.recordingFileName, systemImage: "record.circle.fill")
                    .font(.caption).foregroundStyle(.red).lineLimit(1)
                    .help("正在实时保存日志")
            }
            Spacer()
            if model.selectedSession != nil {
                Picker("显示", selection: sessionBinding(\.receiveMode)) {
                    ForEach(DataMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 130)
                Toggle("时间戳", isOn: sessionBinding(\.timestampEnabled)).toggleStyle(.checkbox)
            }
            Toggle("跟随", isOn: $followTail).toggleStyle(.checkbox)
            Menu {
                Button("复制全部") { model.copyLog() }
                Button("导出日志…") { model.exportLog() }
                Divider()
                if model.isRecordingLog {
                    Button("停止实时保存") { model.stopRealtimeLog() }
                } else {
                    Button("实时保存为 CSV…") { model.startRealtimeLog() }
                }
                Divider()
                Button("清空") { model.clearLog() }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 12).frame(height: 40)
    }

    private var logArea: some View {
        Group {
            if model.selectedSession?.receiveMode == .ascii {
                SerialTerminalView(model: model)
            } else {
                hexLogArea
            }
        }
    }

    private var hexLogArea: some View {
        HexLogView(
            entries: model.logs,
            timestampEnabled: model.selectedSession?.timestampEnabled ?? true,
            followTail: followTail
        )
    }

    private var sendArea: some View {
        VStack(spacing: 8) {
            HStack {
                if let session = model.selectedSession {
                    Picker("发送格式", selection: sessionBinding(\.sendMode)) {
                        ForEach(DataMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).frame(width: 180)
                    Picker("行尾", selection: sessionBinding(\.lineEnding)) {
                        ForEach(LineEnding.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .frame(width: 130)
                    Picker("校验", selection: sessionBinding(\.checksum)) {
                        ForEach(ChecksumKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .frame(width: 190)
                    if session.checksum == .modbusCRC16 || session.checksum == .crc16CCITT {
                        Picker("字节序", selection: sessionBinding(\.checksumLittleEndian)) {
                            Text("低字节在前").tag(true)
                            Text("高字节在前").tag(false)
                        }.frame(width: 150)
                    }
                    Picker("编码", selection: sessionBinding(\.characterEncoding)) {
                        ForEach(CharacterEncoding.allCases) { Text($0.displayName).tag($0) }
                    }.frame(width: 165)
                }
                Spacer()
            }
            if model.isSendingFile {
                HStack(spacing: 8) {
                    ProgressView(value: model.fileSendProgress).frame(maxWidth: 240)
                    Text("正在发送 \(model.fileSendName) · \(Int(model.fileSendProgress * 100))%")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Button("取消") { model.cancelFileSend() }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextEditor(text: $model.sendText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 54, maxHeight: 100)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                Menu {
                    if let history = model.selectedSession?.sendHistory, !history.isEmpty {
                        ForEach(Array(history.prefix(20))) { item in
                            Button(historyTitle(item)) { model.restoreHistory(item) }
                        }
                        Divider()
                        Button("清空历史", role: .destructive) { model.clearSendHistory() }
                    } else {
                        Text("暂无发送历史")
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .help("发送历史")
                Button { model.chooseAndSendFile() } label: {
                    Label("文件", systemImage: "doc.badge.arrow.up")
                }
                .disabled(!model.isConnected || model.isSendingFile)
                .help("分块发送 TXT、CSV 或二进制文件")
                Button("发送") { model.sendCurrent() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.isConnected || model.sendText.isEmpty)
            }
        }
        .padding(12)
    }

    private func sessionBinding<T>(_ keyPath: WritableKeyPath<SerialSession, T>) -> Binding<T> {
        Binding {
            model.selectedSession![keyPath: keyPath]
        } set: { value in
            model.updateSelected { $0[keyPath: keyPath] = value }
        }
    }

    private func historyTitle(_ item: SendHistoryItem) -> String {
        let oneLine = item.payload.replacingOccurrences(of: "\n", with: "↵")
            .replacingOccurrences(of: "\r", with: "")
        let clipped = oneLine.count > 48 ? String(oneLine.prefix(48)) + "…" : oneLine
        return "[\(item.mode.rawValue)] \(clipped)"
    }
}
