# XTerm

XTerm 是原生 macOS 串口终端，采用左侧会话列表、右侧终端工作区布局。最低支持 macOS 13，可构建为同时支持 Intel（x86_64）和 Apple Silicon（arm64）的通用应用。

本项目采用 [GNU General Public License v3.0 或更高版本](LICENSE) 开源。
终端渲染使用 MIT 许可的 SwiftTerm，详见[第三方软件声明](THIRD_PARTY_NOTICES.md)。

## 下载

从 [GitHub Releases](https://github.com/handeng/x-term/releases/latest) 下载最新的 macOS Universal 压缩包，解压后将 `XTerm.app` 移入“应用程序”文件夹。

当前公开构建采用 ad-hoc 签名，尚未经过 Apple notarization。macOS 如果阻止首次打开，可在 Finder 中右键应用并选择“打开”；仅从本仓库的 Releases 页面获取构建。

## 功能

- 会话新增、复制、删除及自动持久化
- 串口热插拔扫描，支持常用及自定义波特率、7/8 数据位、1/2 停止位、奇偶校验和软/硬流控
- 意外断线自动重连
- ASCII/HEX 发送与显示、CR/LF/CRLF 行尾、本地回显
- VT100/xterm 流式终端渲染，支持 ANSI 颜色、光标控制、跨数据块 UTF-8 和控制序列
- RX/TX/SYS 分向日志、毫秒时间戳、跟随尾部、复制和导出
- 自动登录步骤：等待提示符、超时、延迟、ASCII/HEX 和敏感日志遮蔽
- 多条自动发送任务：连接后启动、发送间隔、有限/无限次数
- RS-485 常用校验：CRC-16/Modbus、CRC-16/CCITT-FALSE、LRC、SUM8、XOR8，CRC 字节序可选

## 开发与测试

```bash
swift test
swift run XTerm
```

也可直接在 Xcode 中打开 `Package.swift`，选择 XTerm scheme 运行。

## 构建 Intel + Apple Silicon 通用应用

```bash
chmod +x scripts/build-universal.sh
scripts/build-universal.sh
```

产物位于 `dist/XTerm.app`。脚本采用 ad-hoc 签名，内部部署可直接使用；对外分发应使用 Apple Developer ID 签名并完成 notarization。

## 串口与安全说明

- 应用直接访问 `/dev/cu.*`，因此不启用 App Sandbox。首次连接失败时，检查设备是否被其他程序占用以及 USB 串口驱动是否正常。
- 自动登录中标记为“敏感”的发送内容保存在 macOS Keychain；会话 JSON 和终端日志中均不保存明文。
- 修改串口参数后断开并重新连接生效。
- 高速持续数据场景按 8 MB 原始负载和 4,000 条记录双重限制日志，并分批回收，避免内存持续增长。
- 接收任务采用有界批处理和连接代际隔离；断开连接会立即丢弃待显示数据，关闭最后一个窗口会终止应用并释放串口。

## 反馈

发现问题时请提交 [GitHub Issue](https://github.com/handeng/x-term/issues)，并附上 macOS 版本、芯片类型、USB 串口芯片型号、波特率及复现步骤。请勿在日志中提交密码或其他敏感信息。
