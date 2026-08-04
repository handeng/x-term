import SwiftUI

struct SessionConfigurationView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var useCustomBaud = false
    private let standardBaudRates = [300, 600, 1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200, 230400]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("会话") {
                    TextField("名称", text: binding(\.name))
                }
                Section("串口") {
                    HStack {
                        Picker("设备", selection: binding(\.portPath)) {
                            if let path = model.selectedSession?.portPath,
                               !path.isEmpty, !model.ports.contains(where: { $0.path == path }) {
                                Text("\(path)（离线）").tag(path)
                            }
                            ForEach(model.ports) { Text("\($0.displayName)  —  \($0.path)").tag($0.path) }
                        }
                        Button { model.refreshPorts() } label: { Image(systemName: "arrow.clockwise") }
                    }
                    Picker("波特率", selection: baudRateChoice) {
                        ForEach(standardBaudRates, id: \.self) {
                            Text("\($0)").tag($0)
                        }
                        Divider()
                        Text("自定义…").tag(-1)
                    }
                    if useCustomBaud {
                        HStack {
                            TextField("自定义波特率", value: binding(\.baudRate),
                                      format: .number.grouping(.never))
                                .textFieldStyle(.roundedBorder)
                            Text("bps").foregroundStyle(.secondary)
                        }
                        Text("支持范围为 50～4,000,000 bps；最终可用值取决于串口设备和驱动。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Picker("数据位", selection: binding(\.dataBits)) {
                            Text("7").tag(7); Text("8").tag(8)
                        }
                        Picker("停止位", selection: binding(\.stopBits)) {
                            Text("1").tag(1); Text("2").tag(2)
                        }
                    }
                    Picker("校验位", selection: binding(\.parity)) {
                        ForEach(Parity.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("流控", selection: binding(\.flowControl)) {
                        ForEach(FlowControl.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                Section("连接与显示") {
                    Toggle("断线后自动重连", isOn: binding(\.autoReconnect))
                    if model.selectedSession?.autoReconnect == true {
                        HStack {
                            Text("重连间隔")
                            Slider(value: binding(\.reconnectDelaySeconds), in: 0.5...30, step: 0.5)
                            Text(String(format: "%.1f 秒", model.selectedSession?.reconnectDelaySeconds ?? 2))
                                .monospacedDigit().frame(width: 56)
                        }
                    }
                    Toggle("本地回显", isOn: binding(\.localEcho))
                    Toggle("显示时间戳", isOn: binding(\.timestampEnabled))
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Text("修改串口参数后需重新连接生效。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding()
        }
        .onAppear {
            if let baud = model.selectedSession?.baudRate {
                useCustomBaud = !standardBaudRates.contains(baud)
            }
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<SerialSession, T>) -> Binding<T> {
        Binding { model.selectedSession![keyPath: keyPath] }
        set: { value in model.updateSelected { $0[keyPath: keyPath] = value } }
    }

    private var baudRateChoice: Binding<Int> {
        Binding {
            guard let baud = model.selectedSession?.baudRate else { return 115200 }
            return useCustomBaud || !standardBaudRates.contains(baud) ? -1 : baud
        } set: { value in
            if value == -1 {
                useCustomBaud = true
                if let current = model.selectedSession?.baudRate,
                   standardBaudRates.contains(current) {
                    model.updateSelected { $0.baudRate = current }
                }
            } else {
                useCustomBaud = false
                model.updateSelected { $0.baudRate = value }
            }
        }
    }
}

struct AutomationView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("自动登录").tag(0)
                Text("自动发送").tag(1)
            }.pickerStyle(.segmented).frame(width: 280).padding()
            Divider()
            if tab == 0 { loginView } else { commandView }
            Divider()
            HStack {
                Text("最小自动发送间隔为 50 ms；有限次数填 1 或更大，0 表示持续发送。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding()
        }
    }

    private var loginView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("连接后执行自动登录", isOn: binding(\.autoLoginEnabled))
                .padding(.horizontal).padding(.top, 10)
            Text("每一步可先等待设备提示符，再发送内容。敏感步骤在终端日志中会被遮蔽。")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            List {
                ForEach(Array((model.selectedSession?.loginSteps ?? []).enumerated()), id: \.element.id) { index, _ in
                    LoginStepRow(step: loginStepBinding(index))
                }
                .onDelete { offsets in model.updateSelected { $0.loginSteps.remove(atOffsets: offsets) } }
            }
            HStack {
                Button("添加步骤") { model.updateSelected { $0.loginSteps.append(AutoLoginStep()) } }
                Spacer()
            }.padding([.horizontal, .bottom])
        }
    }

    private var commandView: some View {
        VStack(spacing: 8) {
            List {
                ForEach(Array((model.selectedSession?.autoCommands ?? []).enumerated()), id: \.element.id) { index, command in
                    AutoCommandRow(command: commandBinding(index))
                        .environmentObject(model)
                }
                .onDelete { offsets in model.updateSelected { $0.autoCommands.remove(atOffsets: offsets) } }
            }
            HStack {
                Button("添加命令") { model.updateSelected { $0.autoCommands.append(AutoCommand()) } }
                Spacer()
            }.padding([.horizontal, .bottom])
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<SerialSession, T>) -> Binding<T> {
        Binding { model.selectedSession![keyPath: keyPath] }
        set: { value in model.updateSelected { $0[keyPath: keyPath] = value } }
    }
    private func loginStepBinding(_ index: Int) -> Binding<AutoLoginStep> {
        Binding { model.selectedSession!.loginSteps[index] }
        set: { value in model.updateSelected { $0.loginSteps[index] = value } }
    }
    private func commandBinding(_ index: Int) -> Binding<AutoCommand> {
        Binding { model.selectedSession!.autoCommands[index] }
        set: { value in model.updateSelected { $0.autoCommands[index] = value } }
    }
}

private struct LoginStepRow: View {
    @Binding var step: AutoLoginStep
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("等待提示符（可留空）", text: $step.waitFor)
                TextField("发送内容", text: $step.send)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Picker("格式", selection: $step.mode) { ForEach(DataMode.allCases) { Text($0.rawValue).tag($0) } }
                Picker("行尾", selection: $step.lineEnding) { ForEach(LineEnding.allCases) { Text($0.rawValue).tag($0) } }
                Stepper("超时 \(step.timeoutSeconds, specifier: "%.1f") s", value: $step.timeoutSeconds, in: 0.5...60, step: 0.5)
                Stepper("延迟 \(step.delayMilliseconds) ms", value: $step.delayMilliseconds, in: 0...10_000, step: 50)
                Toggle("敏感", isOn: $step.secret).toggleStyle(.checkbox)
            }.font(.caption)
        }.padding(.vertical, 5)
    }
}

