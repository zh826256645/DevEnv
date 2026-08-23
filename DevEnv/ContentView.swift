import AppKit
import SwiftUI

private struct EnvironmentCardUpperContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private extension View {
    func synchronizedEnvironmentCardUpperContent(minHeight: CGFloat) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(key: EnvironmentCardUpperContentHeightKey.self, value: geometry.size.height)
            }
        }
        .frame(minHeight: minHeight, alignment: .top)
    }
}

struct LocalServiceDisplayGroup: Identifiable {
    var id: Int32 { pids[0] }

    let processName: String
    var pids: [Int32]
    let bindings: [ListenerBinding]
}

struct LocalServiceDescriptor {
    let displayName: String
    let explanation: String
    let symbolName: String
    let tint: Color
    let assetName: String?
}

func localServiceDescriptor(for processName: String) -> LocalServiceDescriptor {
    let name = processName.lowercased()
    func descriptor(
        _ displayName: String,
        _ explanation: String,
        _ symbolName: String,
        _ tint: Color,
        _ assetName: String? = nil
    ) -> LocalServiceDescriptor {
        LocalServiceDescriptor(
            displayName: displayName,
            explanation: explanation,
            symbolName: symbolName,
            tint: tint,
            assetName: assetName
        )
    }

    if name.hasPrefix("python") {
        return descriptor("Python", "Python 解释器启动的本地服务", "chevron.left.forwardslash.chevron.right", .blue, "RuntimePythonLogo")
    }
    if name.hasPrefix("redis") {
        return descriptor("Redis", "内存键值数据库与缓存服务", "square.stack.3d.up.fill", .red, "ServiceRedisLogo")
    }

    switch name {
    case "node", "nodejs":
        return descriptor("Node.js", "JavaScript 运行时启动的本地服务", "hexagon.fill", .green, "RuntimeNodeLogo")
    case "postgres", "postmaster":
        return descriptor("PostgreSQL", "PostgreSQL 关系型数据库", "cylinder.fill", .blue, "ServicePostgreSQLLogo")
    case "mongod", "mongos":
        return descriptor("MongoDB", "MongoDB 文档数据库", "leaf.fill", .green, "ServiceMongoDBLogo")
    case "mysqld", "mysql":
        return descriptor("MySQL", "MySQL 关系型数据库", "cylinder.fill", Color(red: 0.27, green: 0.47, blue: 0.63), "ServiceMySQLLogo")
    case "mariadbd":
        return descriptor("MariaDB", "MariaDB 关系型数据库", "cylinder.fill", Color(red: 0, green: 0.36, blue: 0.43), "ServiceMariaDBLogo")
    case "adb":
        return descriptor("Android Debug Bridge", "Android 设备调试桥接服务", "apps.iphone", .green)
    case "rapportd":
        return descriptor("Apple 设备互联", "附近 Apple 设备发现与接续服务", "link.circle.fill", .blue)
    case "controlcenter":
        return descriptor("控制中心", "macOS 控制中心与隔空播放相关服务", "switch.2", .blue)
    case "wechat":
        return descriptor("微信", "微信客户端内部本地通信服务", "message.fill", .green)
    case "sparkle":
        return descriptor("Sparkle", "Sparkle 应用的本地通信服务", "sparkles", .purple)
    default:
        return descriptor(processName, "未识别的本地 TCP 监听进程", "server.rack", .secondary)
    }
}

func groupLocalServicesForDisplay(
    _ services: [LocalServiceSnapshot]
) -> [LocalServiceDisplayGroup] {
    var groups: [LocalServiceDisplayGroup] = []

    // ponytail: listener counts are small; use keyed indices if this becomes measurable.
    for service in services {
        if let index = groups.firstIndex(where: {
            $0.processName == service.processName && $0.bindings == service.bindings
        }) {
            groups[index].pids.append(service.pid)
            groups[index].pids.sort()
        } else {
            groups.append(LocalServiceDisplayGroup(
                processName: service.processName,
                pids: [service.pid],
                bindings: service.bindings
            ))
        }
    }

    return groups
}

