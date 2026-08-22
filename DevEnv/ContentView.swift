import AppKit
import SwiftUI

@MainActor
final class EnvironmentViewModel: ObservableObject {
    @Published private(set) var snapshot: MachineSnapshot?
    @Published private(set) var isScanning = false
    @Published private(set) var scanError: String?
    @Published private(set) var isShowingStaleSnapshot = false

    private let scanner = EnvironmentScanner()
    private let store = SnapshotStore()

    init() {
        snapshot = store.load()
        scan()
    }

    func scan() {
        guard !isScanning else { return }
        let hadSnapshot = snapshot != nil
        isScanning = true
        scanError = nil
        isShowingStaleSnapshot = false
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
                    self.isShowingStaleSnapshot = hadSnapshot
                }
                self.isScanning = false
            }
        }
    }
}

struct ContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var model = EnvironmentViewModel()
    @State private var copiedPath: String?
    @State private var hoveredPath: String?
    @State private var expandedRuntimeID: String?
    @State private var fullyShownRuntimeID: String?
    @State private var isPathExpanded = false
    @State private var isShowingNotifications = false
    @State private var readNoticeSnapshotDate: Date?
    @FocusState private var focusedCopyPath: String?

    var body: some View {
        Group {
            if let snapshot = model.snapshot {
                overview(snapshot)
            } else if model.isScanning {
                loadingView
            } else {
                unavailableView
            }
        }
        .frame(minWidth: 720, minHeight: 560)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    isShowingNotifications.toggle()
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "bell")
                        if hasUnreadNotices {
                            Circle()
                                .fill(.red)
                                .frame(width: 7, height: 7)
                                .offset(x: 4, y: -3)
                        }
                    }
                    .frame(width: 20, height: 20)
                }
                .accessibilityLabel(hasUnreadNotices
                    ? "通知，当前有未读扫描提示"
                    : "通知")
                .help("通知")
                .popover(isPresented: $isShowingNotifications) {
                    notificationsPopover(currentNotices)
                        .onAppear(perform: markCurrentNoticesRead)
                }

                Button(action: model.scan) {
                    if model.isScanning {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("扫描中…")
                        }
                    } else {
                        Label("重新扫描", systemImage: "arrow.clockwise")
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isScanning)
            }
        }
    }

    private func overview(_ snapshot: MachineSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(snapshot)
                if let scanError = model.scanError {
                    scanErrorBanner(scanError, snapshot: snapshot)
                }
                topOverviewSection(snapshot)
                runtimesSection(snapshot.runtimes)
                localServicesSection(snapshot.localServices)
                environmentSection(snapshot)
            }
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
            .padding(28)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
            Text("正在读取系统信息…")
                .font(.title2.bold())
            Text("首次扫描完成后，将在此展示开发环境总览")
                .foregroundStyle(.secondary)
            ProgressView()
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private var unavailableView: some View {
        ContentUnavailableView {
            Label("无法读取系统信息", systemImage: "exclamationmark.triangle")
        } description: {
            Text(model.scanError ?? "尚未生成 Machine Snapshot")
        } actions: {
            Button("重新扫描", action: model.scan)
                .buttonStyle(.borderedProminent)
        }
    }

    private func header(_ snapshot: MachineSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("开发环境总览")
                .font(.largeTitle.bold())
            HStack(spacing: 10) {
                Text("最近扫描：\(formatted(snapshot.scannedAt))")
                    .foregroundStyle(.secondary)
                if model.isScanning {
                    Label("正在更新", systemImage: "arrow.triangle.2.circlepath")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func scanErrorBanner(_ error: String, snapshot: MachineSnapshot) -> some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.isShowingStaleSnapshot
                        ? "更新失败，当前显示 \(formatted(snapshot.scannedAt)) 的扫描结果"
                        : "扫描结果未能持久化")
                        .fontWeight(.semibold)
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("重新扫描", action: model.scan)
                    .disabled(model.isScanning)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func topOverviewSection(_ snapshot: MachineSnapshot) -> some View {
        HStack(alignment: .top, spacing: 14) {
            systemSection(snapshot.system)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            summarySection(snapshot)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.primary.opacity(0.018))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.primary.opacity(0.08))
                }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func topOverviewCard<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24, height: 24)
                Text(title)
                    .font(.title3.bold())
            }
            .padding(.leading, 4)

            content()
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.primary.opacity(0.10))
                        }
                        .shadow(color: .black.opacity(0.035), radius: 8, y: 3)
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func summarySection(_ snapshot: MachineSnapshot) -> some View {
        let discoveredCount = snapshot.runtimes.filter { $0.state == .discovered }.count
        let installationCount = snapshot.runtimes.reduce(0) { $0 + $1.installations.count }
        let noticeCount = scanNotices(in: snapshot).count

        return topOverviewCard("扫描汇总", systemImage: "chart.bar.fill") {
            VStack(spacing: 12) {
                summaryMetric(discoveredCount, label: "已发现 Runtime 类别", systemImage: "magnifyingglass")
                summaryMetric(installationCount, label: "Runtime Installation", systemImage: "arrow.down.to.line.compact")
                summaryMetric(noticeCount, label: "扫描提示", systemImage: "lightbulb.max")
            }
        }
    }

    private func summaryMetric(_ value: Int, label: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.10))
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 42, height: 42)
            .accessibilityHidden(true)

            Text(label)
                .font(.callout)
            Spacer(minLength: 8)
            Text(value.formatted())
                .font(.title2.bold())
                .monospacedDigit()
                .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 64)
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.primary.opacity(0.012))
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(Color.primary.opacity(0.08))
                }
        }
        .accessibilityElement(children: .combine)
    }

    private func runtimesSection(_ runtimes: [RuntimeSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.primary)
                    Image(systemName: "terminal")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                }
                .frame(width: 30, height: 30)

                Text("Runtime")
                    .font(.title2.bold())
            }

            if let expandedRuntimeID,
               let expandedIndex = runtimes.firstIndex(where: { $0.id == expandedRuntimeID }) {
                runtimeCard(runtimes[expandedIndex])
                runtimeGrid(runtimes.filter { $0.id != expandedRuntimeID })
            } else {
                runtimeGrid(runtimes)
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.018))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.primary.opacity(0.08))
                }
        }
    }

    private func runtimeGrid(_ runtimes: [RuntimeSnapshot]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 14, alignment: .top)],
            alignment: .leading,
            spacing: 14
        ) {
            ForEach(runtimes) { runtime in
                runtimeCard(runtime)
            }
        }
    }

    private func localServicesSection(_ services: [LocalServiceSnapshot]) -> some View {
        let portCount = services.reduce(0) { $0 + Set($1.bindings.map(\.port)).count }

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "network")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 28, height: 28)
                Text("本地服务")
                    .font(.title3.bold())
                Spacer()
                Text("\(services.count) 个服务 · \(portCount) 个端口")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if services.isEmpty {
                ContentUnavailableView("未发现可见的 TCP 监听服务", systemImage: "network.slash")
                    .frame(maxWidth: .infinity, minHeight: 110)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(services.enumerated()), id: \.element.id) { index, service in
                        localServiceRow(service)
                        if index < services.count - 1 { Divider() }
                    }
                }
                .padding(.horizontal, 16)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.primary.opacity(0.09))
                        }
                }
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.018))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.primary.opacity(0.08))
                }
        }
    }

    private func localServiceRow(_ service: LocalServiceSnapshot) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "server.rack")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(service.processName)
                    .font(.headline)
                Text("PID \(service.pid)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: 16)

            VStack(alignment: .trailing, spacing: 7) {
                ForEach(service.bindings, id: \.self) { binding in
                    HStack(spacing: 8) {
                        Text(binding.family.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(listenerBindingText(binding))
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(.vertical, 14)
    }

    private func listenerBindingText(_ binding: ListenerBinding) -> String {
        let address = binding.family == .ipv6 ? "[\(binding.address)]" : binding.address
        return "\(address):\(binding.port)"
    }

    private func runtimeCard(_ runtime: RuntimeSnapshot) -> some View {
        let isExpanded = expandedRuntimeID == runtime.id
        let status = runtimeCardStatus(runtime)
        let showsAllInstallations = fullyShownRuntimeID == runtime.id
        let visibleInstallations = showsAllInstallations
            ? runtime.installations
            : Array(runtime.installations.prefix(3))

        return VStack(alignment: .leading, spacing: 0) {
            if runtime.installations.isEmpty {
                runtimeSummary(runtime)
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        toggleRuntime(runtime.id)
                    } label: {
                        runtimeSummary(runtime)
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(isExpanded ? "已展开" : "已折叠")

                    if isExpanded {
                        Divider()
                            .padding(.vertical, 10)
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(visibleInstallations) { installation in
                                runtimeInstallationRow(installation)
                            }
                            if runtime.installations.count > 3 {
                                Button {
                                    toggleInstallationLimit(runtime.id)
                                } label: {
                                    Label(
                                        showsAllInstallations
                                            ? "收起至 3 个安装路径"
                                            : "展开其余 \(runtime.installations.count - 3) 个安装路径",
                                        systemImage: showsAllInstallations ? "chevron.up" : "chevron.down"
                                    )
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .padding(.bottom, 8)
                        .transition(.opacity)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(status.color.opacity(isExpanded ? 0.10 : 0.035))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(status.color.opacity(isExpanded ? 0.50 : 0.25))
                }
        }
        .shadow(color: .black.opacity(0.025), radius: 8, y: 3)
    }

    private func runtimeSummary(_ runtime: RuntimeSnapshot) -> some View {
        let brand = runtimeBrand(runtime)
        let status = runtimeCardStatus(runtime)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(brand.color.opacity(0.10))
                    Image(brand.assetName)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(brand.color)
                        .padding(8)
                }
                .frame(width: 46, height: 46)
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(brand.color.opacity(0.12))
                }
                .accessibilityHidden(true)

                Spacer(minLength: 0)

                ZStack {
                    Circle()
                        .fill(status.color.opacity(0.13))
                    Image(systemName: status.badgeSymbol)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(status.color)
                }
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            }

            Text(runtime.name)
                .font(.headline)

            Text(effectiveVersion(for: runtime))
                .font(.title2.bold())
                .monospacedDigit()
                .foregroundStyle(runtime.state == .failed ? .orange : .primary)

            Label(
                runtime.installations.isEmpty
                    ? "未发现 Runtime Installation"
                    : "\(runtime.installations.count) 个安装",
                systemImage: "square.stack.3d.up.fill"
            )
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            HStack(spacing: 5) {
                Label(status.title, systemImage: status.pillSymbol)
                if let explanation = status.explanation {
                    helpIcon(explanation)
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(status.color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(status.color.opacity(0.10), in: Capsule())
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
    }

    private func runtimeCardStatus(_ runtime: RuntimeSnapshot) -> (
        title: String,
        badgeSymbol: String,
        pillSymbol: String,
        color: Color,
        explanation: String?
    ) {
        if runtime.hasPathVersionConflict {
            return (
                "PATH 版本冲突",
                "exclamationmark.triangle.fill",
                "exclamationmark.triangle.fill",
                .orange,
                "当前 PATH 中存在该 Runtime 的多个不同版本。终端默认使用 PATH 顺序最靠前的版本，其他工具或项目可能解析到不同版本。"
            )
        }
        if runtime.state == .failed {
            return (
                "读取失败",
                "exclamationmark.triangle.fill",
                "exclamationmark.circle.fill",
                .orange,
                "已找到 Runtime，但无法读取可用版本。常见原因包括命令超时、文件不可执行或版本输出无法识别。"
            )
        }
        if runtime.state == .discovered {
            return ("已安装", "checkmark", "checkmark.circle.fill", .green, nil)
        }
        return ("未发现", "questionmark", "circle.fill", .secondary, nil)
    }

    private func runtimeBrand(_ runtime: RuntimeSnapshot) -> (assetName: String, color: Color) {
        switch runtime.name {
        case "Node.js": ("RuntimeNodeLogo", Color(red: 0.37, green: 0.63, blue: 0.31))
        case "Python": ("RuntimePythonLogo", Color(red: 0.22, green: 0.46, blue: 0.67))
        case "Go": ("RuntimeGoLogo", Color(red: 0, green: 0.68, blue: 0.85))
        case "Java": ("RuntimeJavaLogo", Color(red: 0.26, green: 0.45, blue: 0.57))
        case "Rust": ("RuntimeRustLogo", .primary)
        case "Ruby": ("RuntimeRubyLogo", Color(red: 0.80, green: 0.20, blue: 0.18))
        case "Lua": ("RuntimeLuaLogo", Color(red: 0.17, green: 0.18, blue: 0.45))
        default: ("RuntimeNodeLogo", .secondary)
        }
    }

    private func toggleRuntime(_ id: String) {
        let nextID = expandedRuntimeID == id ? nil : id
        if reduceMotion {
            expandedRuntimeID = nextID
            fullyShownRuntimeID = nil
        } else {
            withAnimation(.smooth(duration: 0.32)) {
                expandedRuntimeID = nextID
                fullyShownRuntimeID = nil
            }
        }
    }

    private func toggleInstallationLimit(_ id: String) {
        let nextID = fullyShownRuntimeID == id ? nil : id
        if reduceMotion {
            fullyShownRuntimeID = nextID
        } else {
            withAnimation(.snappy(duration: 0.25, extraBounce: 0.02)) {
                fullyShownRuntimeID = nextID
            }
        }
    }

    private func runtimeInstallationRow(_ installation: RuntimeInstallation) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: installation.state == .discovered ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(installation.state == .discovered ? .green : .orange)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(installation.version ?? installation.error ?? "版本读取失败")
                    if installation.state == .failed {
                        helpIcon("该安装已被发现，但版本读取失败或可执行文件不可用；它不会阻止其他 Runtime Installation 继续扫描。")
                    }
                    if installation.isEffective {
                        Text("当前生效")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                }
                copyablePath(installation.executable)
                if let actual = installation.actualExecutable {
                    copyablePath(actual, prefix: "实际路径")
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func helpIcon(_ explanation: String) -> some View {
        RuntimeHelpIcon(explanation: explanation)
            .frame(width: 16, height: 16)
    }

    private func environmentSection(_ snapshot: MachineSnapshot) -> some View {
        let pathWarningCount = snapshot.runtimes.filter(\.hasPathVersionConflict).count

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 28, height: 28)
                Text("环境配置")
                    .font(.title3.bold())
            }

            HStack(alignment: .top, spacing: 14) {
                homebrewCard(snapshot.homebrew)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                pathCard(snapshot.path, warningCount: pathWarningCount)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .fixedSize(horizontal: false, vertical: true)

            if isPathExpanded {
                pathDetails(snapshot.path)
                    .transition(.opacity)
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.018))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.primary.opacity(0.08))
                }
        }
    }

    private func homebrewCard(_ homebrew: HomebrewSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.green.opacity(0.09))
                    Image(systemName: "shippingbox")
                        .font(.system(size: 23, weight: .medium))
                }
                .frame(width: 54, height: 54)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.primary.opacity(0.07))
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Homebrew")
                        .font(.headline)
                    Text(homebrew.available ? (homebrew.version ?? "可用") : "未发现")
                        .font(.title2.bold())
                        .monospacedDigit()
                    Text("包管理器")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Image(systemName: homebrew.available ? "checkmark" : "questionmark")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(homebrew.available ? Color.green : Color.secondary)
                    .frame(width: 38, height: 38)
                    .background((homebrew.available ? Color.green : Color.secondary).opacity(0.10), in: Circle())
            }

            if homebrew.available {
                Text("已安装")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.10), in: Capsule())
            }

            Divider()

            if let executable = homebrew.executable {
                copyablePath(executable)
            } else if let error = homebrew.error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else {
                Text("未发现 Homebrew 可执行文件")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.primary.opacity(0.09))
                }
        }
    }

    private func pathCard(_ path: [String], warningCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor.opacity(0.09))
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 23, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 54, height: 54)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.primary.opacity(0.07))
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text("PATH")
                            .font(.headline)
                        Text("\(path.count) 项")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.055), in: Capsule())
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(path.count.formatted())
                            .font(.title2.bold())
                            .monospacedDigit()
                            .foregroundStyle(path.isEmpty ? Color.secondary : Color.green)
                        Text("个目录")
                            .font(.callout)
                        if warningCount > 0 {
                            Text("·")
                                .foregroundStyle(.secondary)
                            Text(warningCount.formatted())
                                .font(.title3.bold())
                                .monospacedDigit()
                                .foregroundStyle(.orange)
                            Text("个冲突")
                                .font(.callout)
                        }
                    }
                    Text("环境变量路径扫描")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack(spacing: 8) {
                Label(path.isEmpty ? "未读取" : "\(path.count) 个目录", systemImage: path.isEmpty ? "circle" : "checkmark.circle.fill")
                    .foregroundStyle(path.isEmpty ? Color.secondary : Color.green)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background((path.isEmpty ? Color.secondary : Color.green).opacity(0.10), in: Capsule())

                if warningCount > 0 {
                    Label("\(warningCount) 个冲突", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.10), in: Capsule())
                }

                Spacer(minLength: 4)

                Button {
                    if reduceMotion {
                        isPathExpanded.toggle()
                    } else {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isPathExpanded.toggle()
                        }
                    }
                } label: {
                    Label(isPathExpanded ? "收起" : "查看全部", systemImage: isPathExpanded ? "arrow.up" : "arrow.right")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
            }
            .font(.caption.weight(.semibold))
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.primary.opacity(0.09))
                }
        }
    }

    private func pathDetails(_ path: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PATH 详情")
                .font(.headline)
            if path.isEmpty {
                Text("未读取到 PATH")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(path.enumerated()), id: \.offset) { index, entry in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 22, alignment: .trailing)
                        copyablePath(entry)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.45))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.primary.opacity(0.08))
                }
        }
    }

    private func systemSection(_ system: SystemSnapshot) -> some View {
        topOverviewCard("系统信息", systemImage: "desktopcomputer") {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 18) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.primary.opacity(0.055))
                        Image(systemName: "apple.logo")
                            .font(.system(size: 34, weight: .medium))
                    }
                    .frame(width: 76, height: 76)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.primary.opacity(0.08))
                    }
                    .shadow(color: .black.opacity(0.045), radius: 7, y: 3)
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("macOS")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text(system.macOSVersion ?? "读取失败")
                            .font(.title.bold())
                            .monospacedDigit()
                        Text("Build \(system.build ?? "读取失败") · \(system.architecture ?? "读取失败")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(alignment: .top, spacing: 16) {
                    systemMetric("主机名", value: system.hostName, systemImage: "person.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    systemMetric("内存", value: byteCount(system.memoryBytes), systemImage: "cpu")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()
                diskUsage(system)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func diskUsage(_ system: SystemSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let total = system.diskTotalBytes,
               let free = system.diskFreeBytes,
               total > 0 {
                let used = total > free ? total - free : 0
                let usedRatio = Double(used) / Double(total)
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.accentColor.opacity(0.10))
                        Image(systemName: "internaldrive")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    .frame(width: 30, height: 30)
                    .accessibilityHidden(true)
                    Text("系统卷")
                        .fontWeight(.semibold)
                    Spacer()
                    Text(usedRatio, format: .percent.precision(.fractionLength(0)))
                        .font(.title3.bold())
                        .monospacedDigit()
                        .foregroundStyle(Color.accentColor)
                }
                ProgressView(value: usedRatio)
                    .progressViewStyle(.linear)
                    .tint(Color.accentColor)
                HStack {
                    Text("已用 \(byteCount(used))")
                    Spacer()
                    Text("可用 \(byteCount(free)) / \(byteCount(total))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                systemValue("系统卷", value: "读取失败")
            }
        }
    }

    private func systemMetric(_ label: String, value: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.10))
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 34, height: 34)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func systemValue(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
    }

    private func copyablePath(_ path: String, prefix: String? = nil) -> some View {
        let showsCopyButton = hoveredPath == path || focusedCopyPath == path || copiedPath == path

        return HStack(spacing: 10) {
            Text(prefix.map { "\($0)：\(path)" } ?? path)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                copy(path)
            } label: {
                Label(copiedPath == path ? "已复制" : "复制", systemImage: copiedPath == path ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .focused($focusedCopyPath, equals: path)
            .opacity(showsCopyButton ? 1 : 0)
            .help("复制路径")
        }
        .contentShape(Rectangle())
        .onHover { isHovering in
            if isHovering {
                hoveredPath = path
            } else if hoveredPath == path {
                hoveredPath = nil
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: showsCopyButton)
    }

    private var currentNotices: [String] {
        model.snapshot.map(scanNotices(in:)) ?? []
    }

    private var hasUnreadNotices: Bool {
        guard let snapshot = model.snapshot else { return false }
        return !currentNotices.isEmpty && readNoticeSnapshotDate != snapshot.scannedAt
    }

    private func notificationsPopover(_ notices: [String]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("通知", systemImage: "bell.fill")
                    .font(.headline)
                Spacer()
                if !notices.isEmpty {
                    Text("\(notices.count) 条")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            if notices.isEmpty {
                ContentUnavailableView("暂无扫描提示", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(notices, id: \.self) { notice in
                        Label(notice, systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func markCurrentNoticesRead() {
        readNoticeSnapshotDate = model.snapshot?.scannedAt
    }

    private func scanNotices(in snapshot: MachineSnapshot) -> [String] {
        snapshot.runtimes
            .filter(\.hasPathVersionConflict)
            .map { "\($0.name)：PATH 版本冲突" }
            + snapshot.issues
    }

    private func effectiveVersion(for runtime: RuntimeSnapshot) -> String {
        guard let installation = runtime.installations.first(where: \.isEffective) ?? runtime.installations.first else {
            return "未发现"
        }
        return installation.version ?? installation.error ?? "读取失败"
    }

    private func copy(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        copiedPath = path
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedPath == path { copiedPath = nil }
        }
    }

    private func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private func byteCount(_ bytes: UInt64?) -> String {
        guard let bytes else { return "读取失败" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

}

private struct RuntimeHelpIcon: View {
    let explanation: String
    @State private var isShowingExplanation = false

    var body: some View {
        Image(systemName: "questionmark.circle")
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
            .onHover { isShowingExplanation = $0 }
            .popover(isPresented: $isShowingExplanation, arrowEdge: .bottom) {
                Text(explanation)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(width: 280, alignment: .leading)
            }
            .accessibilityLabel("说明")
            .accessibilityHint(explanation)
    }
}