private struct AutoCommandRow: View {
    @EnvironmentObject private var model: AppModel
    @Binding var command: AutoCommand
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Toggle("", isOn: $command.enabled).labelsHidden().help("连接后自动启动")
                TextField("名称", text: $command.name).frame(width: 130)
                TextField("命令内容", text: $command.payload).font(.system(.body, design: .monospaced))
                Button(model.isAutoCommandRunning(command.id) ? "停止" : "运行") {
                    model.isAutoCommandRunning(command.id) ? model.stopAutoCommand(command.id) : model.runAutoCommand(command)
                }.disabled(!model.isConnected)
            }
            HStack {
                Picker("格式", selection: $command.mode) { ForEach(DataMode.allCases) { Text($0.rawValue).tag($0) } }
                Picker("行尾", selection: $command.lineEnding) { ForEach(LineEnding.allCases) { Text($0.rawValue).tag($0) } }
                Picker("校验", selection: $command.checksum) { ForEach(ChecksumKind.allCases) { Text($0.rawValue).tag($0) } }
                Stepper("间隔 \(command.intervalMilliseconds) ms", value: $command.intervalMilliseconds, in: 50...3_600_000, step: 50)
                Stepper("次数 \(command.repeatCount == 0 ? "∞" : "\(command.repeatCount)")",
                        value: $command.repeatCount, in: 0...1_000_000)
            }.font(.caption)
        }.padding(.vertical, 5)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        Form {
            Text("XTerm 会将会话配置保存在当前用户的 Application Support 目录。")
            Text("串口访问不启用 App Sandbox，以允许访问 /dev/cu.* 设备。")
        }.formStyle(.grouped).frame(width: 460, height: 160)
    }
}

struct AboutView: View {
    private let contactEmail = "andy@ywsy.net"

    var body: some View {
        VStack(spacing: 14) {
            if let image = NSImage(named: "XTerm") ?? NSImage(named: NSImage.applicationIconName) {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: 96, height: 96)
            }
            Text("XTerm").font(.title.bold())
            Text("版本 1.1.1").foregroundStyle(.secondary)
            Text("原生 macOS 串口终端")
            Link(contactEmail, destination: URL(string: "mailto:\(contactEmail)")!)
                .textSelection(.enabled)
            Link("GitHub 项目主页", destination: URL(string: "https://github.com/handeng/x-term")!)
            Text("Copyright © 2026 handeng\nGNU General Public License v3.0 or later")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(width: 420)
    }
}