func localServiceNotifications(_ services: [LocalServiceSnapshot]) -> [String] {
    groupLocalServicesForDisplay(services).compactMap { group in
        let exposedCount = group.bindings.count { !$0.isLoopback }
        guard exposedCount > 0 else { return nil }
        return "\(localServiceDescriptor(for: group.processName).displayName)：\(exposedCount) 个监听项可能可被局域网访问"
    }
}

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
    @State private var isGitConfigurationExpanded = false
    @State private var isPathExpanded = false
    @State private var isShowingNotifications = false
    @State private var readNoticeSnapshotDate: Date?
    @State private var environmentCardUpperContentHeight: CGFloat = 0
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
                    ? "通知，当前有未读通知"
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
                localServicesSection(snapshot)
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
        let localServiceCount = groupLocalServicesForDisplay(snapshot.localServices).count

        return topOverviewCard("扫描汇总", systemImage: "chart.bar.fill") {
            VStack(spacing: 12) {
                summaryMetric(discoveredCount, label: "已发现 Runtime 类别", systemImage: "magnifyingglass")
                summaryMetric(installationCount, label: "Runtime Installation", systemImage: "arrow.down.to.line.compact")
                summaryMetric(localServiceCount, label: "本地服务", systemImage: "network")
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

    private func localServicesSection(_ snapshot: MachineSnapshot) -> some View {
        let groups = groupLocalServicesForDisplay(snapshot.localServices)
        let portCount = groups.reduce(0) { $0 + Set($1.bindings.map(\.port)).count }

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "network")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.85), in: Circle())
                    .shadow(color: Color.accentColor.opacity(0.25), radius: 8, y: 3)
                Text("本地服务")
                    .font(.title2.bold())
                Spacer()
                Text("\(groups.count) 组服务 · \(portCount) 个端口")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if groups.isEmpty {
                if let notice = snapshot.localServiceScanNotice {
                    ContentUnavailableView {
                        Label("监听读取失败", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("\(notice)。请通过右上角通知查看详情或重新扫描。")
                    }
                    .frame(maxWidth: .infinity, minHeight: 110)
                } else {
                    ContentUnavailableView("当前没有可见的 TCP 监听服务", systemImage: "network.slash")
                        .frame(maxWidth: .infinity, minHeight: 110)
                }
            } else {
                VStack(spacing: 6) {
                    ForEach(groups) { group in
                        localServiceRow(group)
                    }
                }
            }
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.primary.opacity(0.025))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.primary.opacity(0.10))
                }
        }
    }

    private func localServiceRow(_ group: LocalServiceDisplayGroup) -> some View {
        let descriptor = localServiceDescriptor(for: group.processName)
        let applicationIcon = runningApplicationIcon(for: group.pids)
        let pidText = group.pids.count == 1
            ? "PID \(group.pids[0].formatted())"
            : "\(group.pids.count) 个进程 · PID \(group.pids.map { $0.formatted() }.joined(separator: "、"))"
        let processText = descriptor.displayName == group.processName
            ? pidText
            : "\(group.processName) · \(pidText)"

        return HStack(alignment: .center, spacing: 16) {
            Group {
                if let applicationIcon {
                    Image(nsImage: applicationIcon)
                        .resizable()
                        .scaledToFit()
                } else if let assetName = descriptor.assetName {
                    Image(assetName)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(descriptor.tint)
                        .padding(13)
                        .background(descriptor.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 14))
                } else {
                    Image(systemName: descriptor.symbolName)
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(descriptor.tint)
                        .padding(13)
                        .background(descriptor.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .frame(width: 54, height: 54)
            .shadow(color: .black.opacity(0.14), radius: 7, y: 4)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(.green)
                        .frame(width: 9, height: 9)
                        .shadow(color: .green.opacity(0.65), radius: 4)
                        .accessibilityHidden(true)
                    Text(descriptor.displayName)
                        .font(.title3.bold())
                }
                Text(descriptor.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(processText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150, maximum: 205), spacing: 8)],
                alignment: .trailing,
                spacing: 7
            ) {
                ForEach(group.bindings, id: \.self) { binding in
                    listenerBindingBadge(binding)
                }
            }
            .frame(minWidth: 170, maxWidth: 420, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.58))
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(Color.primary.opacity(0.10))
                }
        }
    }

    private func runningApplicationIcon(for pids: [Int32]) -> NSImage? {
        for pid in pids {
            if let icon = NSRunningApplication(processIdentifier: pid)?.icon { return icon }
        }
        return nil
    }

    private func listenerBindingText(_ binding: ListenerBinding) -> String {
        let address = binding.family == .ipv6 ? "[\(binding.address)]" : binding.address
        return "\(address):\(binding.port)"
    }

    private func listenerBindingBadge(_ binding: ListenerBinding) -> some View {
        let tint = binding.family == .ipv4 ? Color.blue : Color.purple

        return HStack(spacing: 6) {
            Text(binding.family.rawValue)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
            Text(listenerBindingText(binding))
                .font(.callout.monospaced())
                .lineLimit(1)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            if !binding.isLoopback {
                ListenerExposureIcon()
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.primary.opacity(0.08))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func runtimeCard(_ runtime: RuntimeSnapshot) -> some View {
        let isExpanded = expandedRuntimeID == runtime.id
        let status = runtimeCardStatus(runtime)
        let showsAllInstallations = fullyShownRuntimeID == runtime.id
        let visibleInstallations = showsAllInstallations
            ? runtime.installations
            : Array(runtime.installations.prefix(3))

        return Group {
            if isExpanded {
                VStack(alignment: .leading, spacing: 16) {
                    Button {
                        toggleRuntime(runtime.id)
                    } label: {
                        runtimeExpandedSummary(runtime)
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue("已展开")

                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(visibleInstallations) { installation in
                            runtimeInstallationRow(installation, hasConflict: runtime.hasPathVersionConflict)
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
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.primary.opacity(0.09))
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .transition(.opacity)
                }
            } else {
                Group {
                    if runtime.installations.isEmpty {
                        runtimeSummary(runtime)
                    } else {
                        Button {
                            toggleRuntime(runtime.id)
                        } label: {
                            runtimeSummary(runtime)
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue("已折叠")
                    }
                }
            }
        }
        .padding(isExpanded ? 16 : 14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: isExpanded ? 16 : 14, style: .continuous)
                .fill(status.color.opacity(isExpanded ? 0.08 : 0.035))
                .overlay {
                    RoundedRectangle(cornerRadius: isExpanded ? 16 : 14, style: .continuous)
                        .stroke(status.color.opacity(isExpanded ? 0.55 : 0.25))
                }
        }
        .shadow(color: status.color.opacity(isExpanded ? 0.10 : 0.025), radius: isExpanded ? 14 : 8, y: 3)
    }

    private func runtimeExpandedSummary(_ runtime: RuntimeSnapshot) -> some View {
        let brand = runtimeBrand(runtime)
        let status = runtimeCardStatus(runtime)
        let pathVersionCount = Set(runtime.installations.filter(\.isInPath).compactMap(\.version)).count

        return HStack(alignment: .center, spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(brand.color.opacity(0.10))
                Image(brand.assetName)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(brand.color)
                    .padding(11)
            }
            .frame(width: 64, height: 64)
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(brand.color.opacity(0.16))
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(runtime.name)
                    .font(.title3.bold())
                Text(effectiveVersion(for: runtime))
                    .font(.title2.bold())
                    .monospacedDigit()
                Label("\(runtime.installations.count) 个安装", systemImage: "square.stack.3d.up.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            .frame(width: 150, alignment: .leading)

            HStack(spacing: 10) {
                runtimeMetric(
                    title: "当前生效",
                    value: effectiveVersion(for: runtime),
                    systemImage: "checkmark.circle",
                    tint: runtime.state == .failed ? .orange : .green
                )
                runtimeMetric(
                    title: "PATH 版本",
                    value: "\(pathVersionCount)",
                    systemImage: "exclamationmark.circle",
                    tint: runtime.hasPathVersionConflict ? .orange : .secondary
                )
                runtimeMetric(
                    title: "已发现",
                    value: "\(runtime.installations.count)",
                    systemImage: "square.stack.3d.up.fill",
                    tint: .blue
                )
            }
            .frame(maxWidth: .infinity)
        }
        .contentShape(Rectangle())
    }

    private func runtimeMetric(
        title: String,
        value: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(.title3.bold())
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(tint.opacity(0.25))
        }
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

    private func runtimeInstallationRow(
        _ installation: RuntimeInstallation,
        hasConflict: Bool
    ) -> some View {
        let isConflictingPath = hasConflict && installation.isInPath && !installation.isEffective
        let tint: Color = installation.isEffective
            ? .green
            : (installation.state == .failed || isConflictingPath ? .orange : .secondary)
        let symbol = installation.isEffective
            ? "checkmark.circle.fill"
            : (installation.state == .failed || isConflictingPath ? "exclamationmark.circle" : "circle.fill")
        let source = installation.isEffective
            ? "当前生效"
            : (installation.isInPath ? "PATH" : "已发现")

        return HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24)

            Text(installation.version ?? "读取失败")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .frame(width: 90, alignment: .leading)

            Text(source)
                .font(.caption.weight(.semibold))
                .foregroundStyle(installation.isEffective ? .green : .secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 5) {
                copyablePath(installation.executable)
                if let actual = installation.actualExecutable {
                    copyablePath(actual, prefix: "实际路径")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if installation.state == .failed {
                helpIcon("该安装已被发现，但版本读取失败或可执行文件不可用；它不会阻止其他 Runtime Installation 继续扫描。")
            } else if isConflictingPath {
                Text("可能冲突")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(tint.opacity(installation.isEffective ? 0.07 : 0.025), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(tint.opacity(installation.isEffective || isConflictingPath ? 0.45 : 0.16))
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
                gitCard(
                    snapshot.gitCLI,
                    lfs: snapshot.gitLFS,
                    configuration: snapshot.userGitConfiguration,
                    signing: snapshot.gitSigningConfiguration,
                    credentialHelpers: snapshot.gitCredentialHelpers,
                    github: snapshot.githubAuthenticationConfiguration
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                pathCard(snapshot.path, warningCount: pathWarningCount)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .fixedSize(horizontal: false, vertical: true)
            .onPreferenceChange(EnvironmentCardUpperContentHeightKey.self) {
                environmentCardUpperContentHeight = $0
            }

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

    private func gitCard(
        _ git: GitCLISnapshot,
        lfs: GitLFSSnapshot?,
        configuration: UserGitConfigurationSnapshot?,
        signing: GitSigningConfigurationSnapshot?,
        credentialHelpers: [String]?,
        github: GitHubAuthenticationConfigurationSnapshot
    ) -> some View {
        let appearance: (color: Color, status: String, badge: String, pill: String) = switch git.state {
        case .available: (.green, "可用", "checkmark", "checkmark.circle.fill")
        case .failed: (.orange, "读取失败", "exclamationmark", "exclamationmark.circle.fill")
        case .unavailable: (.secondary, "未发现", "questionmark", "circle.fill")
        }

        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.orange.opacity(0.09))
                        Image("GitLogo")
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(.orange)
                            .padding(11)
                    }
                    .frame(width: 54, height: 54)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.primary.opacity(0.07))
                    }
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Git")
                            .font(.headline)
                        Text(git.version ?? appearance.status)
                            .font(.title2.bold())
                            .monospacedDigit()
                        Text("当前生效 CLI")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: appearance.badge)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(appearance.color)
                        .frame(width: 38, height: 38)
                        .background(appearance.color.opacity(0.10), in: Circle())
                        .accessibilityHidden(true)
                }

                Label(appearance.status, systemImage: appearance.pill)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(appearance.color)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(appearance.color.opacity(0.10), in: Capsule())

                if let lfs {
                    HStack {
                        Text("Git LFS")
                        Spacer()
                        Text(lfs.version ?? (lfs.state == .failed ? "读取失败" : "未发现"))
                            .foregroundStyle(lfs.state == .failed ? .orange : .secondary)
                    }
                    .font(.caption)
                }

                HStack {
                    Text("GitHub Authentication Configuration")
                    Spacer()
                    Text(github.isConfigured ? "已配置" : "未配置")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            .synchronizedEnvironmentCardUpperContent(minHeight: environmentCardUpperContentHeight)

            Divider()

            if git.state != .available {
                if let executable = git.executable {
                    copyablePath(executable)
                } else {
                    Text("当前 PATH 未发现 Git")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                toggleGitConfiguration()
            } label: {
                Label(
                    isGitConfigurationExpanded ? "收起 Git 配置" : "查看 Git 配置",
                    systemImage: isGitConfigurationExpanded ? "chevron.up" : "chevron.down"
                )
            }
            .buttonStyle(.borderless)
            .accessibilityValue(isGitConfigurationExpanded ? "已展开" : "已折叠")

            if isGitConfigurationExpanded {
                Divider()
                gitConfigurationDetails(
                    configuration,
                    signing: signing,
                    credentialHelpers: credentialHelpers,
                    executable: git.state == .available ? git.executable : nil,
                    github: github
                )
                    .transition(.opacity)
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

    private func gitConfigurationDetails(
        _ configuration: UserGitConfigurationSnapshot?,
        signing: GitSigningConfigurationSnapshot?,
        credentialHelpers: [String]?,
        executable: String?,
        github: GitHubAuthenticationConfigurationSnapshot
    ) -> some View {
        let githubCLIStatus = switch github.cliState {
        case .available: "已发现"
        case .unavailable: "未发现"
        case .failed: "读取失败"
        }

        return VStack(alignment: .leading, spacing: 14) {
            if let executable {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Git CLI 路径")
                        .font(.callout.weight(.semibold))
                    copyablePath(executable)
                }

                if let configuration {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Default Git Identity")
                            .font(.callout.weight(.semibold))
                        if configuration.defaultIdentity.name == nil || configuration.defaultIdentity.email == nil {
                            Text("未配置默认身份")
                                .foregroundStyle(.secondary)
                        }
                        if let name = configuration.defaultIdentity.name { gitConfigurationValue("名称", name) }
                        if let email = configuration.defaultIdentity.email { gitConfigurationValue("邮箱", email) }
                    }

                    gitConfigurationValue("默认分支", configuration.defaultBranch ?? "未配置")

                    VStack(alignment: .leading, spacing: 5) {
                        Text("User Excludes File")
                            .font(.callout.weight(.semibold))
                        Text(configuration.excludesFile.source == .explicitConfiguration ? "显式配置" : "Git 默认")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        copyablePath(configuration.excludesFile.path)
                        Text(configuration.excludesFile.exists ? "文件存在" : "文件不存在")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("User Git Configuration 读取失败，请查看 Scan Notice")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("签名配置")
                        .font(.callout.weight(.semibold))
                    if let signing {
                        gitConfigurationValue("格式", signing.format ?? "未配置")
                        gitConfigurationValue("签名标识", signing.signingKey ?? "未配置")
                        gitConfigurationValue("提交签名", signing.commitSigning ?? "未配置")
                        gitConfigurationValue("标签签名", signing.tagSigning ?? "未配置")
                    } else {
                        Text("读取失败，请查看 Scan Notice")
                            .foregroundStyle(.orange)
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("Credential Helper Chain")
                        .font(.callout.weight(.semibold))
                    if let credentialHelpers {
                        if credentialHelpers.isEmpty {
                            Text("未配置")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(credentialHelpers.enumerated()), id: \.offset) { index, helper in
                                gitConfigurationValue("\(index + 1)", helper)
                            }
                        }
                    } else {
                        Text("读取失败，请查看 Scan Notice")
                            .foregroundStyle(.orange)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("GitHub Authentication Configuration")
                    .font(.callout.weight(.semibold))
                gitConfigurationValue("GitHub CLI", githubCLIStatus)
                gitConfigurationValue("git_protocol", github.gitProtocol ?? (github.cliState == .failed ? "读取失败" : "未配置"))
                gitConfigurationValue("本地配置", github.localConfigurationExists ? "已配置" : "未配置")
                gitConfigurationValue("进程 GH_TOKEN", github.ghTokenExists ? "已配置" : "未配置")
                gitConfigurationValue("进程 GITHUB_TOKEN", github.githubTokenExists ? "已配置" : "未配置")
            }
        }
    }

    private func gitConfigurationValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
    }

    private func toggleGitConfiguration() {
        if reduceMotion {
            isGitConfigurationExpanded.toggle()
        } else {
            withAnimation(.smooth(duration: 0.25)) {
                isGitConfigurationExpanded.toggle()
            }
        }
    }

    private func homebrewCard(_ homebrew: HomebrewSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
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
            }
            .synchronizedEnvironmentCardUpperContent(minHeight: environmentCardUpperContentHeight)

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

                HStack(spacing: 8) {
                    Label(path.isEmpty ? "未读取" : "\(path.count) 个目录", systemImage: path.isEmpty ? "circle" : "checkmark.circle.fill")
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(path.isEmpty ? Color.secondary : Color.green)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background((path.isEmpty ? Color.secondary : Color.green).opacity(0.10), in: Capsule())

                    if warningCount > 0 {
                        Label("\(warningCount) 个冲突", systemImage: "exclamationmark.triangle.fill")
                            .fixedSize(horizontal: true, vertical: false)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Color.orange.opacity(0.10), in: Capsule())
                    }
                }
                .font(.caption.weight(.semibold))
            }
            .synchronizedEnvironmentCardUpperContent(minHeight: environmentCardUpperContentHeight)

            Divider()

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
                    .fixedSize(horizontal: true, vertical: false)
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.borderless)
            .frame(maxWidth: .infinity, alignment: .trailing)
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
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(path)
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
        model.snapshot.map(notifications(in:)) ?? []
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
                ContentUnavailableView("暂无通知", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(notices.indices, id: \.self) { index in
                        Label(notices[index], systemImage: "exclamationmark.circle.fill")
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

    private func notifications(in snapshot: MachineSnapshot) -> [String] {
        snapshot.runtimes
            .filter(\.hasPathVersionConflict)
            .map { "\($0.name)：PATH 版本冲突" }
            + localServiceNotifications(snapshot.localServices)
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

private struct ListenerExposureIcon: View {
    @State private var isShowingExplanation = false

    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.caption.weight(.bold))
            .foregroundStyle(.orange)
            .padding(7)
            .background(Color.orange.opacity(0.17), in: Circle())
            .contentShape(Circle())
            .onHover { isShowingExplanation = $0 }
            .popover(isPresented: $isShowingExplanation, arrowEdge: .bottom) {
                Text("可能可被局域网访问。仅依据监听地址范围判断，未验证防火墙或其他设备的实际可达性。")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(width: 280, alignment: .leading)
            }
            .accessibilityLabel("可能可被局域网访问")
            .accessibilityHint("仅依据监听地址范围判断，未验证实际可达性")
    }
}
