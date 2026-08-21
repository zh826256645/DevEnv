import SwiftUI

@MainActor
final class EnvironmentViewModel: ObservableObject {
    @Published private(set) var snapshot: MachineSnapshot?
    @Published private(set) var isScanning = false
    @Published private(set) var scanError: String?

    private let scanner = EnvironmentScanner()
    private let store = SnapshotStore()

    init() {
        snapshot = store.load()
        scan()
    }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        scanError = nil
        let scanner = scanner
        let store = store
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = scanner.scan()
            var persistenceError: Error?
            if result.canPersist {
                do { try store.save(result.snapshot) } catch { persistenceError = error }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if result.canPersist { self.snapshot = result.snapshot }
                if let persistenceError {
                    self.scanError = "快照保存失败：\(persistenceError.localizedDescription)"
                } else if !result.canPersist {
                    self.scanError = "无法读取 macOS 基础信息，本次未更新快照"
                }
                self.isScanning = false
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var model = EnvironmentViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let scanError = model.scanError {
                    Label(scanError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if model.isScanning && model.snapshot == nil {
                    ProgressView("正在扫描 macOS 系统环境…")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let snapshot = model.snapshot {
                    systemSection(snapshot.system)
                    runtimesSection(snapshot.runtimes)
                    homebrewSection(snapshot.homebrew)
                    pathSection(snapshot.path)
                    issuesSection(snapshot.issues)
                } else if !model.isScanning {
                    ContentUnavailableView("暂无快照", systemImage: "desktopcomputer", description: Text("点击“重新扫描”获取当前环境"))
                }
            }
            .padding(24)
        }
        .frame(minWidth: 720, minHeight: 560)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("系统环境扫描")
                    .font(.largeTitle.bold())
                if let scannedAt = model.snapshot?.scannedAt {
                    Text("最近扫描：\(scannedAt.formatted(date: .abbreviated, time: .shortened))")
                        .foregroundStyle(.secondary)
                } else {
                    Text("查看本机开发环境状态")
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                model.scan()
            } label: {
                Label(model.isScanning ? "扫描中…" : "重新扫描", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isScanning)
        }
    }

    private func systemSection(_ system: SystemSnapshot) -> some View {
        GroupBox("System") {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                row("macOS", value: system.macOSVersion ?? "读取失败")
                row("Build", value: system.build ?? "读取失败")
                row("架构", value: system.architecture ?? "读取失败")
                row("主机名", value: system.hostName)
                row("内存", value: byteCount(system.memoryBytes))
                row("系统卷", value: diskText(total: system.diskTotalBytes, free: system.diskFreeBytes))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func runtimesSection(_ runtimes: [RuntimeSnapshot]) -> some View {
        GroupBox("Runtimes") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(runtimes) { runtime in
                    HStack {
                        Text(runtime.name).fontWeight(.semibold)
                        if runtime.hasPathVersionConflict {
                            Text("PATH 版本冲突")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                        Text(runtime.state.label)
                            .font(.callout)
                            .foregroundStyle(runtime.state == .failed ? .orange : .secondary)
                    }
                    .padding(.vertical, 9)

                    if runtime.installations.isEmpty {
                        Text("未在当前 PATH 中发现")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 28)
                            .padding(.bottom, 9)
                    } else {
                        ForEach(runtime.installations) { installation in
                            runtimeInstallationRow(installation)
                                .padding(.leading, 12)
                                .padding(.bottom, 9)
                        }
                    }
                    if runtime.id != runtimes.last?.id { Divider() }
                }
            }
        }
    }

    private func runtimeInstallationRow(_ installation: RuntimeInstallation) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: installation.state == .discovered ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(installation.state == .discovered ? .green : .orange)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(installation.version ?? installation.error ?? "版本读取失败")
                    if installation.isEffective {
                        Text("Effective")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                }
                Text(installation.executable)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                if let actual = installation.actualExecutable {
                    Text("实际路径：\(actual)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .textSelection(.enabled)
            Spacer()
        }
    }

    private func homebrewSection(_ homebrew: HomebrewSnapshot) -> some View {
        GroupBox("Homebrew") {
            HStack {
                Image(systemName: homebrew.available ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(homebrew.available ? .green : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(homebrew.available ? (homebrew.version ?? "可用") : "未发现")
                    if let executable = homebrew.executable { Text(executable).font(.callout).foregroundStyle(.secondary) }
                    if let error = homebrew.error { Text(error).font(.callout).foregroundStyle(.orange) }
                }
                Spacer()
                Text(homebrew.available ? "可用" : "不可用")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func pathSection(_ path: [String]) -> some View {
        DisclosureGroup("PATH（\(path.count) 项）") {
            Text(path.isEmpty ? "未读取到 PATH" : path.joined(separator: "\n"))
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(.top, 8)
        }
    }

    @ViewBuilder
    private func issuesSection(_ issues: [String]) -> some View {
        if !issues.isEmpty {
            GroupBox("扫描提示") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(issues, id: \.self) { issue in
                        Label(issue, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func row(_ label: String, value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func byteCount(_ bytes: UInt64?) -> String {
        guard let bytes else { return "读取失败" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    private func diskText(total: UInt64?, free: UInt64?) -> String {
        guard let total, let free else { return "读取失败" }
        return "总计 \(byteCount(total))，可用 \(byteCount(free))"
    }
}

private extension RuntimeState {
    var label: String {
        switch self {
        case .discovered: return "已发现"
        case .unavailable: return "未发现"
        case .failed: return "读取失败"
        }
    }
}
