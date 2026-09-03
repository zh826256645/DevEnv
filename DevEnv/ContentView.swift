import AppKit
import SwiftUI

enum AppAppearance: String, CaseIterable {
    case light
    case dark
    case system

    static let storageKey = "appAppearance"

    var title: String {
        switch self {
        case .light: "浅色"
        case .dark: "深色"
        case .system: "跟随系统"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        case .system: nil
        }
    }

    @MainActor
    func apply(to target: any NSAppearanceCustomization = NSApplication.shared) {
        target.appearance = nsAppearance
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? .system
    }
}

private enum AppTheme {
    static let accent = adaptive(
        light: NSColor(red: 0.08, green: 0.38, blue: 0.95, alpha: 1),
        dark: NSColor(red: 0.29, green: 0.57, blue: 1, alpha: 1)
    )
    static let canvas = adaptive(
        light: NSColor(red: 0.95, green: 0.975, blue: 1, alpha: 1),
        dark: NSColor(red: 0.05, green: 0.08, blue: 0.13, alpha: 1)
    )
    static let sidebar = adaptive(
        light: NSColor(red: 0.91, green: 0.95, blue: 1, alpha: 1),
        dark: NSColor(red: 0.07, green: 0.11, blue: 0.18, alpha: 1)
    )
    static let cardSubtle = adaptive(
        light: NSColor(white: 1, alpha: 0.58),
        dark: NSColor(red: 0.08, green: 0.13, blue: 0.21, alpha: 0.82)
    )
    static let cardSurface = adaptive(
        light: NSColor(white: 1, alpha: 0.76),
        dark: NSColor(red: 0.09, green: 0.15, blue: 0.24, alpha: 0.92)
    )
    static let cardRaised = adaptive(
        light: NSColor(white: 1, alpha: 0.88),
        dark: NSColor(red: 0.10, green: 0.17, blue: 0.27, alpha: 0.96)
    )
    static let innerCard = adaptive(
        light: NSColor(white: 0.5, alpha: 0.10),
        dark: NSColor(white: 1, alpha: 0.07)
    )

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

final class ProjectTerminalContainerView: NSView {
    private weak var terminalView: NSView?

    func mount(_ terminalView: NSView) {
        self.terminalView = terminalView
        guard terminalView.superview !== self else { return }
        addSubview(terminalView)
        resizeTerminalIfPossible()
    }

    func unmount() {
        guard let terminalView, terminalView.superview === self else { return }
        terminalView.removeFromSuperview()
    }

    override func layout() {
        super.layout()
        resizeTerminalIfPossible()
    }

    private func resizeTerminalIfPossible() {
        guard bounds.width > 1, bounds.height > 1,
              let terminalView, terminalView.superview === self else { return }
        terminalView.frame = bounds
    }
}

struct ProjectTerminalView: NSViewRepresentable {
    let terminalView: NSView

    func makeNSView(context _: Context) -> ProjectTerminalContainerView {
        let container = ProjectTerminalContainerView()
        container.mount(terminalView)
        return container
    }

    func updateNSView(_ container: ProjectTerminalContainerView, context _: Context) {
        container.mount(terminalView)
    }

    static func dismantleNSView(_ container: ProjectTerminalContainerView, coordinator _: ()) {
        container.unmount()
    }
}

struct AutoRefreshSettings: Equatable, Sendable {
    static let foregroundRange = 5 ... 300
    static let backgroundRange = 30 ... 3_600

    var isEnabled: Bool
    var foregroundSeconds: Int
    var backgroundSeconds: Int

    init(
        isEnabled: Bool = true,
        foregroundSeconds: Int = 10,
        backgroundSeconds: Int = 60
    ) {
        self.isEnabled = isEnabled
        self.foregroundSeconds = min(
            max(foregroundSeconds, Self.foregroundRange.lowerBound),
            Self.foregroundRange.upperBound
        )
        self.backgroundSeconds = max(
            min(max(backgroundSeconds, Self.backgroundRange.lowerBound), Self.backgroundRange.upperBound),
            self.foregroundSeconds
        )
    }

    func interval(isActive: Bool) -> TimeInterval {
        TimeInterval(isActive ? foregroundSeconds : backgroundSeconds)
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        AutoRefreshSettings(
            isEnabled: defaults.object(forKey: "autoRefreshEnabled") as? Bool ?? true,
            foregroundSeconds: defaults.object(forKey: "autoRefreshForegroundSeconds") as? Int ?? 10,
            backgroundSeconds: defaults.object(forKey: "autoRefreshBackgroundSeconds") as? Int ?? 60
        )
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(isEnabled, forKey: "autoRefreshEnabled")
        defaults.set(foregroundSeconds, forKey: "autoRefreshForegroundSeconds")
        defaults.set(backgroundSeconds, forKey: "autoRefreshBackgroundSeconds")
    }
}

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

    func overviewCard(cornerRadius: CGFloat = 15) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(AppTheme.cardSurface)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.primary.opacity(0.09))
            }
        }
    }

    func overviewListItemCard(cornerRadius: CGFloat = 9) -> some View {
        background(Color.primary.opacity(0.018), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.primary.opacity(0.09))
            }
    }
}

struct LocalServiceDisplayGroup: Identifiable {
    var id: Int32 { pids[0] }
    var displayName: String { attribution?.name ?? localServiceDescriptor(for: processName).displayName }

    let processName: String
    var pids: [Int32]
    let bindings: [ListenerBinding]
    let attribution: LocalServiceAttribution?
}

struct ServiceDisplayDescriptor {
    let displayName: String
    let explanation: String
    let symbolName: String
    let tint: Color
    let assetName: String?
}

func localServiceDescriptor(for processName: String) -> ServiceDisplayDescriptor {
    let name = processName.lowercased()
    func descriptor(
        _ displayName: String,
        _ explanation: String,
        _ symbolName: String,
        _ tint: Color,
        _ assetName: String? = nil
    ) -> ServiceDisplayDescriptor {
        ServiceDisplayDescriptor(
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
    case "mysqld":
        return descriptor("mysqld", "仅凭进程名无法区分 MySQL 与 MariaDB", "cylinder.fill", .secondary)
    case "mysql":
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

func homebrewServiceDescriptor(for formula: String) -> ServiceDisplayDescriptor {
    let name = formula.lowercased()

    if name == "postgresql" || name.hasPrefix("postgresql@") {
        return localServiceDescriptor(for: "postgres")
    }
    if name == "mongodb-community" || name.hasPrefix("mongodb-community@") {
        return localServiceDescriptor(for: "mongod")
    }
    if name == "redis" || name.hasPrefix("redis@") {
        return localServiceDescriptor(for: "redis")
    }
    if name == "mysql" || name.hasPrefix("mysql@") {
        return localServiceDescriptor(for: "mysql")
    }
    if name == "mariadb" || name.hasPrefix("mariadb@") {
        return localServiceDescriptor(for: "mariadbd")
    }
    if name == "node" || name.hasPrefix("node@") {
        return localServiceDescriptor(for: "node")
    }
    if name == "python" || name.hasPrefix("python@") {
        return localServiceDescriptor(for: "python")
    }
    if name == "cloudflared" {
        return ServiceDisplayDescriptor(displayName: formula, explanation: "", symbolName: "cloud.fill", tint: .blue, assetName: nil)
    }
    if name == "php" || name.hasPrefix("php@") {
        return ServiceDisplayDescriptor(displayName: formula, explanation: "", symbolName: "chevron.left.forwardslash.chevron.right", tint: .indigo, assetName: nil)
    }
    if name == "unbound" {
        return ServiceDisplayDescriptor(displayName: formula, explanation: "", symbolName: "network", tint: .teal, assetName: nil)
    }
    return ServiceDisplayDescriptor(displayName: formula, explanation: "", symbolName: "shippingbox.fill", tint: .secondary, assetName: nil)
}

func groupLocalServicesForDisplay(
    _ services: [LocalServiceSnapshot]
) -> [LocalServiceDisplayGroup] {
    var groups: [LocalServiceDisplayGroup] = []

    // ponytail: listener counts are small; use keyed indices if this becomes measurable.
    for service in services {
        if let index = groups.firstIndex(where: {
            $0.processName == service.processName
                && $0.bindings == service.bindings
                && $0.attribution == service.attribution
        }) {
            groups[index].pids.append(service.pid)
            groups[index].pids.sort()
        } else {
            groups.append(LocalServiceDisplayGroup(
                processName: service.processName,
                pids: [service.pid],
                bindings: service.bindings,
                attribution: service.attribution
            ))
        }
    }

    return groups
}

struct EnvironmentNotice {
    let identities: Set<NoticeIdentity>
    let message: String
}

func localServiceNotices(_ services: [LocalServiceSnapshot]) -> [EnvironmentNotice] {
    groupLocalServicesForDisplay(services).compactMap { group in
        let exposedBindings = Set(group.bindings.filter { !$0.isLoopback })
        guard !exposedBindings.isEmpty else { return nil }
        return EnvironmentNotice(
            identities: Set(exposedBindings.map {
                .localService($0)
            }),
            message: "\(group.displayName)：\(exposedBindings.count) 个监听项可能可被局域网访问"
        )
    }
}

func overviewVisibleRunLimit(cardHeight: CGFloat, itemCount: Int) -> Int {
    guard itemCount > 0 else { return 0 }
    return (1...itemCount).reversed().first { count in
        let footerHeight: CGFloat = itemCount > count ? 36 : 0
        return 58 + CGFloat(count * 82 + max(0, count - 1) * 6) + footerHeight <= cardHeight
    } ?? 1
}

func overviewVisibleAttentionLimit(cardHeight: CGFloat, itemCount: Int) -> Int {
    guard itemCount > 0 else { return 0 }
    return (1...itemCount).reversed().first { count in
        let footerHeight: CGFloat = itemCount > count ? 36 : 0
        return 58 + CGFloat(count * 52 + max(0, count - 1) * 6) + footerHeight <= cardHeight
    } ?? 1
}

func listenerBindingText(_ binding: ListenerBinding) -> String {
    let rawAddress = if binding.address == "*" {
        binding.family == .ipv4 ? "0.0.0.0" : "::"
    } else {
        binding.address
    }
    let address = binding.family == .ipv6 ? "[\(rawAddress)]" : rawAddress
    return "\(address):\(binding.port)"
}

enum NoticeIdentity: Hashable {
    case message(String)
    case localService(ListenerBinding)
    case overview(String)
}

@MainActor
final class EnvironmentViewModel: ObservableObject {
    @Published private(set) var snapshot: MachineSnapshot?
    @Published private(set) var scanError: String?
    @Published private(set) var dynamicRefreshError: String?
    @Published private(set) var isShowingStaleSnapshot = false
    @Published private(set) var dynamicStatusRefreshedAt: Date?
    @Published private(set) var autoRefreshSettings = AutoRefreshSettings.load()
    @Published private(set) var homebrewServiceList: HomebrewServiceListState?
    @Published private(set) var homebrewServiceActionResult: HomebrewServiceActionResult?
    @Published private(set) var operationCoordinator = MachineOperationCoordinator()

    var isScanning: Bool { operationCoordinator.active == .environmentScan }
    var isRefreshingDynamicStatus: Bool { operationCoordinator.active == .dynamicStatusRefresh }
    var isRefreshingHomebrewServices: Bool { operationCoordinator.active == .homebrewServiceRefresh }
    var homebrewServiceActionFormula: String? {
        guard case let .homebrewServiceAction(formula) = operationCoordinator.active else { return nil }
        return formula
    }
    var isBusy: Bool { operationCoordinator.active != nil }
    var busyDescription: String? {
        switch operationCoordinator.active {
        case .environmentScan: "正在扫描"
        case .dynamicStatusRefresh: "正在刷新动态状态"
        case .homebrewServiceRefresh: "正在刷新 Homebrew Service"
        case .homebrewServiceAction: "正在修改 Homebrew Service"
        case nil: nil
        }
    }

    private let scanner = EnvironmentScanner()
    private let store = SnapshotStore()
    private var shouldRefreshHomebrewServicesWhenIdle = false

    init() {
        snapshot = store.load()
        scan()
    }

    func scan() {
        guard begin(.environmentScan) else { return }
        let hadSnapshot = snapshot != nil
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
                if result.canPersist {
                    self.snapshot = result.snapshot
                    self.dynamicStatusRefreshedAt = result.snapshot.scannedAt
                    self.dynamicRefreshError = nil
                }
                if let persistenceError {
                    self.scanError = "快照保存失败：\(persistenceError.localizedDescription)"
                } else if !result.canPersist {
                    self.scanError = "无法读取 macOS 基础信息，本次未更新快照"
                    self.isShowingStaleSnapshot = hadSnapshot
                }
                self.finish(.environmentScan)
            }
        }
    }

    func saveAutoRefreshSettings(_ settings: AutoRefreshSettings) {
        let settings = AutoRefreshSettings(
            isEnabled: settings.isEnabled,
            foregroundSeconds: settings.foregroundSeconds,
            backgroundSeconds: settings.backgroundSeconds
        )
        settings.save()
        autoRefreshSettings = settings
        if settings.isEnabled { refreshDynamicStatus() }
    }

    func refreshDynamicStatus() {
        guard let snapshot, begin(.dynamicStatusRefresh) else { return }
        let scanner = scanner
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = scanner.refreshDynamicStatus(in: snapshot)
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case let .success(dynamicStatus):
                    self.snapshot = snapshot.applying(dynamicStatus)
                    self.dynamicStatusRefreshedAt = Date()
                    self.dynamicRefreshError = nil
                case let .failure(error):
                    self.dynamicRefreshError = error.localizedDescription
                }
                self.finish(.dynamicStatusRefresh)
            }
        }
    }

    func refreshHomebrewServices() {
        guard let executable = snapshot?.homebrew.executable,
              snapshot?.homebrew.available == true else { return }
        guard !isBusy else {
            shouldRefreshHomebrewServicesWhenIdle = true
            return
        }
        guard begin(.homebrewServiceRefresh) else { return }
        shouldRefreshHomebrewServicesWhenIdle = false
        let previous = homebrewServiceList
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let state = HomebrewServiceManager().refresh(executable: executable, previous: previous)
            DispatchQueue.main.async {
                self?.homebrewServiceList = state
                self?.finish(.homebrewServiceRefresh)
            }
        }
    }

    func performHomebrewServiceAction(_ action: HomebrewServiceAction, on service: HomebrewService) {
        guard let snapshot,
              let executable = snapshot.homebrew.executable,
              snapshot.homebrew.available,
              let currentServices = homebrewServiceList?.services,
              currentServices.contains(where: { $0.formula == service.formula }),
              homebrewServiceList?.isStale == false,
              begin(.homebrewServiceAction(service.formula)) else { return }
        homebrewServiceActionResult = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = HomebrewServiceManager().perform(
                action,
                on: service,
                executable: executable,
                currentServices: currentServices,
                snapshot: snapshot
            )
            DispatchQueue.main.async {
                guard let self else { return }
                self.homebrewServiceList = result.list
                self.homebrewServiceActionResult = result
                if let dynamicStatus = result.dynamicStatus {
                    self.snapshot = snapshot.applying(dynamicStatus)
                    self.dynamicStatusRefreshedAt = Date()
                    self.dynamicRefreshError = nil
                } else if let error = result.dynamicStatusError {
                    self.dynamicRefreshError = error
                }
                self.finish(.homebrewServiceAction(service.formula))
                let message = result.message
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                    if self?.homebrewServiceActionResult?.message == message {
                        self?.homebrewServiceActionResult = nil
                    }
                }
            }
        }
    }

    private func begin(_ operation: MachineOperationCoordinator.Operation) -> Bool {
        var coordinator = operationCoordinator
        guard coordinator.begin(operation) else { return false }
        operationCoordinator = coordinator
        return true
    }

    private func finish(_ operation: MachineOperationCoordinator.Operation) {
        var coordinator = operationCoordinator
        coordinator.finish(operation)
        operationCoordinator = coordinator
        if !isBusy, shouldRefreshHomebrewServicesWhenIdle {
            DispatchQueue.main.async { [weak self] in self?.refreshHomebrewServices() }
        }
    }
}

struct ContentView: View {
    private struct PendingHomebrewServiceAction: Identifiable {
        var id: String { "\(service.formula)-\(action.rawValue)" }
        let service: HomebrewService
        let action: HomebrewServiceAction
        let executable: String
    }

    private struct OverviewRun: Identifiable {
        var id: String { configuration.id }
        let configuration: ProjectRunConfiguration
        let project: ProjectRecord
        let session: ProjectRunSession
        let bindings: [ListenerBinding]?
        let repositoryState: ProjectRepositoryState
    }

    private enum OverviewAttentionDestination {
        case run(String)
        case project(String, capability: String)
        case runtime(String)
        case database(String)
        case localServices
        case environmentRefresh
        case dynamicRefresh
        case storage
    }

    private struct OverviewAttentionItem: Identifiable {
        let id: String
        let title: String
        let detail: String
        let systemImage: String
        let tint: Color
        let priority: Int
        let occurredAt: Date?
        let destination: OverviewAttentionDestination
    }

    private enum Page: CaseIterable, Hashable {
        case overview
        case projects
        case runs
        case localServices
        case systemInformation
        case settings

        static var primaryPages: [Page] { allCases.filter { $0 != .settings } }
        var usesProjectRecords: Bool { self == .projects || self == .runs }

        var title: String {
            switch self {
            case .overview: "总览"
            case .projects: "项目"
            case .runs: "运行"
            case .localServices: "本地服务"
            case .systemInformation: "系统信息"
            case .settings: "设置"
            }
        }

        var systemImage: String {
            switch self {
            case .overview: "square.grid.2x2"
            case .projects: "folder"
            case .runs: "play.rectangle"
            case .localServices: "network"
            case .systemInformation: "info.circle"
            case .settings: "gearshape"
            }
        }
    }

    private enum SystemInformationSection: Hashable {
        case runtimes
        case databases
    }

    private enum ServiceTab: Hashable {
        case local
        case homebrew
    }

    private struct AutoRefreshSchedule: Hashable {
        let isEnabled: Bool
        let seconds: Int
    }

    private enum EnvironmentCard: CaseIterable {
        case packageManagers
        case git
        case terminal
        case shell
        case path
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppAppearance.storageKey) private var appAppearance = AppAppearance.load()
    @StateObject private var model = EnvironmentViewModel()
    @ObservedObject private var projectsModel: ProjectsViewModel
    @ObservedObject private var runCoordinator: ProjectRunCoordinator
    @State private var selectedPage: Page? = .overview
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var copiedPath: String?
    @State private var hoveredPath: String?
    @State private var expandedRuntimeID: String?
    @State private var fullyShownRuntimeID: String?
    @State private var expandedDatabaseID: String?
    @State private var fullyShownDatabaseID: String?
    @State private var pendingSystemInformationSection: SystemInformationSection?
    @State private var expandedEnvironmentCard: EnvironmentCard?
    @State private var showsAllPathEntries = false
    @State private var isShowingNotifications = false
    @State private var readNoticeIdentities: Set<NoticeIdentity> = []
    @State private var settingsDraft = AutoRefreshSettings()
    @State private var pendingPage: Page?
    @State private var isShowingSettingsExitConfirmation = false
    @State private var usesForegroundRefreshInterval = NSApplication.shared.isActive
    @State private var environmentCardUpperContentHeight: CGFloat = 0
    @State private var pendingHomebrewServiceAction: PendingHomebrewServiceAction?
    @State private var selectedServiceTab = ServiceTab.local
    @State private var isSelectingProjects = false
    @State private var selectedProjectIDs: Set<String> = []
    @State private var pendingProjectRemovalIDs: Set<String> = []
    @State private var isConfirmingProjectStoreReset = false
    @State private var selectedProjectID: String?
    @State private var expandedProjectRequirementID: String?
    @State private var projectSearchText = ""
    @State private var runProjectFilterID: String?
    @State private var isRunSuggestionsExpanded = false
    @State private var isShowingRunConfigurationEditor = false
    @State private var editingRunConfiguration: ProjectRunConfiguration?
    @State private var runConfigurationProjectID = ""
    @State private var runConfigurationName = ""
    @State private var runConfigurationCommand = ""
    @State private var runConfigurationWorkingDirectory = "."
    @State private var runConfigurationSaveAttempted = false
    @State private var runConfigurationSourceIdentity: String?
    @State private var pendingRunConfigurationDeletion: ProjectRunConfiguration?
    @State private var pendingProjectRunTrust: ProjectRunTrustRequest?
    @State private var pendingRunAllConfigurations: [ProjectRunConfiguration] = []
    @State private var pendingStopAllConfigurationIDs: [String] = []
    @State private var selectedRunConfigurationID: String?
    @State private var expandedTerminalConfiguration: ProjectRunConfiguration?
    @State private var runSearchText = ""
    @FocusState private var focusedCopyPath: String?
    @FocusState private var projectSearchIsFocused: Bool
    @FocusState private var projectAddIsFocused: Bool
    @FocusState private var runConfigurationNameIsFocused: Bool

    init(projectsModel: ProjectsViewModel, runCoordinator: ProjectRunCoordinator) {
        self.projectsModel = projectsModel
        self.runCoordinator = runCoordinator
    }

    var body: some View {
        navigation(model.snapshot)
        .frame(minWidth: 1100, minHeight: 720)
        .onChange(of: appAppearance, initial: true) { _, appearance in
            appearance.apply()
        }
        .tint(AppTheme.accent)
        .containerBackground(AppTheme.canvas, for: .window)
        .overlay(alignment: .topTrailing) { topActionButtons }
        .overlay(alignment: .topLeading) {
            if columnVisibility == .detailOnly {
                sidebarToggleButton
                    .padding(.leading, 72)
                    .padding(.top, 14)
            }
        }
        .task(id: autoRefreshSchedule) {
            let schedule = autoRefreshSchedule
            guard schedule.isEnabled else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(schedule.seconds))
                } catch {
                    return
                }
                model.refreshDynamicStatus()
            }
        }
        .onAppear {
            NSApplication.shared.windows.forEach { $0.titlebarSeparatorStyle = .none }
            updateRefreshActivity()
            if selectedPage == .overview { runCoordinator.refreshProjects() }
        }
        .onDisappear {
            if selectedPage == .projects { projectsModel.leaveProjects() }
        }
        .onChange(of: scenePhase) { _, _ in
            updateRefreshActivity()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            updateRefreshActivity()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            updateRefreshActivity()
        }
        .onReceive(NotificationCenter.default.publisher(for: .devEnvStatusBarAction)) { notification in
            switch notification.userInfo?["action"] as? String {
            case "open":
                if let configurationID = notification.userInfo?["configurationID"] as? String {
                    runProjectFilterID = nil
                    runSearchText = ""
                    selectedRunConfigurationID = configurationID
                    selectPage(.runs)
                }
            case "runAll": requestRunAllGlobal()
            case "stopAll": requestStopAllGlobal()
            default: break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification)) { _ in
            updateRefreshActivity()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didDeminiaturizeNotification)) { _ in
            updateRefreshActivity()
        }
        .onChange(of: currentNoticeIdentities) { _, identities in
            readNoticeIdentities.formIntersection(identities)
        }
        .onChange(of: model.snapshot?.scannedAt) {
            readNoticeIdentities.removeAll()
            switch selectedPage {
            case .projects?, .overview?:
                runCoordinator.refreshRequirements(machineSnapshot: model.snapshot)
            default:
                break
            }
        }
        .onChange(of: model.dynamicStatusRefreshedAt) {
            if selectedPage == .overview {
                runCoordinator.refreshRequirements(machineSnapshot: model.snapshot)
            }
        }
        .sheet(isPresented: $isShowingSettingsExitConfirmation, onDismiss: {
            pendingPage = nil
        }) {
            settingsExitConfirmation
        }
        .sheet(isPresented: $isShowingRunConfigurationEditor) {
            runConfigurationEditor
        }
        .alert(
            homebrewServiceConfirmationTitle,
            isPresented: isConfirmingHomebrewServiceAction,
            presenting: pendingHomebrewServiceAction
        ) { request in
            Button("取消", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
            Button("确认\(request.action.title)", role: request.action == .stop ? .destructive : nil) {
                model.performHomebrewServiceAction(request.action, on: request.service)
            }
        } message: { request in
            let command = ([request.executable, "services", request.action.rawValue, request.service.formula])
                .joined(separator: " ")
            Text("\(command)\n\n\(request.action.persistentEffect)")
        }
        .alert(
            projectRemovalConfirmationTitle,
            isPresented: isConfirmingProjectRemoval
        ) {
            Button("取消", role: .cancel) {}
            Button("确认删除", role: .destructive) {
                let projectIDs = pendingProjectRemovalIDs
                let succeeded = runCoordinator.removeProjects(projectIDs: projectIDs) != nil
                pendingProjectRemovalIDs.removeAll()
                guard succeeded else { return }
                selectedProjectIDs.removeAll()
                isSelectingProjects = false
                selectFirstProjectIfNeeded()
                projectSearchIsFocused = true
            }
        } message: {
            let summary = projectsModel.removalSummary(for: pendingProjectRemovalIDs)
            let configurations = runCoordinator.runConfigurations().filter {
                pendingProjectRemovalIDs.contains($0.projectID)
            }
            let activeSessionCount = configurations.filter {
                runCoordinator.session(for: $0.id)?.state.isLive == true
            }.count
            Text("将移除 \(summary.projectCount) 个项目记录、\(configurations.count) 个已保存运行配置和 \(activeSessionCount) 个活动会话，并清除 \(summary.ignoredProjectCount) 个忽略记录？活动会话将停止，Project Trust 将删除；不会删除、移动或修改原项目文件。项目记录会进入 Ignored Projects；忽略记录会从 DevEnv 中移除。")
        }
        .alert("重新创建项目记录存储？", isPresented: $isConfirmingProjectStoreReset) {
            Button("取消", role: .cancel) {}
            Button("保留备份并重新创建", role: .destructive) {
                projectsModel.recreateStore()
                selectedProjectID = nil
                projectAddIsFocused = true
            }
        } message: {
            Text("当前存储损坏或版本不兼容，已暂停修改。原文件会保留为备份，然后创建空的 project-records.json。")
        }
        .alert(
            "删除运行配置？",
            isPresented: isConfirmingRunConfigurationDeletion,
            presenting: pendingRunConfigurationDeletion
        ) { configuration in
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                if runCoordinator.deleteRunConfiguration(configuration) {
                    runCoordinator.closeTerminal(configurationID: configuration.id)
                    if selectedRunConfigurationID == configuration.id {
                        selectedRunConfigurationID = nil
                    }
                }
            }
        } message: { configuration in
            Text("将删除运行配置“\(configuration.name)”。此操作不会修改 Project Root。")
        }
        .alert(
            "信任并运行此 Project Root？",
            isPresented: isConfirmingProjectRunTrust,
            presenting: pendingProjectRunTrust
        ) { request in
            Button("取消", role: .cancel) {}
            Button("信任并运行") {
                if runCoordinator.confirmTrustAndRun(request) == .started {
                    selectedRunConfigurationID = request.configuration.id
                }
            }
        } message: { request in
            Text("完整命令：\n\(request.command)\n\n工作目录：\n\(request.workingDirectory)\n\n确认后，此 Project Root 的后续运行不再重复询问。")
        }
    }

    private var autoRefreshSchedule: AutoRefreshSchedule {
        AutoRefreshSchedule(
            isEnabled: model.autoRefreshSettings.isEnabled,
            seconds: Int(model.autoRefreshSettings.interval(isActive: usesForegroundRefreshInterval))
        )
    }

    private var isConfirmingHomebrewServiceAction: Binding<Bool> {
        Binding(
            get: { pendingHomebrewServiceAction != nil },
            set: { if !$0 { pendingHomebrewServiceAction = nil } }
        )
    }

    private var homebrewServiceConfirmationTitle: String {
        guard let pendingHomebrewServiceAction else { return "" }
        return "\(pendingHomebrewServiceAction.action.title) \(pendingHomebrewServiceAction.service.formula)？"
    }

    private var projectRemovalConfirmationTitle: String {
        let count = pendingProjectRemovalIDs.count
        return count == 1 ? "移除项目记录？" : "批量移除项目记录？"
    }

    private var isConfirmingProjectRemoval: Binding<Bool> {
        Binding(
            get: { !pendingProjectRemovalIDs.isEmpty },
            set: { if !$0 { pendingProjectRemovalIDs.removeAll() } }
        )
    }

    private var isConfirmingRunConfigurationDeletion: Binding<Bool> {
        Binding(
            get: { pendingRunConfigurationDeletion != nil },
            set: { if !$0 { pendingRunConfigurationDeletion = nil } }
        )
    }

    private var isConfirmingProjectRunTrust: Binding<Bool> {
        Binding(
            get: { pendingProjectRunTrust != nil },
            set: { if !$0 { pendingProjectRunTrust = nil } }
        )
    }

    private var isConfirmingRunAllTrust: Binding<Bool> {
        Binding(
            get: { !pendingRunAllConfigurations.isEmpty },
            set: { if !$0 { pendingRunAllConfigurations.removeAll() } }
        )
    }

    private var isConfirmingStopAll: Binding<Bool> {
        Binding(
            get: { !pendingStopAllConfigurationIDs.isEmpty },
            set: { if !$0 { pendingStopAllConfigurationIDs.removeAll() } }
        )
    }

    private func updateRefreshActivity() {
        let wasUsingForegroundInterval = usesForegroundRefreshInterval
        usesForegroundRefreshInterval = scenePhase == .active
            && NSApplication.shared.isActive
            && !NSApplication.shared.isHidden
            && NSApplication.shared.windows.contains { $0.isVisible && !$0.isMiniaturized }
        if !wasUsingForegroundInterval,
           usesForegroundRefreshInterval,
           model.autoRefreshSettings.isEnabled {
            model.refreshDynamicStatus()
        }
    }

    private func navigation(_ snapshot: MachineSnapshot?) -> some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)

                HStack(spacing: 10) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 36, height: 36)
                    Text("DevEnv")
                        .font(.title3.bold())
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 18)

                List(selection: pageSelection) {
                    ForEach(Page.primaryPages, id: \.self) { page in
                        Label(page.title, systemImage: page.systemImage)
                            .font(.system(size: 15, weight: .medium))
                            .imageScale(.large)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                            .tag(page)
                            .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .padding(.top, 14)

                Button {
                    requestPage(.settings)
                } label: {
                    Label(Page.settings.title, systemImage: Page.settings.systemImage)
                        .font(.system(size: 15, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                        .background(
                            selectedPage == .settings ? AppTheme.accent.opacity(0.16) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                }
                .buttonStyle(.plain)
                .padding(10)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
            .background(AppTheme.sidebar)
            .shadow(color: AppTheme.accent.opacity(0.05), radius: 18, x: 5, y: 0)
        } detail: {
            page(snapshot)
        }
        .navigationTitle("")
        .background(AppTheme.canvas)
        .ignoresSafeArea(.container, edges: .top)
    }

    private var topActionButtons: some View {
        HStack(spacing: 10) {
            notificationButton
            refreshButton
        }
        .buttonStyle(.plain)
        .controlSize(.regular)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.86), in: Capsule())
        .padding(8)
        .background(AppTheme.canvas.opacity(0.96), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.top, 12)
        .padding(.trailing, 18)
        .offset(y: -54)
    }

    private var notificationButton: some View {
        Button { isShowingNotifications.toggle() } label: {
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
        .accessibilityLabel(hasUnreadNotices ? "通知，当前有未读通知" : "通知")
        .help("通知")
        .popover(isPresented: $isShowingNotifications) {
            notificationsPopover(currentNotices)
                .onAppear(perform: markCurrentNoticesRead)
        }
    }

    private var refreshButton: some View {
        Button(action: refreshCurrentPage) {
            if isRefreshingCurrentPage {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .accessibilityLabel(refreshCurrentPageLabel)
        .help(refreshCurrentPageHelp)
        .keyboardShortcut("r", modifiers: .command)
        .disabled(isRefreshingCurrentPage)
    }

    private var isRefreshingCurrentPage: Bool {
        selectedPage == .overview
            ? (model.isBusy || projectsModel.isScanning || projectsModel.isRefreshingProjects)
            : (selectedPage?.usesProjectRecords == true
                ? (projectsModel.isScanning || projectsModel.isRefreshingProjects)
                : model.isBusy)
    }

    private var refreshCurrentPageLabel: String {
        selectedPage == .overview
            ? (isRefreshingCurrentPage ? "正在刷新总览" : "刷新总览")
            : selectedPage?.usesProjectRecords == true
            ? (isRefreshingCurrentPage ? "正在刷新项目" : "刷新项目")
            : (model.busyDescription ?? "重新扫描")
    }

    private var refreshCurrentPageHelp: String {
        selectedPage == .overview
            ? "刷新运行、项目与环境状态"
            : (selectedPage?.usesProjectRecords == true ? "刷新项目状态" : (model.busyDescription ?? "重新扫描"))
    }

    private func refreshCurrentPage() {
        if selectedPage == .overview {
            model.scan()
            runCoordinator.refreshProjects()
        } else if selectedPage?.usesProjectRecords == true {
            runCoordinator.refreshProjects()
        } else {
            model.scan()
        }
    }

    private var sidebarToggleButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
            }
        } label: {
            Image(systemName: "sidebar.left")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(columnVisibility == .detailOnly ? "显示侧边栏" : "隐藏侧边栏")
        .help(columnVisibility == .detailOnly ? "显示侧边栏" : "隐藏侧边栏")
    }

    @ViewBuilder
    private func page(_ snapshot: MachineSnapshot?) -> some View {
        if selectedPage?.usesProjectRecords == true {
            populatedPage(selectedPage ?? .projects, snapshot: snapshot)
        } else if let snapshot {
            populatedPage(selectedPage ?? .overview, snapshot: snapshot)
        } else if model.isScanning {
            loadingView
        } else {
            unavailableView
        }
    }

    @ViewBuilder
    private func populatedPage(_ page: Page, snapshot: MachineSnapshot?) -> some View {
        if page.usesProjectRecords {
            Group {
                if page == .projects { projectsPage } else { runsPage }
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if page == .overview, let snapshot {
            overviewPage(snapshot)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header(page, snapshot: snapshot)
                        if let scanError = model.scanError, let snapshot, page != .projects {
                            scanErrorBanner(scanError, snapshot: snapshot)
                        }
                        if let dynamicRefreshError = model.dynamicRefreshError,
                           page == .systemInformation || page == .localServices {
                            dynamicRefreshErrorBanner(dynamicRefreshError)
                        }

                        switch page {
                        case .overview:
                            EmptyView()
                        case .projects:
                            EmptyView()
                        case .runs:
                            EmptyView()
                        case .localServices:
                            if let snapshot { localServicesSection(snapshot) }
                        case .systemInformation:
                            if let snapshot {
                                systemSection(snapshot.system)
                                environmentSection(snapshot)
                                runtimesSection(snapshot.runtimes)
                                    .id(SystemInformationSection.runtimes)
                                databaseInstallationsSection(snapshot.databaseInstallationOverviews)
                                    .id(SystemInformationSection.databases)
                            }
                        case .settings:
                            settingsPage
                        }
                    }
                    .frame(
                        maxWidth: page == .overview || page == .projects || page == .runs || page == .localServices
                            ? 1100
                            : 900
                    )
                    .frame(maxWidth: .infinity)
                    .padding(28)
                }
                .task(id: pendingSystemInformationSection) {
                    guard page == .systemInformation, let section = pendingSystemInformationSection else { return }
                    await Task.yield()
                    proxy.scrollTo(section, anchor: .top)
                    pendingSystemInformationSection = nil
                }
            }
            .id(page)
            .background(AppTheme.canvas)
        }
    }

    private var pageSelection: Binding<Page?> {
        Binding(
            get: { selectedPage },
            set: { page in
                if let page { requestPage(page) }
            }
        )
    }

    private func requestPage(_ page: Page) {
        guard page != selectedPage else { return }
        if selectedPage == .settings, settingsDraft != model.autoRefreshSettings {
            pendingPage = page
            isShowingSettingsExitConfirmation = true
            return
        }
        selectPage(page)
    }

    private func selectPage(_ page: Page) {
        let previousPage = selectedPage
        if previousPage == .projects, page != .projects { projectsModel.leaveProjects() }
        selectedPage = page
        if page == .projects, previousPage != .projects {
            projectsModel.enterProjects()
            runCoordinator.refreshRequirements(machineSnapshot: model.snapshot)
            DispatchQueue.main.async { projectSearchIsFocused = true }
        }
        if page == .runs, previousPage != .runs {
            runCoordinator.refreshProjects()
        }
        if page == .overview, previousPage != .overview {
            runCoordinator.refreshProjects()
            runCoordinator.refreshRequirements(machineSnapshot: model.snapshot)
        }
        if page == .settings { settingsDraft = model.autoRefreshSettings }
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
        .background(AppTheme.canvas)
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

    private func header(_ page: Page, snapshot: MachineSnapshot?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(page.title)
                .font(.largeTitle.bold())
            if page != .settings && page != .projects {
                HStack(spacing: 10) {
                    if page == .localServices {
                        Text(model.dynamicStatusRefreshedAt.map { "最近刷新：\(formatted($0))" } ?? "最近刷新：尚未刷新")
                            .foregroundStyle(.secondary)
                    } else if let snapshot {
                        Text("最近扫描：\(formatted(snapshot.scannedAt))")
                            .foregroundStyle(.secondary)
                    }
                    if model.isBusy {
                        Label(
                            model.isScanning ? "正在更新" : "正在刷新",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var projectsPage: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("项目")
                        .font(.system(size: 29, weight: .bold))
                    Text("\(projectsModel.records.count) 个项目  ·  本次新增 \(projectsModel.records.filter(\.isNew).count) 个")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 20)
                Button { chooseProjectDirectories(forBatchScan: false) } label: {
                    Label("添加项目", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .focused($projectAddIsFocused)
                .disabled(projectsModel.mutationsArePaused || projectsModel.isScanning)
                Button("扫描目录…") { chooseProjectDirectories(forBatchScan: true) }
                    .buttonStyle(.bordered)
                    .disabled(projectsModel.mutationsArePaused || projectsModel.isScanning)
                if isSelectingProjects {
                    Button("取消") {
                        selectedProjectIDs.removeAll()
                        isSelectingProjects = false
                    }
                    Button("全选") { selectedProjectIDs = visibleProjectRecordIDs }
                        .disabled(selectedProjectIDs == visibleProjectRecordIDs)
                    Button("删除（\(selectedProjectIDs.count)）", role: .destructive) {
                        pendingProjectRemovalIDs = selectedProjectIDs
                    }
                    .disabled(
                        selectedProjectIDs.isEmpty
                            || projectsModel.mutationsArePaused
                            || projectsModel.isScanning
                    )
                } else {
                    Button("多选") { isSelectingProjects = true }
                        .buttonStyle(.bordered)
                        .disabled(projectsModel.mutationsArePaused || projectsModel.isScanning)
                }
            }
            .controlSize(.regular)
            .padding(.bottom, 4)

            if let storageError = projectsModel.storageError {
                GroupBox {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "externaldrive.badge.exclamationmark")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("项目记录存储已暂停")
                                .fontWeight(.semibold)
                            Text(storageError)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("重新创建存储…") { isConfirmingProjectStoreReset = true }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
                .background(AppTheme.cardSurface, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.10)))
            }

            if let progress = projectsModel.scanProgress {
                GroupBox {
                    HStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.small)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("正在扫描，已发现 \(progress.discoveredCount) 个项目")
                                .fontWeight(.semibold)
                            Text(progress.currentPath)
                                .font(.callout.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button("取消", action: projectsModel.cancelScan)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("正在扫描项目，已发现 \(progress.discoveredCount) 个，当前目录 \(progress.currentPath)")
                .padding(14)
                .background(AppTheme.cardSurface, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.10)))
            }

            if let error = projectsModel.operationError {
                GroupBox {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityLabel("项目操作失败，\(error)")
                .padding(14)
                .background(AppTheme.cardSurface, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.10)))
            } else if let message = projectsModel.resultMessage {
                Label(message, systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(message)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(AppTheme.cardSurface, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.10)))
            }

            if projectsModel.records.isEmpty && projectsModel.ignoredProjects.isEmpty {
                ContentUnavailableView {
                    Label("尚未添加项目", systemImage: "folder.badge.plus")
                } description: {
                    Text("直接添加 Project Root，或扫描一个临时选择的目录来批量发现项目。")
                } actions: {
                    Button("添加项目…") { chooseProjectDirectories(forBatchScan: false) }
                        .disabled(projectsModel.mutationsArePaused || projectsModel.isScanning)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppTheme.cardSurface, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.10)))
            } else {
                VStack(spacing: 14) {
                    GeometryReader { geometry in
                        HStack(spacing: 12) {
                            projectList
                                .frame(
                                    width: min(max(geometry.size.width * 0.20, 240), 320),
                                    height: geometry.size.height
                                )
                            projectDetail
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .frame(height: geometry.size.height, alignment: .topLeading)
                                .layoutPriority(1)
                        }
                    }
                    if selectedProject != nil {
                        projectStatusBar
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .accessibilityElement(children: .contain)
            }
        }
        .padding(24)
        .background(AppTheme.canvas)
        .onAppear(perform: selectFirstProjectIfNeeded)
        .onChange(of: projectsModel.records.map(\.id)) { _, _ in
            selectFirstProjectIfNeeded()
        }
        .onChange(of: selectedProjectID) { _, _ in
            expandedProjectRequirementID = nil
        }
    }

    private var runsPage: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("运行")
                        .font(.system(size: 29, weight: .bold))
                    Text("管理和运行项目的开发、启动或调试命令")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 20)
                Picker("筛选项目", selection: $runProjectFilterID) {
                    Text("全部项目").tag(Optional<String>.none)
                    ForEach(projectsModel.records) { project in
                        Text(project.title).tag(Optional(project.id))
                    }
                }
                .frame(maxWidth: 260)
                .accessibilityLabel("按项目筛选运行配置")
                Button(action: requestRunAll) {
                    Label("全部启动", systemImage: "play.fill")
                }
                .buttonStyle(.bordered)
                .disabled(runAllConfigurations.isEmpty)
                Button(role: .destructive, action: requestStopAll) {
                    Label("全部停止", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(stopAllConfigurationIDs.isEmpty)
                Button(action: beginCreatingRunConfiguration) {
                    Label("新建配置", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(projectsModel.records.isEmpty || projectsModel.mutationsArePaused)
                .accessibilityLabel("新建运行配置")
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 18)

            runsPageContent
        }
        .padding(24)
        .background(AppTheme.canvas)
        .onAppear(perform: selectFirstRunConfigurationIfNeeded)
        .onChange(of: projectsModel.records.map(\.id)) { _, projectIDs in
            if let runProjectFilterID, !projectIDs.contains(runProjectFilterID) {
                self.runProjectFilterID = nil
            }
        }
        .onChange(of: runProjectFilterID) { _, _ in
            isRunSuggestionsExpanded = false
            selectedRunConfigurationID = visibleRunConfigurations.first?.id
        }
        .onChange(of: runSearchText) { _, _ in
            if !visibleRunConfigurations.contains(where: { $0.id == selectedRunConfigurationID }) {
                selectedRunConfigurationID = visibleRunConfigurations.first?.id
            }
        }
        .alert("信任并全部启动？", isPresented: isConfirmingRunAllTrust) {
            Button("取消", role: .cancel) {}
            Button("信任并全部启动", action: confirmRunAllTrust)
        } message: {
            let roots = untrustedProjectRoots(for: pendingRunAllConfigurations)
            Text("将信任 \(roots.count) 个 Project Root，并启动 \(pendingRunAllConfigurations.count) 个运行配置：\n\n\(roots.joined(separator: "\n"))\n\n确认后，这些 Project Root 的后续运行不再重复询问。")
        }
        .alert("停止全部活动会话？", isPresented: isConfirmingStopAll) {
            Button("取消", role: .cancel) {}
            Button("全部停止", role: .destructive) {
                let configurationIDs = pendingStopAllConfigurationIDs
                pendingStopAllConfigurationIDs.removeAll()
                configurationIDs.forEach { runCoordinator.stop(configurationID: $0) }
            }
        } message: {
            Text("将停止 \(pendingStopAllConfigurationIDs.count) 个活动会话，包括取消正在进行的重启。")
        }
    }

    private func runStorageErrorView(_ error: String) -> some View {
        GroupBox {
            Label("项目记录存储已暂停：\(error)", systemImage: "externaldrive.badge.exclamationmark")
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(28)
    }

    @ViewBuilder
    private var runsPageContent: some View {
        if let storageError = projectsModel.storageError {
            runStorageErrorView(storageError)
        } else if projectsModel.records.isEmpty && runCoordinator.runConfigurations().isEmpty {
            ContentUnavailableView {
                Label("尚未添加项目", systemImage: "folder.badge.plus")
            } description: {
                Text("请先在“项目”页面添加 Project Root，再创建运行配置。")
            } actions: {
                Button("前往项目页面") { selectPage(.projects) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if runCoordinator.runConfigurations(projectID: runProjectFilterID).isEmpty
            && selectedRunSuggestions.isEmpty {
            ContentUnavailableView {
                Label("没有运行配置", systemImage: "play.rectangle")
            } description: {
                Text(runEmptyDescription)
            } actions: {
                Button("新建配置", action: beginCreatingRunConfiguration)
                    .disabled(projectsModel.mutationsArePaused)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 14) {
                GeometryReader { geometry in
                    HStack(spacing: 12) {
                        runConfigurationSidebar
                            .frame(
                                width: min(max(geometry.size.width * 0.20, 240), 320),
                                height: geometry.size.height
                            )
                        runConfigurationDetail
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .frame(height: geometry.size.height, alignment: .topLeading)
                            .layoutPriority(1)
                    }
                }
                .clipped()
                runSessionStatusBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var runEmptyDescription: String {
        runProjectFilterID == nil ? "为项目保存名称、命令和 Project Root 相对工作目录。" : "当前项目尚未保存运行配置。"
    }

    private var selectedRunSuggestions: [ProjectRunSuggestion] {
        runCoordinator.runSuggestions(projectID: runProjectFilterID)
    }

    private var visibleRunConfigurations: [ProjectRunConfiguration] {
        let configurations = runCoordinator.activeConfigurationsFirst(
            runCoordinator.runConfigurations(projectID: runProjectFilterID)
        )
        guard !runSearchText.isEmpty else { return configurations }
        return configurations.filter {
            $0.name.localizedCaseInsensitiveContains(runSearchText)
                || $0.command.localizedCaseInsensitiveContains(runSearchText)
        }
    }

    private var runningConfigurations: [ProjectRunConfiguration] {
        visibleRunConfigurations.filter {
            $0.isEnabled && runCoordinator.session(for: $0.id)?.state.isLive == true
        }
    }

    private var stoppedConfigurations: [ProjectRunConfiguration] {
        visibleRunConfigurations.filter {
            $0.isEnabled && runCoordinator.session(for: $0.id)?.state.isLive != true
        }
    }

    private var disabledConfigurations: [ProjectRunConfiguration] {
        visibleRunConfigurations.filter { !$0.isEnabled }
    }

    private var selectedRunConfiguration: ProjectRunConfiguration? {
        guard let selectedRunConfigurationID else { return visibleRunConfigurations.first }
        return visibleRunConfigurations.first { $0.id == selectedRunConfigurationID }
            ?? visibleRunConfigurations.first
    }

    private var runAllConfigurations: [ProjectRunConfiguration] {
        visibleRunConfigurations.filter { configuration in
            guard configuration.isEnabled,
                  runCoordinator.session(for: configuration.id)?.state.isLive != true,
                  let project = projectsModel.records.first(where: { $0.id == configuration.projectID }) else {
                return false
            }
            return !project.availability.isUnavailable
        }
    }

    private var stopAllConfigurationIDs: [String] {
        visibleRunConfigurations.compactMap { configuration in
            guard let state = runCoordinator.session(for: configuration.id)?.state,
                  state.isLive,
                  state != .stopping else { return nil }
            return configuration.id
        }
    }

    private func requestRunAll() {
        let configurations = runAllConfigurations
        guard !configurations.isEmpty else { return }
        guard !untrustedProjectRoots(for: configurations).isEmpty else {
            runAll(configurations)
            return
        }
        pendingRunAllConfigurations = configurations
    }

    private func requestRunAllGlobal() {
        let configurations = runCoordinator.runConfigurationsToStart()
        guard !configurations.isEmpty else { return }
        selectPage(.runs)
        guard !untrustedProjectRoots(for: configurations).isEmpty else {
            runAll(configurations)
            return
        }
        pendingRunAllConfigurations = configurations
    }

    private func confirmRunAllTrust() {
        let configurations = pendingRunAllConfigurations
        let roots = untrustedProjectRoots(for: configurations)
        pendingRunAllConfigurations.removeAll()
        guard roots.allSatisfy(projectsModel.trustProjectRunRoot) else { return }
        runAll(configurations)
    }

    private func runAll(_ configurations: [ProjectRunConfiguration]) {
        for configuration in configurations
        where runCoordinator.session(for: configuration.id)?.state.isLive != true {
            guard let project = projectsModel.records.first(where: { $0.id == configuration.projectID }) else {
                continue
            }
            _ = runCoordinator.run(configuration, project: project)
        }
    }

    private func untrustedProjectRoots(for configurations: [ProjectRunConfiguration]) -> [String] {
        Set(configurations.compactMap { configuration in
            projectsModel.records.first { $0.id == configuration.projectID }?.path
        }.filter { !projectsModel.isProjectRunTrusted($0) }).sorted()
    }

    private func requestStopAll() {
        pendingStopAllConfigurationIDs = stopAllConfigurationIDs
    }

    private func requestStopAllGlobal() {
        selectPage(.runs)
        pendingStopAllConfigurationIDs = runCoordinator.activeRunConfigurationIDs
    }

    private func selectFirstRunConfigurationIfNeeded() {
        if selectedRunConfigurationID == nil {
            selectedRunConfigurationID = visibleRunConfigurations.first?.id
        }
    }

    private var runConfigurationSidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索配置名称或命令", text: $runSearchText)
                    .textFieldStyle(.plain)
                Text("⌘F")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.10)))
            .padding(14)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    runConfigurationSection(title: "运行中", count: runningConfigurations.count, configurations: runningConfigurations)
                    runConfigurationSection(title: "未启动", count: stoppedConfigurations.count, configurations: stoppedConfigurations)
                    runConfigurationSection(title: "已禁用", count: disabledConfigurations.count, configurations: disabledConfigurations)
                }
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)

            if !selectedRunSuggestions.isEmpty {
                Divider().opacity(0.5)
                DisclosureGroup(isExpanded: $isRunSuggestionsExpanded) {
                    VStack(spacing: 8) {
                        ForEach(selectedRunSuggestions) { suggestion in
                            runSuggestionRow(suggestion)
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Label("运行建议", systemImage: "lightbulb")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .padding(14)
            }
        }
        .background(AppTheme.cardSurface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.10)))
    }

    private var runSessionStatusBar: some View {
        let configuration = selectedRunConfiguration
        let project = configuration.flatMap { selected in
            projectsModel.records.first { $0.id == selected.projectID }
        }
        let state = configuration.flatMap { runCoordinator.session(for: $0.id)?.state } ?? .inactive
        return HStack(spacing: 10) {
            Image(systemName: state.isLive ? "checkmark.shield.fill" : "shield")
                .foregroundStyle(state.isLive ? Color.green : Color.secondary)
                .padding(7)
                .background((state.isLive ? Color.green : Color.secondary).opacity(0.12), in: Circle())
            if configuration?.isEnabled == false {
                Label("已禁用", systemImage: "pause.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                projectRunState(state)
                    .font(.callout)
            }
            Spacer()
            if let project {
                Text("最后更新：\(formatted(project.lastDiscoveredAt))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button("刷新状态") { runCoordinator.refreshProjects() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(runCoordinator.isRefreshingProjects)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(AppTheme.cardSurface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
    }

    private func runConfigurationSection(
        title: String,
        count: Int,
        configurations: [ProjectRunConfiguration]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle()
                    .fill(title == "运行中" ? Color.blue : Color.secondary)
                    .frame(width: 8, height: 8)
                Text("\(title)  \(count)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(title == "运行中" ? Color.blue : Color.primary)
                Spacer()
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            ForEach(configurations) { configuration in
                runConfigurationRow(configuration)
            }
            if !configurations.isEmpty {
                Divider().padding(.horizontal, 14).padding(.top, 4)
            }
        }
    }

    private func runConfigurationRow(_ configuration: ProjectRunConfiguration) -> some View {
        let session = runCoordinator.session(for: configuration.id)
        let isSelected = selectedRunConfiguration?.id == configuration.id
        let state = session?.state ?? .inactive
        let isLive = state.isLive
        let status: (title: String, color: Color) = if !configuration.isEnabled {
            ("已禁用", .secondary)
        } else {
            switch state {
            case .restarting: ("重启中", .blue)
            case .restartFailed: ("重启失败", .orange)
            default: (isLive ? "运行中" : "未启动", isLive ? .green : .secondary)
            }
        }
        return Button {
            selectedRunConfigurationID = configuration.id
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(status.color)
                    .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 4) {
                    Text(configuration.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(configuration.isEnabled ? Color.primary : Color.secondary)
                        .lineLimit(1)
                    Text("\(projectsModel.records.first { $0.id == configuration.projectID }?.title ?? "未知项目") · \(configuration.command)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(status.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(status.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(status.color.opacity(0.12), in: Capsule())
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(isSelected ? Color.blue.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.blue : Color.primary.opacity(0.08), lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
    }

    @ViewBuilder
    private var runConfigurationDetail: some View {
        if let configuration = selectedRunConfiguration {
            runConfigurationDetail(configuration)
        } else {
            ContentUnavailableView("选择一个运行配置", systemImage: "play.rectangle")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func runConfigurationDetail(_ configuration: ProjectRunConfiguration) -> some View {
        let project = projectsModel.records.first { $0.id == configuration.projectID }
        let session = runCoordinator.session(for: configuration.id)
        let state = session?.state ?? .inactive
        return VStack(alignment: .leading, spacing: 12) {
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "terminal.fill")
                            .font(.system(size: 23, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 50, height: 50)
                            .background(Color.blue.gradient, in: RoundedRectangle(cornerRadius: 10))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .center, spacing: 9) {
                                Text(configuration.name)
                                    .font(.title2.bold())
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                    .layoutPriority(1)
                                    .frame(minHeight: 24, alignment: .center)
                                projectRunStatusBadge(state, isEnabled: configuration.isEnabled)
                            }
                            Text(project.map { "\($0.title)" } ?? "所属项目记录不存在")
                                .font(.callout).foregroundStyle(.secondary)
                            Text(project?.path ?? "").font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        HStack(spacing: 6) {
                            if !configuration.isEnabled {
                                Button(session == nil ? "运行" : "重新运行") {}
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.regular)
                                    .frame(minWidth: session == nil ? 60 : 76, minHeight: 36)
                                    .disabled(true)
                            } else if state == .restarting {
                                Button {} label: {
                                    HStack(spacing: 6) {
                                        ProgressView()
                                            .controlSize(.small)
                                        Text("正在重启")
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.regular)
                                .frame(width: 96, height: 36)
                                .disabled(true)
                            } else if state == .stopping {
                                Button {
                                    runCoordinator.stop(configurationID: configuration.id)
                                } label: {
                                    HStack(spacing: 6) {
                                        ProgressView()
                                            .controlSize(.small)
                                        Text("正在停止")
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.red)
                                .controlSize(.regular)
                                .frame(width: 88, height: 36)
                                .disabled(true)
                            } else if state.canRestart {
                                Button("重启") {
                                    guard let project else { return }
                                    runCoordinator.restart(configuration, project: project)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)
                                .frame(minWidth: 60, minHeight: 36)
                                .disabled(project == nil || project?.availability.isUnavailable == true)
                                Button("停止", role: .destructive) { runCoordinator.stop(configurationID: configuration.id) }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.red)
                                    .controlSize(.regular)
                                    .frame(minWidth: 60, minHeight: 36)
                            } else if state.isLive {
                                Button("停止", role: .destructive) { runCoordinator.stop(configurationID: configuration.id) }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.red)
                                    .controlSize(.regular)
                                    .frame(minWidth: 60, minHeight: 36)
                            } else {
                                Button(session == nil ? "运行" : "重新运行") { run(configuration, project: project) }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.regular)
                                    .frame(minWidth: session == nil ? 60 : 76, minHeight: 36)
                                    .disabled(project == nil || project?.availability.isUnavailable == true)
                            }
                            Button("编辑") { beginEditingRunConfiguration(configuration) }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)
                                .frame(minWidth: 60, minHeight: 36)
                                .disabled(projectsModel.mutationsArePaused || state.isLive)
                            Button(configuration.isEnabled ? "禁用" : "启用") {
                                runCoordinator.setRunConfigurationEnabled(
                                    configuration,
                                    isEnabled: !configuration.isEnabled
                                )
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                            .frame(minWidth: 60, minHeight: 36)
                            .disabled(
                                projectsModel.mutationsArePaused
                                    || (configuration.isEnabled && state.isLive)
                            )
                            Menu { Button("删除", role: .destructive) { pendingRunConfigurationDeletion = configuration } } label: {
                                Image(systemName: "ellipsis")
                                    .frame(width: 34, height: 22)
                            }
                            .menuStyle(.button)
                            .controlSize(.regular)
                            .frame(minWidth: 42, minHeight: 36)
                        }
                    }
                    .padding(16)

                    Text("配置详情")
                        .font(.subheadline.weight(.semibold))
                        .padding(.bottom, 10)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(Color.accentColor)
                                .frame(height: 3)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .overlay(alignment: .bottom) {
                            Divider().opacity(0.45)
                        }

                    VStack(alignment: .leading, spacing: 0) {
                        runDetailRow("命令") {
                            runDetailField(configuration.command)
                        }
                        runDetailRow("工作目录") {
                            runDetailField(configuration.workingDirectory == "." ? "项目根目录（.）" : configuration.workingDirectory)
                        }
                        runDetailRow("来源") {
                            if configuration.sourceIdentity != nil {
                                Text(runCoordinator.isSuggestionSourceAvailable(configuration) ? "来自 package.json scripts" : "项目声明已消失")
                                    .foregroundStyle(runCoordinator.isSuggestionSourceAvailable(configuration) ? Color.secondary : Color.orange)
                            } else { Text("手动创建").foregroundStyle(.secondary) }
                        }
                        if let project {
                            runDetailRow("创建时间") { Text(formatted(project.firstDiscoveredAt)).foregroundStyle(.secondary) }
                            runDetailRow("更新时间") { Text(formatted(project.lastDiscoveredAt)).foregroundStyle(.secondary) }
                            runDetailRow("信任状态", showsDivider: false) {
                                Text(projectsModel.isProjectRunTrusted(project.path) ? "首次运行已确认信任" : "首次运行时需要确认")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if runCoordinator.hasCommandDraft(configurationID: configuration.id) {
                            Label("命令修改将在成功启动后保存", systemImage: "clock.arrow.circlepath").foregroundStyle(.secondary).padding(.vertical, 10)
                        }
                    }
                    .padding(10)
                    .background(AppTheme.innerCard, in: RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.primary.opacity(0.10)))
                    .padding(10)
                }
                .background(AppTheme.cardRaised, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.10)))

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("终端会话")
                            .font(.headline)
                            .frame(minHeight: 24, alignment: .center)
                        projectRunStatusBadge(state, isEnabled: configuration.isEnabled)
                        Spacer()
                        if session != nil, !state.isLive {
                            Button("重新运行") { run(configuration, project: project) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(
                                    !configuration.isEnabled
                                        || project == nil
                                        || project?.availability.isUnavailable == true
                                )
                        }
                        if session?.lastSuccessfulCommand != nil {
                            Button("清空") { runCoordinator.clearTerminal(configurationID: configuration.id) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                        if session?.lastSuccessfulCommand != nil, !state.isLive {
                            Button("关闭终端") { runCoordinator.closeTerminal(configurationID: configuration.id) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                        Button {
                            expandedTerminalConfiguration = configuration
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .disabled(session?.lastSuccessfulCommand == nil)
                        .help("放大终端")
                    }
                    if let session,
                       session.lastSuccessfulCommand != nil,
                       expandedTerminalConfiguration?.id != configuration.id {
                        ProjectTerminalView(terminalView: session.terminalView)
                            .id(configuration.id)
                            .frame(minHeight: 280, idealHeight: 360, maxHeight: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .accessibilityLabel("运行配置 \(configuration.name) 的终端")
                    } else {
                        ZStack {
                            LinearGradient(
                                colors: [
                                    Color(red: 0.04, green: 0.08, blue: 0.16),
                                    Color(red: 0.08, green: 0.15, blue: 0.29)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )

                            VStack(spacing: 12) {
                                Image(systemName: "terminal.fill")
                                    .font(.system(size: 30, weight: .semibold))
                                    .foregroundStyle(AppTheme.accent)
                                    .frame(width: 64, height: 64)
                                    .background(AppTheme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .stroke(AppTheme.accent.opacity(0.35), lineWidth: 1)
                                    }
                                Text("终端会话尚未启动")
                                    .font(.headline.weight(.semibold))
                                    .foregroundStyle(.white)
                                Text("运行配置后，终端输出会显示在这里")
                                    .font(.callout)
                                    .foregroundStyle(.white.opacity(0.62))
                                Text("⌘↵ 运行配置")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.white.opacity(0.72))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(.white.opacity(0.10), in: Capsule())
                            }
                            .padding(24)
                        }
                        .frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(AppTheme.accent.opacity(0.28), lineWidth: 1)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("终端会话尚未启动，运行配置后终端输出会显示在这里")
                    }
                }
                .padding(16)
                .background(AppTheme.cardSurface, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.10)))
                .frame(maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $expandedTerminalConfiguration) { configuration in
            expandedTerminalView(configuration)
        }
    }

    private func expandedTerminalView(_ configuration: ProjectRunConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(configuration.name).font(.title2.bold())
                Spacer()
                Button("清空") { runCoordinator.clearTerminal(configurationID: configuration.id) }
                    .disabled(runCoordinator.session(for: configuration.id)?.lastSuccessfulCommand == nil)
                Button("关闭") { expandedTerminalConfiguration = nil }
                    .keyboardShortcut(.cancelAction)
            }
            if let session = runCoordinator.session(for: configuration.id), session.lastSuccessfulCommand != nil {
                ProjectTerminalView(terminalView: session.terminalView)
                    .frame(minWidth: 780, minHeight: 480)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                ContentUnavailableView("终端会话不可用", systemImage: "terminal")
                    .frame(minWidth: 780, minHeight: 480)
            }
        }
        .padding(20)
        .frame(minWidth: 820, minHeight: 560)
    }

    private func runDetailRow<Content: View>(
        _ title: String,
        showsDivider: Bool = true,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 18) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            if showsDivider { Divider().opacity(0.45) }
        }
    }

    private func runDetailField(_ value: String) -> some View {
        let showsCopyButton = hoveredPath == value || focusedCopyPath == value || copiedPath == value

        return HStack(spacing: 8) {
            Text(value)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
            copyButton(value, help: "复制")
                .opacity(showsCopyButton ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(AppTheme.innerCard, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onHover { isHovering in
            if isHovering {
                hoveredPath = value
            } else if hoveredPath == value {
                hoveredPath = nil
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: showsCopyButton)
    }

    private func projectRunStatusBadge(
        _ state: ProjectRunSessionState,
        isEnabled: Bool = true
    ) -> some View {
        let badge: (title: String, symbol: String, color: Color) = if !isEnabled {
            ("已禁用", "pause.circle.fill", .secondary)
        } else {
            switch state {
            case .inactive: ("未启动", "circle.fill", .secondary)
            case .starting: ("正在启动", "hourglass", .blue)
            case .running: ("运行中", "checkmark.circle.fill", .green)
            case .stopping: ("正在停止", "stop.circle.fill", .orange)
            case .stopFailed: ("停止失败", "exclamationmark.triangle.fill", .orange)
            case .restarting: ("正在重启", "arrow.clockwise.circle.fill", .blue)
            case .restartFailed: ("重启失败", "exclamationmark.triangle.fill", .orange)
            case .stopped: ("已结束", "checkmark.circle.fill", .secondary)
            case let .exited(code): (code == 0 ? "已结束" : "异常退出", code == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill", code == 0 ? .secondary : .orange)
            case .launchFailed: ("启动失败", "exclamationmark.triangle.fill", .orange)
            }
        }
        return Label(badge.title, systemImage: badge.symbol)
            .font(.caption2.weight(.semibold))
            .fixedSize()
            .foregroundStyle(badge.color)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(badge.color.opacity(0.13), in: Capsule())
    }

    @ViewBuilder
    private func projectRunState(_ state: ProjectRunSessionState) -> some View {
        switch state {
        case .inactive:
            Label("未启动", systemImage: "pause.circle")
                .foregroundStyle(.secondary)
        case .starting:
            Label("正在启动", systemImage: "hourglass")
                .foregroundStyle(.secondary)
        case .running:
            Label("正在运行", systemImage: "play.circle.fill")
                .foregroundStyle(.green)
        case .stopping:
            Label("正在停止", systemImage: "stop.circle")
                .foregroundStyle(.orange)
        case let .stopFailed(message):
            Label("停止失败：\(message)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .restarting:
            Label("正在重启", systemImage: "arrow.clockwise.circle.fill")
                .foregroundStyle(.blue)
        case let .restartFailed(message):
            Label("重启失败：\(message)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case let .stopped(code):
            Label("用户主动停止 · 退出码 \(code)", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case let .exited(code):
            Label("已退出（退出码 \(code)）", systemImage: code == 0 ? "checkmark.circle" : "xmark.circle")
                .foregroundStyle(code == 0 ? Color.secondary : Color.orange)
        case let .launchFailed(message):
            Label("启动失败：\(message)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private func run(_ configuration: ProjectRunConfiguration, project: ProjectRecord?) {
        guard let project else { return }
        switch runCoordinator.run(configuration, project: project) {
        case let .needsTrust(request):
            pendingProjectRunTrust = request
        case .started:
            selectedRunConfigurationID = configuration.id
        case .rejected:
            break
        }
    }

    private var runConfigurationEditor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: editingRunConfiguration == nil ? "plus" : "slider.horizontal.3")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(AppTheme.accent.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(editingRunConfiguration == nil ? "新建运行配置" : "编辑运行配置")
                        .font(.headline.weight(.semibold))
                    Text("设置项目的启动命令和工作目录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { isShowingRunConfigurationEditor = false } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("取消编辑运行配置")
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                    runConfigurationEditorField("项目", systemImage: "folder") {
                        Picker("项目", selection: $runConfigurationProjectID) {
                            ForEach(projectsModel.records) { project in
                                Text(project.title).tag(project.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .disabled(editingRunConfiguration != nil)
                        .accessibilityLabel("运行配置所属项目")
                    }

                    runConfigurationEditorField("名称", systemImage: "textformat") {
                        TextField("例如：前端开发服务器", text: $runConfigurationName)
                            .textFieldStyle(.plain)
                            .focused($runConfigurationNameIsFocused)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.primary.opacity(0.11))
                            }
                            .accessibilityLabel("运行配置名称")
                    }

                    runConfigurationEditorField("命令", systemImage: "terminal") {
                        TextEditor(text: $runConfigurationCommand)
                            .font(.body.monospaced())
                            .scrollContentBackground(.hidden)
                            .scrollIndicators(.hidden)
                            .frame(height: 72)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 5)
                            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.primary.opacity(0.11))
                            }
                            .accessibilityLabel("运行命令")
                    }

                    runConfigurationEditorField("工作目录", systemImage: "location") {
                        TextField(".", text: $runConfigurationWorkingDirectory)
                            .textFieldStyle(.plain)
                            .font(.body.monospaced())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.primary.opacity(0.11))
                            }
                            .accessibilityLabel("Project Root 相对工作目录")
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Label("启动参数说明", systemImage: "info.circle")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.accent)
                        Text("工作目录使用 Project Root 相对路径；根目录填写 .")
                        if editingRunConfiguration != nil {
                            Text("命令修改将在成功启动后保存；启动失败时保留上次可用命令。")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(AppTheme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(AppTheme.accent.opacity(0.14))
                    }

                    if runConfigurationSaveAttempted, let error = projectsModel.operationError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityLabel("运行配置保存失败，\(error)")
                    }
                }
                .padding(22)

            Divider()
            HStack {
                Button("取消") { isShowingRunConfigurationEditor = false }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(editingRunConfiguration == nil ? "创建配置" : "保存修改", action: saveRunConfiguration)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(runConfigurationProjectID.isEmpty || projectsModel.mutationsArePaused)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(width: 540, height: 580)
        .onAppear {
            DispatchQueue.main.async { runConfigurationNameIsFocused = true }
        }
        .accessibilityElement(children: .contain)
    }

    private func runConfigurationEditorField<Content: View>(
            _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func beginCreatingRunConfiguration() {
        guard let projectID = runProjectFilterID ?? projectsModel.records.first?.id else { return }
        editingRunConfiguration = nil
        runConfigurationProjectID = projectID
        runConfigurationName = ""
        runConfigurationCommand = ""
        runConfigurationWorkingDirectory = "."
        runConfigurationSaveAttempted = false
        runConfigurationSourceIdentity = nil
        isShowingRunConfigurationEditor = true
    }

    private func runSuggestionRow(_ suggestion: ProjectRunSuggestion) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(suggestion.name).font(.headline)
                Text("\(suggestion.sourceDescription) · \(suggestion.workingDirectory)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(suggestion.command)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
            }
            Spacer()
            Button("编辑并采纳") { beginAdoptingSuggestion(suggestion) }
                .buttonStyle(.bordered)
                .accessibilityLabel("编辑并采纳运行建议 \(suggestion.name)")
        }
        .padding(.vertical, 4)
    }

    private func beginAdoptingSuggestion(_ suggestion: ProjectRunSuggestion) {
        editingRunConfiguration = nil
        runConfigurationProjectID = suggestion.projectID
        runConfigurationName = suggestion.name
        runConfigurationCommand = suggestion.command
        runConfigurationWorkingDirectory = suggestion.workingDirectory
        runConfigurationSaveAttempted = false
        runConfigurationSourceIdentity = suggestion.sourceIdentity
        isShowingRunConfigurationEditor = true
    }

    private func beginEditingRunConfiguration(_ configuration: ProjectRunConfiguration) {
        editingRunConfiguration = configuration
        runConfigurationProjectID = configuration.projectID
        runConfigurationName = configuration.name
        runConfigurationCommand = configuration.command
        runConfigurationWorkingDirectory = configuration.workingDirectory
        runConfigurationSaveAttempted = false
        runConfigurationSourceIdentity = configuration.sourceIdentity
        isShowingRunConfigurationEditor = true
    }

    private func saveRunConfiguration() {
        runConfigurationSaveAttempted = true
        let succeeded = if let editingRunConfiguration {
            runCoordinator.updateRunConfiguration(
                editingRunConfiguration,
                name: runConfigurationName,
                command: runConfigurationCommand,
                workingDirectory: runConfigurationWorkingDirectory
            )
        } else {
            runCoordinator.createRunConfiguration(
                projectID: runConfigurationProjectID,
                name: runConfigurationName,
                command: runConfigurationCommand,
                workingDirectory: runConfigurationWorkingDirectory,
                sourceIdentity: runConfigurationSourceIdentity
            ) != nil
        }
        if succeeded { isShowingRunConfigurationEditor = false }
    }

    private var projectList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索项目或路径", text: $projectSearchText)
                    .textFieldStyle(.plain)
                    .focused($projectSearchIsFocused)
                    .accessibilityLabel("搜索项目标题或路径")
                Text("⌘F")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.10)))
            .padding(14)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    Text("项目列表")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.top, 4)

                    let matchingProjects = projectsModel.records(matching: projectSearchText)
                    ForEach(matchingProjects) { project in
                        let isSelected = selectedProjectID == project.id
                        HStack(spacing: 8) {
                            if isSelectingProjects {
                                Toggle("", isOn: projectSelectionBinding(project.id))
                                    .labelsHidden()
                                    .toggleStyle(.checkbox)
                                    .accessibilityLabel("选择 \(project.title)")
                            }
                            Button { selectedProjectID = project.id } label: {
                                projectListRow(project)
                                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .background(isSelected ? Color.blue.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(isSelected ? Color.blue : Color.primary.opacity(0.08), lineWidth: isSelected ? 1.5 : 1)
                        )
                        .padding(.horizontal, 10)
                        .onAppear { projectsModel.markDisplayed(project.id) }
                        .onTapGesture { selectedProjectID = project.id }
                    }
                    if !projectSearchText.isEmpty && matchingProjects.isEmpty {
                        Text("没有匹配的项目")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                    }

                    if !projectsModel.ignoredProjects.isEmpty {
                        HStack {
                            Image(systemName: "eye.slash")
                            Text("已忽略  \(projectsModel.ignoredProjects.count)")
                            Spacer()
                            Image(systemName: "chevron.down")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.top, 18)

                        ForEach(projectsModel.ignoredProjects) { project in
                            HStack(spacing: 8) {
                                if isSelectingProjects {
                                    Toggle("", isOn: projectSelectionBinding(project.id))
                                        .labelsHidden()
                                        .toggleStyle(.checkbox)
                                        .accessibilityLabel("选择 \(project.path)")
                                }
                                Image(systemName: "eye.slash")
                                    .foregroundStyle(.secondary)
                                Text(project.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                if !isSelectingProjects {
                                    Button("恢复") {
                                        projectsModel.restore(project)
                                        selectedProjectID = project.path
                                        projectSearchIsFocused = true
                                    }
                                    .accessibilityLabel("恢复 \(project.path)")
                                    .disabled(projectsModel.isScanning || projectsModel.mutationsArePaused)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
        }
        .background(AppTheme.cardSurface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.10)))
    }

    private func projectListRow(_ project: ProjectRecord) -> some View {
        let summary = projectsModel.summary(for: project)
        let hasActiveSession = runCoordinator.runConfigurations(projectID: project.id).contains {
            runCoordinator.session(for: $0.id)?.state.isLive == true
        }
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "folder.fill")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.blue)
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(project.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    if project.isNew {
                        Text("NEW")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.12), in: Capsule())
                    }
                    Spacer(minLength: 4)
                    if projectsModel.refreshingProjectIDs.contains(project.id) {
                        ProgressView()
                            .controlSize(.mini)
                            .accessibilityLabel("正在刷新 \(project.title)")
                    }
                }
                Text(project.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 5) {
                    Image(systemName: projectSummarySymbol(summary))
                    Text(summary.map(projectSummaryTitle) ?? "待刷新")
                    if projectsModel.staleProjectIDs.contains(project.id) {
                        Text("过期")
                    }
                    if hasActiveSession {
                        HStack(spacing: 5) {
                            Image(systemName: "play.circle.fill")
                            Text("运行中")
                        }
                        .padding(.leading, 3)
                        .foregroundStyle(.green)
                    }
                }
                .font(.caption)
                .foregroundStyle(projectSummaryColor(summary))
            }
        }
        .opacity(project.availability == .available ? 1 : 0.72)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(project.title)，\(project.path)，\(project.isNew ? "New，" : "")"
                + "\(summary.map(projectSummaryTitle) ?? "待刷新")"
                + "\(projectsModel.staleProjectIDs.contains(project.id) ? "，结果已过期" : "")"
                + "\(hasActiveSession ? "，含活动 Project Run Session" : "")"
        )
    }

    @ViewBuilder
    private var projectDetail: some View {
        if let project = selectedProject {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        projectDetailHeader(project)
                        projectSummaryCards(project, analysis: projectsModel.analyses[project.id])
                        if case let .unavailable(reason) = project.availability {
                            Label("项目不可用：\(reason)", systemImage: "folder.badge.questionmark")
                                .foregroundStyle(.secondary)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        }
                        if projectsModel.staleProjectIDs.contains(project.id) {
                            Label("当前路径刷新失败；以下为本次会话最后一次成功结果，已过期。", systemImage: "clock.badge.exclamationmark")
                                .foregroundStyle(.orange)
                                .accessibilityLabel("项目结果已过期，显示本次会话最后一次成功结果")
                        }
                        if projectsModel.refreshingProjectIDs.contains(project.id) {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("正在刷新项目要求…")
                            }
                            .accessibilityElement(children: .combine)
                        }
                        ForEach(projectsModel.projectNotices[project.id] ?? []) { notice in
                            Label("\(notice.relativePath)：\(notice.message)", systemImage: "exclamationmark.triangle")
                                .font(.callout)
                                .foregroundStyle(.orange)
                                .accessibilityLabel("Project Notice，\(notice.relativePath)，\(notice.message)")
                        }
                        Text("环境要求与匹配")
                            .font(.headline)
                        if let analysis = projectsModel.analyses[project.id] {
                            projectAnalysisDetail(analysis)
                        } else if !projectsModel.refreshingProjectIDs.contains(project.id) {
                            ContentUnavailableView {
                                Label("没有项目要求结果", systemImage: "doc.text.magnifyingglass")
                            } description: {
                                Text("刷新项目后将在此展示声明来源和 Machine Environment 证据。")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
            }
            .background(AppTheme.cardRaised, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.10)))
            .id(project.id)
        } else {
            ContentUnavailableView {
                Label("选择一个项目", systemImage: "sidebar.left")
            } description: {
                Text("从列表中选择项目以查看声明来源和 Machine Environment 证据。")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppTheme.cardRaised, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.10)))
        }
    }

    @ViewBuilder
    private var projectStatusBar: some View {
        if let project = selectedProject {
            HStack(spacing: 10) {
                Image(systemName: project.availability == .available ? "checkmark.shield.fill" : "shield")
                    .foregroundStyle(project.availability == .available ? Color.green : Color.secondary)
                    .padding(7)
                    .background(
                        (project.availability == .available ? Color.green : Color.secondary).opacity(0.12),
                        in: Circle()
                    )
                Text(project.availability == .available ? "项目可访问" : "项目不可访问")
                    .font(.callout)
                    .foregroundStyle(project.availability == .available ? Color.green : Color.secondary)
                Spacer()
                Text("最近发现：\(formatted(project.lastDiscoveredAt))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("重新扫描", action: runCoordinator.refreshProjects)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(projectsModel.isScanning || projectsModel.isRefreshingProjects)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(AppTheme.cardSurface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
        }
    }

    private var selectedProject: ProjectRecord? {
        guard let selectedProjectID else { return nil }
        return projectsModel.records.first { $0.id == selectedProjectID }
    }

    private var visibleProjectRecordIDs: Set<String> {
        Set(
            projectsModel.records(matching: projectSearchText).map(\.id)
                + projectsModel.ignoredProjects.map(\.id)
        )
    }

    private func projectSelectionBinding(_ projectID: String) -> Binding<Bool> {
        Binding(
            get: { selectedProjectIDs.contains(projectID) },
            set: { isSelected in
                if isSelected {
                    selectedProjectIDs.insert(projectID)
                } else {
                    selectedProjectIDs.remove(projectID)
                }
            }
        )
    }

    private func projectDetailHeader(_ project: ProjectRecord) -> some View {
        let summary = projectsModel.summary(for: project)
        return HStack(alignment: .top, spacing: 14) {
            Image(systemName: "folder.fill")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.blue)
                .frame(width: 48, height: 42)
                .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Text(project.title)
                        .font(.title2.bold())
                    Label(summary.map(projectSummaryTitle) ?? "待刷新", systemImage: projectSummarySymbol(summary))
                        .foregroundStyle(projectSummaryColor(summary))
                }
                Text(project.path)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityLabel("项目路径 \(project.path)")
                if project.isNew {
                    HStack(spacing: 8) {
                        Text("NEW")
                            .font(.caption.bold())
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.12), in: Capsule())
                        Text("本次扫描新发现")
                            .font(.callout)
                            .foregroundStyle(.blue)
                    }
                }
            }
            Spacer()
            if !isSelectingProjects {
                Button {
                    openRuns(for: project)
                } label: {
                    Label("运行", systemImage: "play.rectangle")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("管理 \(project.title) 的运行配置")
                .help("在运行页面管理此项目的运行配置")
                Menu {
                    Button("移除项目记录", role: .destructive) {
                        pendingProjectRemovalIDs = [project.id]
                    }
                    .disabled(projectsModel.isScanning || projectsModel.mutationsArePaused)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 24, height: 20)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .accessibilityLabel("项目操作")
                .help("项目操作")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func openRuns(for project: ProjectRecord) {
        runProjectFilterID = project.id
        selectPage(.runs)
    }

    private func projectSummaryCards(
        _ project: ProjectRecord,
        analysis: ProjectRequirementsAnalysis?
    ) -> some View {
        let manifests = Array(Set(analysis?.components.flatMap(\.manifestNames) ?? [])).sorted()
        let requirements = analysis?.requirements ?? []
        let capabilities = Array(Set(requirements.map { projectCapabilityTitle($0.capability) })).sorted()
        let unsatisfiedCount = requirements.filter { $0.satisfaction == .unsatisfied }.count
        let discovery = ProjectDiscovery()
        let isGitRepository = discovery.isGitRepository(project.path)
        let gitBranch = discovery.currentGitBranch(project.path)
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
            spacing: 10
        ) {
            projectMetricCard(
                title: "Git 仓库",
                assetName: "GitLogo",
                value: isGitRepository ? "已检测到" : "未检测到",
                detail: gitBranch.map { "当前分支：\($0)" }
                    ?? (isGitRepository ? "当前分支：游离 HEAD" : "未发现 Git 仓库"),
                tint: isGitRepository ? .secondary : .orange
            )
            projectMetricCard(
                title: "项目清单",
                symbol: "doc.text",
                value: "\(manifests.count) 个清单文件",
                detail: manifests.isEmpty ? "未发现支持的清单" : manifests.prefix(2).joined(separator: "、"),
                tint: .secondary
            )
            projectMetricCard(
                title: "环境要求",
                symbol: "viewfinder",
                value: "\(requirements.count) 项",
                detail: capabilities.isEmpty ? "未声明要求" : capabilities.prefix(3).joined(separator: "、"),
                tint: .secondary
            )
            projectMetricCard(
                title: "匹配结果",
                symbol: projectSummarySymbol(analysis?.summary),
                value: analysis.map { projectSummaryTitle($0.summary) } ?? "待刷新",
                detail: "未满足 \(unsatisfiedCount) 项",
                tint: projectSummaryColor(analysis?.summary)
            )
        }
    }

    private func projectMetricCard(
        title: String,
        symbol: String? = nil,
        assetName: String? = nil,
        value: String,
        detail: String,
        tint: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if let assetName {
                    Image(assetName)
                        .resizable()
                        .scaledToFit()
                        .padding(2)
                } else if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .medium))
                }
            }
            .foregroundStyle(assetName == nil ? tint : .orange)
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout)
                    .lineLimit(1)
                Text(value)
                    .font(.caption)
                    .foregroundStyle(tint)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 72, maxHeight: 72, alignment: .topLeading)
        .background(AppTheme.cardSurface, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.separator.opacity(0.65), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func projectAnalysisDetail(_ analysis: ProjectRequirementsAnalysis) -> some View {
        let requirements = analysis.requirements
        if analysis.components.isEmpty || requirements.isEmpty {
            Label("未声明受支持的 Project Requirements", systemImage: "doc.text")
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(requirements.enumerated()), id: \.element.id) { index, requirement in
                    projectRequirementDetail(requirement)
                    if index < requirements.count - 1 { Divider() }
                }
            }
            .background(AppTheme.innerCard, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(.separator.opacity(0.75), lineWidth: 1)
            }
            .onAppear {
                expandedProjectRequirementID = expandedProjectRequirementID ?? requirements.first?.id
            }
        }
    }

    private func projectRequirementDetail(_ requirement: ProjectCapabilityRequirement) -> some View {
        let isExpanded = expandedProjectRequirementID == requirement.id
        return VStack(spacing: 0) {
            Button {
                expandedProjectRequirementID = isExpanded ? nil : requirement.id
            } label: {
                HStack(spacing: 14) {
                    projectCapabilityIcon(requirement.capability)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(projectCapabilityTitle(requirement.capability))
                            .font(.headline)
                        Text("要求：\(requirement.expression)（\(requirement.declarations.count) 个声明）")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(
                        projectRequirementStateTitle(requirement.satisfaction),
                        systemImage: projectRequirementStateSymbol(requirement.satisfaction)
                    )
                    .foregroundStyle(projectRequirementStateColor(requirement.satisfaction))
                    Image(systemName: "chevron.down")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 18)
                .padding(.vertical, 15)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "\(projectCapabilityTitle(requirement.capability))，要求 \(requirement.expression)，"
                    + "\(requirement.declarations.count) 个声明，"
                    + "\(projectRequirementStateTitle(requirement.satisfaction))，"
                    + (isExpanded ? "收起详情" : "展开详情")
            )

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text("声明来源（\(requirement.declarations.count)）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(requirement.declarations) { declaration in
                        HStack(spacing: 12) {
                            Text(declaration.expression)
                                .font(.headline)
                            Text("\(declaration.relativePath) · \(declaration.field)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
                    }
                    Text("匹配环境（\(requirement.matches.count)）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if requirement.matches.isEmpty {
                        Label(
                            requirement.evidence.first ?? projectRequirementEvidenceFallback(requirement.satisfaction),
                            systemImage: projectRequirementStateSymbol(requirement.satisfaction)
                        )
                        .font(.callout)
                        .foregroundStyle(projectRequirementStateColor(requirement.satisfaction))
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
                    } else {
                        ForEach(requirement.matches, id: \.path) { match in
                            HStack(spacing: 12) {
                                Image(systemName: "checkmark.circle")
                                    .foregroundStyle(.green)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 8) {
                                        Text(match.version)
                                            .font(.headline)
                                        if let source = match.source {
                                            Text(source)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 7)
                                                .padding(.vertical, 3)
                                                .background(.secondary.opacity(0.1), in: Capsule())
                                        }
                                    }
                                    Text(match.path)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 3) {
                                    Text("\(projectCapabilityTitle(requirement.capability)) \(match.version)")
                                    if let listeningState = match.listeningState {
                                        let listening = databaseListeningStyle(listeningState)
                                        Label(listening.title, systemImage: listening.symbol)
                                            .foregroundStyle(listening.color)
                                            .accessibilityLabel("Database Listening State：\(listening.title)")
                                    } else {
                                        Text("优先级：\(match.isEffective ? "高" : "中")")
                                    }
                                }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                            .background(.background.opacity(0.72), in: RoundedRectangle(cornerRadius: 9))
                            .overlay {
                                RoundedRectangle(cornerRadius: 9)
                                    .stroke(.separator.opacity(0.55), lineWidth: 1)
                            }
                        }
                    }
                }
                .padding(14)
                .background(.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
                .padding(.leading, 72)
                .padding(.trailing, 18)
                .padding(.bottom, 16)
            }
        }
    }

    @ViewBuilder
    private func projectCapabilityIcon(_ capability: String) -> some View {
        if let brand = runtimeBrand(capability) {
            runtimeLogo(brand)
        } else if capability == "mysql-compatible" {
            HStack(spacing: 4) {
                databaseLogo("mysql", size: 22, padding: 4)
                databaseLogo("mariadb", size: 22, padding: 4)
            }
            .frame(width: 48, height: 48)
        } else if ["postgresql", "mysql", "mariadb", "mongodb", "redis"].contains(capability) {
            databaseLogo(capability, size: 48, padding: 8)
        } else {
            Image(systemName: capability == "docker-compose" ? "shippingbox.fill" : "terminal.fill")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(.blue)
                .frame(width: 48, height: 48)
        }
    }

    private func projectCapabilityTitle(_ capability: String) -> String {
        switch capability {
        case "node": "Node.js"
        case "python": "Python"
        case "docker-compose": "Docker Compose"
        case "go": "Go"
        case "java": "Java"
        case "rust": "Rust"
        case "ruby": "Ruby"
        case "lua": "Lua"
        case "postgresql": "PostgreSQL"
        case "mysql": "MySQL"
        case "mariadb": "MariaDB"
        case "mongodb": "MongoDB"
        case "redis": "Redis"
        case "mysql-compatible": "MySQL 兼容数据库要求"
        default: capability
        }
    }

    private func projectBoundaryTitle(_ boundary: ProjectRootBoundary) -> String {
        switch boundary {
        case .git: "Git 根目录"
        case .manifest: "项目清单"
        case .explicit: "手动添加"
        }
    }

    private func projectSummaryTitle(_ summary: ProjectRequirementsSummary) -> String {
        switch summary {
        case .satisfied: "已满足"
        case .unsatisfied: "未满足"
        case .undetermined: "无法判断"
        case .declarationConflict: "声明冲突"
        case .undeclared: "未声明要求"
        case .unavailable: "不可用"
        }
    }

    private func projectRequirementStateTitle(_ state: ProjectRequirementSatisfactionState) -> String {
        switch state {
        case .satisfied: "已满足"
        case .unsatisfied: "未满足"
        case .undetermined: "无法判断"
        case .declarationConflict: "声明冲突"
        }
    }

    private func projectSummarySymbol(_ summary: ProjectRequirementsSummary?) -> String {
        switch summary {
        case .satisfied: "checkmark.circle"
        case .unsatisfied: "xmark.circle"
        case .undetermined: "questionmark.circle"
        case .declarationConflict: "exclamationmark.triangle"
        case .undeclared: "doc.text"
        case .unavailable: "folder.badge.questionmark"
        case nil: "clock"
        }
    }

    private func projectSummaryColor(_ summary: ProjectRequirementsSummary?) -> Color {
        switch summary {
        case .satisfied: .green
        case .unsatisfied: .red
        case .undetermined, .undeclared, .unavailable, nil: .secondary
        case .declarationConflict: .orange
        }
    }

    private func projectRequirementStateSymbol(_ state: ProjectRequirementSatisfactionState) -> String {
        switch state {
        case .satisfied: "checkmark.circle"
        case .unsatisfied: "xmark.circle"
        case .undetermined: "questionmark.circle"
        case .declarationConflict: "exclamationmark.triangle"
        }
    }

    private func projectRequirementStateColor(_ state: ProjectRequirementSatisfactionState) -> Color {
        switch state {
        case .satisfied: .green
        case .unsatisfied: .red
        case .undetermined: .secondary
        case .declarationConflict: .orange
        }
    }

    private func projectRequirementEvidenceFallback(_ state: ProjectRequirementSatisfactionState) -> String {
        switch state {
        case .satisfied: "Machine Snapshot 已满足该声明"
        case .unsatisfied: "未找到满足声明的可用安装"
        case .undetermined: "Machine Environment 证据不足，无法判断"
        case .declarationConflict: "项目中的声明无法由单个安装同时满足"
        }
    }

    private func selectFirstProjectIfNeeded() {
        if let selectedProjectID, projectsModel.records.contains(where: { $0.id == selectedProjectID }) {
            return
        }
        selectedProjectID = projectsModel.records.first?.id
    }

    private func chooseProjectDirectories(forBatchScan: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = forBatchScan ? "扫描" : "添加"
        panel.message = forBatchScan
            ? "选择一个或多个临时 Project Search Root；所选扫描目录不会持久化。"
            : "选择一个或多个目录作为明确的 Project Root。"
        panel.begin { response in
            guard response == .OK else { return }
            if forBatchScan {
                projectsModel.scan(panel.urls)
            } else {
                projectsModel.addDirect(panel.urls)
            }
        }
    }

    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))

                VStack(alignment: .leading, spacing: 2) {
                    Text("外观")
                        .font(.headline)
                    Text("选择应用界面的显示模式")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("主题模式")
                            .fontWeight(.medium)
                        Text("选择后立即生效")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("主题模式", selection: $appAppearance) {
                        ForEach(AppAppearance.allCases, id: \.self) { appearance in
                            Text(appearance.title).tag(appearance)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 280)
                }
                .padding(10)
            }

            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))

                VStack(alignment: .leading, spacing: 2) {
                    Text("动态状态刷新")
                        .font(.headline)
                    Text("自动更新本地服务与已知数据库的监听状态")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox {
                VStack(spacing: 0) {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("定时刷新")
                                .fontWeight(.medium)
                            Text("关闭后保留当前的刷新间隔")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("定时刷新", isOn: $settingsDraft.isEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    .padding(.vertical, 6)

                    Divider()
                        .padding(.vertical, 14)

                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("前台刷新间隔")
                                .fontWeight(.medium)
                            Text("应用处于活动状态时")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Stepper(value: foregroundSeconds, in: AutoRefreshSettings.foregroundRange) {
                            Text("\(settingsDraft.foregroundSeconds) 秒")
                                .monospacedDigit()
                                .frame(width: 64, alignment: .trailing)
                        }
                        .fixedSize()
                        .accessibilityLabel("前台刷新间隔")
                        .accessibilityValue("\(settingsDraft.foregroundSeconds) 秒")
                    }
                    .disabled(!settingsDraft.isEnabled)

                    Divider()
                        .padding(.vertical, 14)

                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("后台刷新间隔")
                                .fontWeight(.medium)
                            Text("应用非活动、隐藏或最小化时")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Stepper(value: backgroundSeconds, in: AutoRefreshSettings.backgroundRange) {
                            Text("\(settingsDraft.backgroundSeconds) 秒")
                                .monospacedDigit()
                                .frame(width: 64, alignment: .trailing)
                        }
                        .fixedSize()
                        .accessibilityLabel("后台刷新间隔")
                        .accessibilityValue("\(settingsDraft.backgroundSeconds) 秒")
                    }
                    .disabled(!settingsDraft.isEnabled)
                }
                .padding(10)
            }

            if settingsDraft != model.autoRefreshSettings {
                HStack {
                    Text("有未保存的修改")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("保存") {
                        saveSettings()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxWidth: 640)
    }

    private var foregroundSeconds: Binding<Int> {
        Binding(
            get: { settingsDraft.foregroundSeconds },
            set: { value in
                settingsDraft.foregroundSeconds = value
                settingsDraft.backgroundSeconds = max(settingsDraft.backgroundSeconds, value)
            }
        )
    }

    private var backgroundSeconds: Binding<Int> {
        Binding(
            get: { settingsDraft.backgroundSeconds },
            set: { settingsDraft.backgroundSeconds = max($0, settingsDraft.foregroundSeconds) }
        )
    }

    private func saveSettings() {
        model.saveAutoRefreshSettings(settingsDraft)
        settingsDraft = model.autoRefreshSettings
    }

    private var settingsExitConfirmation: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("设置尚未保存")
                    .font(.title3.bold())
                Spacer()
                Button {
                    isShowingSettingsExitConfirmation = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭并继续编辑")
            }

            Text("修改需要保存后才会生效。直接离开将放弃已修改的内容。")
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("放弃修改", role: .destructive) {
                    leaveSettings(saving: false)
                }
                Button("保存并离开") {
                    leaveSettings(saving: true)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 430)
    }

    private func leaveSettings(saving: Bool) {
        guard let pendingPage else { return }
        if saving {
            saveSettings()
        } else {
            settingsDraft = model.autoRefreshSettings
        }
        isShowingSettingsExitConfirmation = false
        selectPage(pendingPage)
        self.pendingPage = nil
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
                    .disabled(model.isBusy)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func dynamicRefreshErrorBanner(_ error: String) -> some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("自动刷新失败，当前显示上次结果")
                        .fontWeight(.semibold)
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("立即刷新", action: model.refreshDynamicStatus)
                    .disabled(model.isBusy)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func overviewPage(_ snapshot: MachineSnapshot) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let runs = overviewRuns(snapshot)
            let attention = overviewAttentionItems(snapshot, runs: runs, now: context.date)

            VStack(alignment: .leading, spacing: 12) {
                overviewHeader(snapshot, now: context.date)

                GeometryReader { geometry in
                    let attentionWidth = min(max(geometry.size.width * 0.32, 280), 350)
                    let visibleRunLimit = overviewVisibleRunLimit(
                        cardHeight: geometry.size.height,
                        itemCount: runs.count
                    )
                    let visibleAttentionLimit = overviewVisibleAttentionLimit(
                        cardHeight: geometry.size.height,
                        itemCount: attention.count
                    )
                    HStack(alignment: .top, spacing: 12) {
                        overviewRunningCard(runs, visibleLimit: visibleRunLimit, now: context.date)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        overviewAttentionCard(attention, visibleLimit: visibleAttentionLimit)
                            .frame(width: attentionWidth)
                            .frame(maxHeight: .infinity)
                    }
                }
                .frame(minHeight: 322)

                overviewEnvironmentSummary(snapshot)
                overviewBaseConfiguration(snapshot)
                overviewSystemSummary(snapshot.system)
            }
            .frame(maxWidth: 1100, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(AppTheme.canvas)
    }

    private func overviewHeader(_ snapshot: MachineSnapshot, now: Date) -> some View {
        let isRefreshing = model.isBusy || projectsModel.isScanning || projectsModel.isRefreshingProjects
        let dynamicUpdatedAt = model.dynamicStatusRefreshedAt ?? snapshot.scannedAt
        let isStale = now.timeIntervalSince(dynamicUpdatedAt) > 60
            || now.timeIntervalSince(snapshot.scannedAt) > 24 * 60 * 60

        return VStack(alignment: .leading, spacing: 5) {
            Text("总览")
                .font(.system(size: 30, weight: .bold))
            HStack(spacing: 8) {
                Text("运行状态：\(relativeUpdateText(dynamicUpdatedAt, now: now)) · 环境扫描：\(relativeCompletionText(snapshot.scannedAt, now: now))")
                if isRefreshing {
                    Label("正在更新", systemImage: "arrow.triangle.2.circlepath")
                } else if isStale {
                    Label("状态可能已过期", systemImage: "clock.badge.exclamationmark")
                        .foregroundStyle(.orange)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private func overviewRunningCard(_ runs: [OverviewRun], visibleLimit: Int, now: Date) -> some View {
        let visibleRuns = Array(runs.prefix(visibleLimit))

        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("运行会话")
                    .font(.title3.bold())
                Text(runs.count.formatted())
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.07), in: Capsule())
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 48)

            if runs.isEmpty {
                Button {
                    selectPage(.runs)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("当前没有运行会话")
                            .font(.callout.weight(.semibold))
                        Text("启动运行配置后，会在这里显示实时状态")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("查看运行配置")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.top, 2)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                VStack(spacing: 6) {
                    ForEach(visibleRuns) { run in
                        overviewRunRow(run, now: now)
                    }

                    if runs.count > visibleRuns.count {
                        Button("还有 \(runs.count - visibleRuns.count) 个运行会话") {
                            selectPage(.runs)
                        }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 16)
                        .frame(height: 30, alignment: .leading)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .overviewCard()
    }

    private func overviewRunRow(_ run: OverviewRun, now: Date) -> some View {
        let summary = projectsModel.summary(for: run.project)
        let tint = overviewRunColor(run.session.state)
        return Button {
            selectedRunConfigurationID = run.configuration.id
            selectPage(.runs)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
                    .padding(.top, 9)
                    .accessibilityHidden(true)

                overviewRunLogo(run)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(run.project.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if run.session.state == .running, let startedAt = run.session.startedAt {
                            Text("已运行 \(runDuration(from: startedAt, now: now))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                    }

                    HStack(spacing: 8) {
                        HStack(spacing: 5) {
                            Text(run.configuration.name)
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text(repositoryStateText(run.repositoryState))
                                .monospaced()
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(1)

                        Spacer(minLength: 4)

                        Text(projectRunStateTitle(run.session.state))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(tint)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(tint.opacity(0.10), in: Capsule())
                            .fixedSize()

                        Divider().frame(height: 16)

                        Label(overviewPortsText(run), systemImage: "network")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .fixedSize()

                        Divider().frame(height: 16)

                        TimelineView(.periodic(from: .now, by: 2)) { _ in
                            Label("内存 \(overviewMemoryText(run))", systemImage: "memorychip")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }

                        Divider().frame(height: 16)

                        Label(
                            overviewProjectRequirementText(summary),
                            systemImage: projectSummarySymbol(summary)
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(projectSummaryColor(summary))
                        .fixedSize()
                    }

                    Text(run.session.lastSuccessfulCommand ?? run.configuration.command)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overviewListItemCard()
        .accessibilityLabel("\(run.project.title)，\(run.configuration.name)，\(projectRunStateTitle(run.session.state))")
    }

    @ViewBuilder
    private func overviewRunLogo(_ run: OverviewRun) -> some View {
        if let brand = overviewRunBrand(run) {
            runtimeLogo(brand, size: 42, padding: 7, cornerRadius: 9)
        } else {
            Image(systemName: "terminal.fill")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(.blue)
                .frame(width: 42, height: 42)
                .background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
        }
    }

    private func overviewRunBrand(_ run: OverviewRun) -> (assetName: String, color: Color)? {
        guard let analysis = projectsModel.analyses[run.project.id] else { return nil }
        let componentCapabilities = analysis.components
            .first { $0.relativePath == run.configuration.workingDirectory }?
            .requirements.map(\.capability) ?? []
        return (componentCapabilities + analysis.requirements.map(\.capability))
            .lazy.compactMap(runtimeBrand).first
    }

    private func overviewAttentionCard(_ items: [OverviewAttentionItem], visibleLimit: Int) -> some View {
        let visibleItems = Array(items.prefix(visibleLimit))

        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("需要关注")
                    .font(.title3.bold())
                if !items.isEmpty {
                    Text(items.count.formatted())
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 48)

            if items.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("当前没有需要处理的问题")
                        .font(.callout.weight(.semibold))
                    Text("运行会话和环境扫描状态正常")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                VStack(spacing: 6) {
                    ForEach(visibleItems) { item in
                        overviewAttentionRow(item)
                    }

                    if items.count > visibleItems.count {
                        Button("查看全部 \(items.count) 项提醒") { isShowingNotifications = true }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 14)
                            .frame(height: 30, alignment: .leading)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .overviewCard()
    }

    private func overviewAttentionRow(_ item: OverviewAttentionItem) -> some View {
        Button { navigate(to: item.destination) } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(item.tint)
                    .frame(width: 18, height: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 3)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 3)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overviewListItemCard()
    }

    private func overviewEnvironmentSummary(_ snapshot: MachineSnapshot) -> some View {
        let projectSummaries = projectsModel.records.compactMap { projectsModel.summary(for: $0) }
        let satisfiedProjects = projectSummaries.count { $0 == .satisfied }
        let unsatisfiedProjects = projectSummaries.count { $0 == .unsatisfied }
        let otherProjects = projectsModel.records.count - satisfiedProjects - unsatisfiedProjects
        let discoveredRuntimes = snapshot.runtimes.filter { runtime in
            runtime.installations.contains { $0.state == .discovered }
        }
        let runtimeVersionKeys: [String] = discoveredRuntimes.flatMap { runtime -> [String] in
            runtime.installations.compactMap { installation in
                guard installation.state == .discovered, let version = installation.version else { return nil }
                return "\(runtime.id):\(version)"
            }
        }
        let runtimeVersions = Set(runtimeVersionKeys)
        let installations = snapshot.databaseInstallationOverviews.flatMap(\.installations)
        let listeningInstallations = installations.count { $0.listeningState == .listening }
        let processCount = Set(snapshot.localServices.map(\.pid)).count
        let portCount = Set(snapshot.localServices.flatMap { $0.bindings.map(\.port) }).count
        let runtimeResultsArePartial = snapshot.runtimes.contains { $0.state == .failed }
        let databaseResultsArePartial = snapshot.databaseInstallationOverviews.contains {
            $0.discoveryState == .unknown || $0.listeningState == .unknown
        }
        let localServiceResultsArePartial = snapshot.localServiceScanNotice != nil

        return VStack(alignment: .leading, spacing: 7) {
            Text("环境概况")
                .font(.headline)
            HStack(spacing: 10) {
                overviewSummaryCard(
                    title: "项目要求状态",
                    value: "\(satisfiedProjects) 个项目满足",
                    detail: "\(unsatisfiedProjects) 个不满足 · \(otherProjects) 个待判断",
                    systemImage: "folder",
                    tint: AppTheme.accent
                ) { selectPage(.projects) }
                overviewSummaryCard(
                    title: "开发语言",
                    value: "发现 \(discoveredRuntimes.count) 类",
                    detail: runtimeResultsArePartial
                        ? "\(runtimeVersions.count) 个安装版本 · 部分结果不可用"
                        : "共 \(runtimeVersions.count) 个安装版本",
                    systemImage: "terminal",
                    tint: .purple
                ) { selectSystemInformation(.runtimes) }
                overviewSummaryCard(
                    title: "数据库",
                    value: "已安装 \(installations.count) 个",
                    detail: databaseResultsArePartial
                        ? "\(listeningInstallations) 个正在监听 · 部分结果不可用"
                        : "\(listeningInstallations) 个正在监听",
                    systemImage: "cylinder",
                    tint: .orange
                ) { selectSystemInformation(.databases) }
                overviewSummaryCard(
                    title: "本地服务",
                    value: "\(processCount) 个监听进程",
                    detail: localServiceResultsArePartial
                        ? "共监听 \(portCount) 个端口 · 部分结果不可用"
                        : "共监听 \(portCount) 个端口",
                    systemImage: "network",
                    tint: .cyan
                ) { selectPage(.localServices) }
            }
        }
    }

    private func overviewSummaryCard(
        title: String,
        value: String,
        detail: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overviewCard(cornerRadius: 12)
    }

    private func overviewBaseConfiguration(_ snapshot: MachineSnapshot) -> some View {
        let pathManagers = snapshot.packageManagers.count {
            $0.state == .available || $0.state == .configured
        }
        let terminals = snapshot.terminalApplications
        let defaultShell = snapshot.shellInstallations.first(where: \.isDefault)

        return VStack(alignment: .leading, spacing: 7) {
            Text("基础配置")
                .font(.headline)
            HStack(spacing: 0) {
                overviewBaseItem(
                    title: "包管理器",
                    value: snapshot.homebrew.version.map { "Homebrew \($0)" }
                        ?? (snapshot.homebrew.available ? "Homebrew" : "未发现 Homebrew"),
                    detail: "另发现 \(pathManagers) 个 PATH 工具",
                    assetName: "PackageManagerHomebrewLogo",
                    systemImage: nil,
                    isProblem: !snapshot.homebrew.available,
                    tint: .orange,
                    card: .packageManagers
                )
                Divider().frame(height: 44)
                overviewBaseItem(
                    title: "Git",
                    value: snapshot.gitCLI.version ?? (snapshot.gitCLI.state == .available ? "可用" : "未发现"),
                    detail: "当前生效 CLI",
                    assetName: "GitLogo",
                    systemImage: nil,
                    isProblem: snapshot.gitCLI.state != .available,
                    tint: .orange,
                    card: .git
                )
                Divider().frame(height: 44)
                overviewBaseItem(
                    title: "Terminal",
                    value: terminals.isEmpty ? "未发现" : "发现 \(terminals.count) 个",
                    detail: terminals.isEmpty
                        ? "未发现应用"
                        : terminals.prefix(2).map(\.name).joined(separator: " · "),
                    assetName: nil,
                    systemImage: "macwindow.on.rectangle",
                    isProblem: terminals.isEmpty,
                    tint: .cyan,
                    card: .terminal
                )
                Divider().frame(height: 44)
                overviewBaseItem(
                    title: "默认 Shell",
                    value: defaultShell?.name ?? "未发现",
                    detail: defaultShell?.path ?? "账户默认 Shell 不可用",
                    assetName: nil,
                    systemImage: "terminal",
                    isProblem: defaultShell?.isAvailable != true,
                    tint: .indigo,
                    card: .shell
                )
            }
            .frame(height: 68)
            .overviewCard(cornerRadius: 12)
        }
    }

    private func overviewBaseItem(
        title: String,
        value: String,
        detail: String,
        assetName: String?,
        systemImage: String?,
        isProblem: Bool,
        tint: Color,
        card: EnvironmentCard
    ) -> some View {
        let iconTint = isProblem ? Color.orange : tint
        return Button {
            expandedEnvironmentCard = card
            selectPage(.systemInformation)
        } label: {
            HStack(spacing: 10) {
                Group {
                    if let assetName {
                        Image(assetName).resizable().scaledToFit().padding(6)
                    } else if let systemImage {
                        Image(systemName: systemImage)
                            .font(.system(size: 15, weight: .medium))
                    }
                }
                .foregroundStyle(iconTint)
                .frame(width: 30, height: 30)
                .background(iconTint.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(isProblem ? .orange : .primary)
                        .lineLimit(1)
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.plain)
    }

    private func overviewSystemSummary(_ system: SystemSnapshot) -> some View {
        let usedRatio: Double? = if let total = system.diskTotalBytes,
                                    let free = system.diskFreeBytes,
                                    total > 0 {
            Double(total > free ? total - free : 0) / Double(total)
        } else { nil }
        let diskText = usedRatio.map {
            "系统卷已使用 \($0.formatted(.percent.precision(.fractionLength(0))))"
        } ?? "系统卷使用情况未知"
        let lowDisk = (system.diskFreeBytes ?? .max) < 20 * 1_024 * 1_024 * 1_024

        return HStack(spacing: 6) {
            Image(systemName: "desktopcomputer")
            Text("macOS \(system.macOSVersion ?? "未知") · \(system.architecture ?? "未知") · \(byteCount(system.memoryBytes)) 内存 · \(diskText)")
        }
        .font(.caption)
        .foregroundStyle(lowDisk ? .orange : .secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func overviewRuns(_ snapshot: MachineSnapshot) -> [OverviewRun] {
        let projects = Dictionary(uniqueKeysWithValues: projectsModel.records.map { ($0.id, $0) })
        return runCoordinator.runConfigurations().compactMap { configuration in
            guard let project = projects[configuration.projectID],
                  let session = runCoordinator.session(for: configuration.id),
                  session.state.isLive || session.failureMessage != nil else { return nil }
            let bindings: [ListenerBinding]? = if session.state == .running,
                                                  let processIDs = session.ownedProcessIDs {
                Array(Set(snapshot.localServices
                    .filter { processIDs.contains(pid_t($0.pid)) }
                    .flatMap(\.bindings)))
                    .sorted { lhs, rhs in
                        lhs.port == rhs.port ? lhs.address < rhs.address : lhs.port < rhs.port
                    }
            } else { nil }
            return OverviewRun(
                configuration: configuration,
                project: project,
                session: session,
                bindings: bindings,
                repositoryState: ProjectRepositoryState.read(projectRoot: project.path)
            )
        }
        .sorted { lhs, rhs in
            let lhsStarting = lhs.session.state == .starting
            let rhsStarting = rhs.session.state == .starting
            if lhsStarting != rhsStarting { return lhsStarting }
            let lhsDate = lhs.session.startedAt ?? .distantPast
            let rhsDate = rhs.session.startedAt ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.configuration.id < rhs.configuration.id
        }
    }

    private func overviewAttentionItems(
        _ snapshot: MachineSnapshot,
        runs: [OverviewRun],
        now: Date
    ) -> [OverviewAttentionItem] {
        let configurations = runCoordinator.runConfigurations()
        let projects = Dictionary(uniqueKeysWithValues: projectsModel.records.map { ($0.id, $0) })
        var items: [OverviewAttentionItem] = configurations.compactMap { configuration in
            guard let session = runCoordinator.session(for: configuration.id),
                  let message = session.failureMessage else { return nil }
            return OverviewAttentionItem(
                id: "run-failure:\(configuration.id)",
                title: "\(projects[configuration.projectID]?.title ?? configuration.name) 运行失败",
                detail: "\(configuration.name)：\(message)",
                systemImage: "exclamationmark.octagon.fill",
                tint: .red,
                priority: 0,
                occurredAt: session.failureAt,
                destination: .run(configuration.id)
            )
        }

        let dynamicUpdatedAt = model.dynamicStatusRefreshedAt ?? snapshot.scannedAt
        if let error = model.dynamicRefreshError {
            items.append(OverviewAttentionItem(
                id: "dynamic-refresh-failed",
                title: "运行状态刷新失败",
                detail: error,
                systemImage: "clock.badge.exclamationmark",
                tint: .orange,
                priority: 1,
                occurredAt: dynamicUpdatedAt,
                destination: .dynamicRefresh
            ))
        } else if now.timeIntervalSince(dynamicUpdatedAt) > 60 {
            items.append(OverviewAttentionItem(
                id: "dynamic-status-stale",
                title: "运行状态已过期",
                detail: "超过 60 秒没有成功刷新监听状态",
                systemImage: "clock.badge.exclamationmark",
                tint: .orange,
                priority: 1,
                occurredAt: dynamicUpdatedAt,
                destination: .dynamicRefresh
            ))
        }

        if let error = model.scanError {
            items.append(OverviewAttentionItem(
                id: "environment-scan-failed",
                title: "环境扫描失败",
                detail: error,
                systemImage: "exclamationmark.triangle.fill",
                tint: .orange,
                priority: 1,
                occurredAt: snapshot.scannedAt,
                destination: .environmentRefresh
            ))
        } else if now.timeIntervalSince(snapshot.scannedAt) > 24 * 60 * 60 {
            items.append(OverviewAttentionItem(
                id: "environment-snapshot-stale",
                title: "环境扫描结果已过期",
                detail: "超过 24 小时没有完成一次环境扫描",
                systemImage: "clock.badge.exclamationmark",
                tint: .orange,
                priority: 1,
                occurredAt: snapshot.scannedAt,
                destination: .environmentRefresh
            ))
        }

        let runtimeCapabilities: Set<String> = ["node", "python", "go", "java", "rust", "ruby", "lua"]
        let databaseCapabilities: Set<String> = ["postgresql", "mysql", "mariadb", "mongodb", "redis", "mysql-compatible"]
        let activeProjectIDs = Set(runs.filter { $0.session.state.isLive }.map { $0.project.id })
        var runtimeProblemIDs: Set<String> = []

        for projectID in activeProjectIDs.sorted() {
            guard let project = projects[projectID], let analysis = projectsModel.analyses[projectID] else { continue }
            for requirement in analysis.requirements {
                let itemID = "project-requirement:\(projectID):\(requirement.capability)"
                if runtimeCapabilities.contains(requirement.capability)
                    && (requirement.satisfaction == .unsatisfied
                        || requirement.satisfaction == .declarationConflict) {
                    runtimeProblemIDs.insert(itemID)
                    items.append(OverviewAttentionItem(
                        id: itemID,
                        title: "\(project.title) 的 \(projectCapabilityTitle(requirement.capability)) 要求未满足",
                        detail: requirement.satisfaction == .declarationConflict
                            ? "项目内存在无法同时满足的版本声明"
                            : "要求 \(requirement.expression)",
                        systemImage: "terminal.fill",
                        tint: .red,
                        priority: 2,
                        occurredAt: nil,
                        destination: .project(projectID, capability: requirement.capability)
                    ))
                    continue
                }

                if databaseCapabilities.contains(requirement.capability) {
                    if requirement.satisfaction == .unsatisfied {
                        items.append(OverviewAttentionItem(
                            id: itemID,
                            title: "\(project.title) 缺少 \(projectCapabilityTitle(requirement.capability))",
                            detail: "未发现满足项目要求的数据库安装",
                            systemImage: "cylinder.split.1x2.fill",
                            tint: .red,
                            priority: 2,
                            occurredAt: nil,
                            destination: .database(databaseDestinationID(requirement.capability))
                        ))
                    } else if !requirement.matches.isEmpty,
                              requirement.matches.allSatisfy({ $0.listeningState == .notListening }) {
                        items.append(OverviewAttentionItem(
                            id: itemID,
                            title: "\(projectCapabilityTitle(requirement.capability)) 当前未监听",
                            detail: "\(project.title) 的数据库要求已匹配安装，但没有 TCP Listener Binding",
                            systemImage: "cylinder.split.1x2.fill",
                            tint: .red,
                            priority: 2,
                            occurredAt: nil,
                            destination: .database(databaseDestinationID(requirement.capability))
                        ))
                    }
                }
            }
        }

        for projectID in activeProjectIDs.sorted() {
            guard let project = projects[projectID], let analysis = projectsModel.analyses[projectID] else { continue }
            for requirement in analysis.requirements where runtimeCapabilities.contains(requirement.capability) {
                let itemID = "project-requirement:\(projectID):\(requirement.capability)"
                guard !runtimeProblemIDs.contains(itemID),
                      let runtime = snapshot.runtimes.first(where: { $0.id == requirement.capability }),
                      runtime.hasPathVersionConflict else {
                    continue
                }
                let effectiveVersion = runtime.installations.first(where: \.isEffective)?.version ?? "未知"
                items.append(OverviewAttentionItem(
                    id: "path-conflict:\(projectID):\(requirement.capability)",
                    title: "\(projectCapabilityTitle(requirement.capability)) PATH 版本冲突",
                    detail: "\(project.title)：要求 \(requirement.expression) · 当前生效 \(effectiveVersion)",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    tint: .orange,
                    priority: 4,
                    occurredAt: nil,
                    destination: .runtime(requirement.capability)
                ))
            }
        }

        for run in runs {
            let exposed = Array(Set((run.bindings ?? []).filter { !$0.isLoopback })).sorted {
                $0.port == $1.port ? $0.address < $1.address : $0.port < $1.port
            }
            guard !exposed.isEmpty else { continue }
            items.append(OverviewAttentionItem(
                id: "exposed-run:\(run.id)",
                title: "\(run.project.title) 可能对局域网开放",
                detail: "监听地址：\(exposed.map(listenerBindingText).joined(separator: " · "))",
                systemImage: "antenna.radiowaves.left.and.right",
                tint: .orange,
                priority: 3,
                occurredAt: run.session.startedAt,
                destination: .localServices
            ))
        }

        if let free = snapshot.system.diskFreeBytes, free < 20 * 1_024 * 1_024 * 1_024 {
            items.append(OverviewAttentionItem(
                id: "low-disk-space",
                title: "系统卷可用空间不足",
                detail: "当前可用 \(byteCount(free))，低于 20 GB",
                systemImage: "internaldrive.fill",
                tint: .orange,
                priority: 5,
                occurredAt: snapshot.scannedAt,
                destination: .storage
            ))
        }

        return items.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            let lhsDate = lhs.occurredAt ?? .distantPast
            let rhsDate = rhs.occurredAt ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    private var currentOverviewAttentionItems: [OverviewAttentionItem] {
        guard let snapshot = model.snapshot else { return [] }
        return overviewAttentionItems(snapshot, runs: overviewRuns(snapshot), now: Date())
    }

    private func navigate(to destination: OverviewAttentionDestination) {
        isShowingNotifications = false
        switch destination {
        case let .run(configurationID):
            selectedRunConfigurationID = configurationID
            selectPage(.runs)
        case let .project(projectID, capability):
            selectedProjectID = projectID
            expandedProjectRequirementID = capability
            selectPage(.projects)
        case let .runtime(runtimeID):
            expandedRuntimeID = runtimeID
            selectSystemInformation(.runtimes)
        case let .database(databaseID):
            expandedDatabaseID = databaseID
            selectSystemInformation(.databases)
        case .localServices:
            selectedServiceTab = .local
            selectPage(.localServices)
        case .environmentRefresh:
            model.scan()
            runCoordinator.refreshProjects()
        case .dynamicRefresh:
            model.refreshDynamicStatus()
        case .storage:
            if let url = URL(string: "x-apple.systempreferences:com.apple.settings.Storage") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func selectSystemInformation(_ section: SystemInformationSection) {
        pendingSystemInformationSection = section
        selectPage(.systemInformation)
    }

    private func overviewRunColor(_ state: ProjectRunSessionState) -> Color {
        switch state {
        case .starting: .blue
        case .running: .green
        case .stopping: .orange
        case .stopFailed: .red
        case .restarting: .blue
        case .restartFailed: .red
        case .stopped: .secondary
        case .launchFailed: .red
        case let .exited(code): code == 0 ? .secondary : .red
        case .inactive: .secondary
        }
    }

    private func overviewProjectRequirementText(_ summary: ProjectRequirementsSummary?) -> String {
        switch summary {
        case .satisfied: "满足"
        case .unsatisfied: "未满足"
        case .undetermined: "待判断"
        case .declarationConflict: "声明冲突"
        case .undeclared: "未声明"
        case .unavailable: "不可用"
        case nil: "待刷新"
        }
    }

    private func projectRunStateTitle(_ state: ProjectRunSessionState) -> String {
        switch state {
        case .inactive: "未启动"
        case .starting: "启动中"
        case .running: "运行中"
        case .stopping: "停止中"
        case .stopFailed: "停止失败"
        case .restarting: "重启中"
        case .restartFailed: "重启失败"
        case .stopped: "已结束"
        case let .exited(code): code == 0 ? "已退出" : "异常退出"
        case .launchFailed: "启动失败"
        }
    }

    private func repositoryStateText(_ state: ProjectRepositoryState) -> String {
        switch state {
        case let .branch(branch): branch
        case let .detached(commit): "detached \(commit)"
        case .nonGit: "非 Git 项目"
        case .unknown: "Git 未知"
        }
    }

    private func overviewPortsText(_ run: OverviewRun) -> String {
        guard run.session.state == .running else { return "—" }
        guard let bindings = run.bindings else { return "未知" }
        let ports = Set(bindings.map(\.port)).sorted()
        return ports.isEmpty ? "无监听端口" : ports.map { ":\($0)" }.joined(separator: " · ")
    }

    private func overviewMemoryText(_ run: OverviewRun) -> String {
        guard run.session.state == .running else { return "—" }
        guard let bytes = run.session.physicalMemoryBytes else { return "未知" }
        return byteCount(bytes)
    }

    private func runDuration(from start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 60 { return "<1 分钟" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) 分钟" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours) 小时" : "\(hours) 小时 \(remainder) 分"
    }

    private func relativeUpdateText(_ date: Date, now: Date) -> String {
        let age = relativeAge(date, now: now)
        return age == "刚刚" ? "刚刚更新" : "\(age)更新"
    }

    private func relativeCompletionText(_ date: Date, now: Date) -> String {
        let age = relativeAge(date, now: now)
        return age == "刚刚" ? "刚刚完成" : "\(age)完成"
    }

    private func relativeAge(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "刚刚" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) 分钟前" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) 小时前" }
        return "\(hours / 24) 天前"
    }

    private func databaseDestinationID(_ capability: String) -> String {
        capability == "mysql-compatible" ? "mysql" : capability
    }

    private func topOverviewSection(_ snapshot: MachineSnapshot) -> some View {
        HStack(alignment: .top, spacing: 14) {
            systemSection(snapshot.system)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            summarySection(snapshot)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func overviewMetricsSection(_ snapshot: MachineSnapshot) -> some View {
        let discoveredCount = snapshot.runtimes.count { $0.state == .discovered }
        let databaseCount = snapshot.databaseInstallationOverviews.count { $0.discoveryState == .discovered }
        let localServiceCount = groupLocalServicesForDisplay(snapshot.localServices).count

        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4),
            spacing: 12
        ) {
            overviewMetricCard(
                discoveredCount.formatted(),
                label: "开发语言类别",
                systemImage: "square.grid.2x2",
                tint: .blue
            )
            overviewMetricCard(
                "\(databaseCount) / \(snapshot.databaseInstallationOverviews.count)",
                label: "数据库",
                systemImage: "cylinder",
                tint: .blue
            )
            overviewMetricCard(
                localServiceCount.formatted(),
                label: "本地服务",
                systemImage: "network",
                tint: .purple
            )
            overviewMetricCard(
                EnvironmentCard.allCases.count.formatted(),
                label: "环境配置项",
                systemImage: "slider.horizontal.3",
                tint: .green
            )
        }
    }

    private func overviewMetricCard(
        _ value: String,
        label: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 46, height: 46)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title2.bold())
                    .monospacedDigit()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(AppTheme.cardSurface)
                .overlay {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(Color.primary.opacity(0.10))
                }
        }
        .accessibilityElement(children: .combine)
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
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppTheme.cardSubtle)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.primary.opacity(0.08))
                }
        }
    }

    private func summarySection(_ snapshot: MachineSnapshot) -> some View {
        let pathConflictCount = snapshot.runtimes.count { $0.hasPathVersionConflict }
        let unavailableRuntimeCount = snapshot.runtimes.count { $0.state == .unavailable }
        let databaseNotListeningCount = snapshot.databaseInstallationOverviews.count {
            $0.discoveryState == .discovered && $0.listeningState != .listening
        }
        let exposedPortCount = groupLocalServicesForDisplay(snapshot.localServices).reduce(0) {
            $0 + $1.bindings.count { !$0.isLoopback }
        }
        let needsAttention = pathConflictCount + unavailableRuntimeCount + databaseNotListeningCount + exposedPortCount > 0

        return topOverviewCard("环境状态", systemImage: "checkmark.shield") {
            VStack(spacing: 10) {
                summaryMetric(pathConflictCount, label: "PATH 冲突", systemImage: "exclamationmark.triangle.fill", tint: .orange)
                summaryMetric(unavailableRuntimeCount, label: "开发语言未发现", systemImage: "questionmark.circle.fill", tint: .secondary)
                summaryMetric(databaseNotListeningCount, label: "数据库未监听", systemImage: "cylinder", tint: .blue)
                summaryMetric(exposedPortCount, label: "异常监听端口", systemImage: "antenna.radiowaves.left.and.right", tint: .red)

                HStack(spacing: 8) {
                    Spacer()
                    Text("环境整体状态：")
                        .foregroundStyle(.secondary)
                    Text(needsAttention ? "需关注" : "正常")
                        .fontWeight(.semibold)
                        .foregroundStyle(needsAttention ? .orange : .green)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background((needsAttention ? Color.orange : Color.green).opacity(0.10), in: Capsule())
                    Spacer()
                }
                .font(.callout)
                .padding(.vertical, 10)
                .background(AppTheme.innerCard, in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.primary.opacity(0.10))
                }
            }
        }
    }

    private func summaryMetric(_ value: Int, label: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.10))
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(tint)
            }
            .frame(width: 36, height: 36)
            .accessibilityHidden(true)

            Text(label)
                .font(.callout)
            Spacer(minLength: 8)
            Text(value.formatted())
                .font(.title2.bold())
                .monospacedDigit()
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 54)
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(AppTheme.innerCard)
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
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 28, height: 28)
                Text("开发语言")
                    .font(.title3.bold())
            }

            if let expandedRuntimeID,
               let expandedIndex = runtimes.firstIndex(where: { $0.id == expandedRuntimeID }) {
                runtimeCard(runtimes[expandedIndex])
                runtimeGrid(runtimes.filter { $0.id != expandedRuntimeID })
            } else {
                runtimeGrid(runtimes)
            }
        }
    }

    private func runtimeGrid(_ runtimes: [RuntimeSnapshot]) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: 2),
            alignment: .leading,
            spacing: 14
        ) {
            ForEach(runtimes) { runtime in
                runtimeCard(runtime)
            }
        }
    }

    private func databaseInstallationsSection(_ overviews: [DatabaseInstallationOverview]) -> some View {
        let shouldCollapseExpanded = expandedDatabaseID.map { id in
            overviews.first(where: { $0.id == id })?.installations.isEmpty ?? true
        } ?? false

        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 10) {
                    Image(systemName: "cylinder.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 28, height: 28)
                    Text("数据库")
                        .font(.title3.bold())
                }
                Spacer()
                Text(model.dynamicStatusRefreshedAt.map { "最近刷新：\(formatted($0))" } ?? "最近刷新：尚未刷新")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            homebrewServiceFeedback

            if let expandedDatabaseID,
               let expanded = overviews.first(where: { $0.id == expandedDatabaseID }) {
                databaseCard(expanded)
                databaseGrid(overviews.filter { $0.id != expandedDatabaseID })
            } else {
                databaseGrid(overviews)
            }
        }
        .onChange(of: shouldCollapseExpanded) { _, shouldCollapse in
            if shouldCollapse {
                expandedDatabaseID = nil
                fullyShownDatabaseID = nil
            }
        }
        .onAppear(perform: model.refreshHomebrewServices)
    }

    private func databaseGrid(_ overviews: [DatabaseInstallationOverview]) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: 2),
            alignment: .leading,
            spacing: 14
        ) {
            ForEach(overviews) { database in
                databaseCard(database)
            }
        }
    }

    private func databaseCard(_ database: DatabaseInstallationOverview) -> some View {
        let isExpanded = expandedDatabaseID == database.id
        let highlightsStatus = database.installations.contains { $0.error != nil }
            || database.discoveryState == .unknown
            || database.listeningState == .unknown
        let showsAllInstallations = fullyShownDatabaseID == database.id
        let installations = showsAllInstallations
            ? database.installations
            : Array(database.installations.prefix(3))

        return Group {
            if isExpanded {
                VStack(alignment: .leading, spacing: 16) {
                    Button {
                        toggleCard(database.id, expandedID: $expandedDatabaseID, fullyShownID: $fullyShownDatabaseID)
                    } label: {
                        databaseExpandedSummary(database)
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue("已展开")

                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(installations) { installation in
                            databaseInstallationRow(installation)
                        }
                        if database.installations.count > 3 {
                            Button {
                                toggleInstallationLimit(database.id, fullyShownID: $fullyShownDatabaseID)
                            } label: {
                                Label(
                                    showsAllInstallations
                                        ? "收起至 3 个安装路径"
                                        : "展开其余 \(database.installations.count - 3) 个安装路径",
                                    systemImage: showsAllInstallations ? "chevron.up" : "chevron.down"
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(AppTheme.innerCard, in: RoundedRectangle(cornerRadius: 10))
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
            } else if database.installations.isEmpty {
                databaseSummary(database)
            } else {
                Button {
                    toggleCard(database.id, expandedID: $expandedDatabaseID, fullyShownID: $fullyShownDatabaseID)
                } label: {
                    databaseSummary(database)
                }
                .buttonStyle(.plain)
                .accessibilityValue("已折叠")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.cardRaised)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(highlightsStatus ? Color.orange.opacity(0.55) : Color.primary.opacity(0.09))
                }
        }
    }

    private func databaseExpandedSummary(_ database: DatabaseInstallationOverview) -> some View {
        let discovery = databaseDiscoveryStyle(database.discoveryState)
        let listening = databaseListeningStyle(database.listeningState)

        return HStack(alignment: .center, spacing: 18) {
            databaseLogo(database, size: 64, padding: 11, usesNeutralBackground: true)

            VStack(alignment: .leading, spacing: 5) {
                Text(database.name)
                    .font(.title3.bold())
                Text(databaseVersion(database))
                    .font(.title2.bold())
                    .monospacedDigit()
                    .foregroundStyle(database.installations.contains { $0.error != nil } ? .orange : .primary)
                Label("\(database.installations.count) 个安装", systemImage: "square.stack.3d.up.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label(listening.title, systemImage: listening.symbol)
                    .font(.caption.weight(.semibold))
                .foregroundStyle(listening.color)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.045), in: Capsule())
            }
            .frame(width: 150, alignment: .leading)

            HStack(spacing: 10) {
                environmentMetric(
                    title: "发现状态",
                    value: discovery.title,
                    systemImage: discovery.symbol,
                    tint: discovery.color,
                    usesNeutralBackground: true
                )
                environmentMetric(
                    title: "监听状态",
                    value: listening.title,
                    systemImage: listening.symbol,
                    tint: listening.color,
                    usesNeutralBackground: true
                )
                environmentMetric(
                    title: "正在监听",
                    value: "\(database.listeningCount)",
                    systemImage: "network",
                    tint: database.listeningCount > 0 ? .green : .secondary,
                    usesNeutralBackground: true
                )
            }
            .frame(maxWidth: .infinity)
        }
        .contentShape(Rectangle())
    }

    private func databaseSummary(_ database: DatabaseInstallationOverview) -> some View {
        let tint = databaseTint(database)
        let discovery = databaseDiscoveryStyle(database.discoveryState)
        let listening = databaseListeningStyle(database.listeningState)
        let statusColor = database.installations.isEmpty ? discovery.color : tint
        let statusSymbol = database.installations.isEmpty ? "questionmark" : listening.symbol

        return environmentCardSummary(
            title: database.name,
            primaryValue: databaseVersion(database),
            subtitle: database.installations.isEmpty
                ? "未检测到 Database Installation"
                : "\(database.installations.count) 个安装 · \(database.listeningCount) 个正在监听",
            status: database.installations.isEmpty ? discovery.title : listening.title,
            statusImage: statusSymbol,
            statusColor: statusColor,
            showsDisclosure: !database.installations.isEmpty
        ) {
            databaseLogo(database, size: 50, padding: 8)
        }
    }

    private func databaseLogo(
        _ database: DatabaseInstallationOverview,
        size: CGFloat,
        padding: CGFloat,
        usesNeutralBackground: Bool = false
    ) -> some View {
        databaseLogo(database.id, size: size, padding: padding, usesNeutralBackground: usesNeutralBackground)
    }

    private func databaseLogo(
        _ id: String,
        size: CGFloat,
        padding: CGFloat,
        usesNeutralBackground: Bool = false
    ) -> some View {
        let appearance: (asset: String, color: Color) = switch id {
        case "mysql": ("ServiceMySQLLogo", Color(red: 0.27, green: 0.47, blue: 0.63))
        case "mariadb": ("ServiceMariaDBLogo", Color(red: 0, green: 0.36, blue: 0.43))
        case "mongodb": ("ServiceMongoDBLogo", Color(red: 0.29, green: 0.66, blue: 0.34))
        case "redis": ("ServiceRedisLogo", Color(red: 0.82, green: 0.16, blue: 0.15))
        default: ("ServicePostgreSQLLogo", Color(red: 0.20, green: 0.45, blue: 0.64))
        }
        return ZStack {
            RoundedRectangle(cornerRadius: size > 50 ? 14 : 11, style: .continuous)
                .fill(usesNeutralBackground ? Color.primary.opacity(0.045) : appearance.color.opacity(0.10))
            Image(appearance.asset)
                .resizable()
                .scaledToFit()
                .padding(padding)
        }
        .frame(width: size, height: size)
        .overlay {
            RoundedRectangle(cornerRadius: size > 50 ? 14 : 11, style: .continuous)
                .stroke(usesNeutralBackground ? Color.primary.opacity(0.10) : appearance.color.opacity(0.16))
        }
        .accessibilityHidden(true)
    }

    private func databaseInstallationRow(_ installation: DatabaseInstallation) -> some View {
        let listening = databaseListeningStyle(installation.listeningState)
        let tint: Color = installation.error == nil
            ? listening.color
            : .orange
        let homebrewExecutable = model.snapshot?.homebrew.available == true
            ? model.snapshot?.homebrew.executable
            : nil
        let service = homebrewExecutable == nil ? nil : installation.homebrewFormula.flatMap { formula in
            model.homebrewServiceList?.services.first { $0.formula == formula }
        }
        let homebrewServiceStateUnknown = homebrewExecutable == nil
            || model.homebrewServiceList == nil
            || model.homebrewServiceList?.error != nil

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: installation.error == nil
                    ? listening.symbol
                    : "exclamationmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 24)

                Text(installation.version ?? "读取失败")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .textSelection(.enabled)
                    .frame(width: 90, alignment: .leading)

                HStack(spacing: 5) {
                    ForEach(installation.sources, id: \.self) { source in
                        Text(source.displayName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                    }
                    Text("监听：\(listening.title)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                }

                Spacer(minLength: 0)

                if installation.error != nil {
                    helpIcon("该 Database Installation 已被发现，但版本读取失败或可执行文件不可用；可独立确定的 TCP 监听状态不受影响。")
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                copyablePath(installation.executable)
                if let actual = installation.actualExecutable {
                    copyablePath(actual, prefix: "实际路径")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 38)

            if let formula = installation.homebrewFormula {
                Divider()
                HStack(spacing: 10) {
                    if let service {
                        Label(
                            "Homebrew：\(homebrewServiceDetail(service)) · \(formula)",
                            systemImage: "shippingbox.fill"
                        )
                        .foregroundStyle(homebrewServiceColor(service.status))

                        Spacer()

                        if model.homebrewServiceActionFormula == service.formula {
                            ProgressView("正在处理")
                                .controlSize(.small)
                                .accessibilityLabel("正在为 \(service.formula) 执行 Homebrew Service 操作")
                        } else {
                            ForEach(service.allowedActions, id: \.self) { action in
                                homebrewServiceActionButton(
                                    action,
                                    service: service,
                                    executable: homebrewExecutable ?? ""
                                )
                            }
                            .disabled(model.isBusy || model.homebrewServiceList?.isStale == true)
                        }
                    } else {
                        Label(
                            homebrewServiceStateUnknown
                                ? "\(formula) · Homebrew Service 状态未知"
                                : "\(formula) · 未提供 Homebrew Service",
                            systemImage: "shippingbox"
                        )
                        .foregroundStyle(
                            homebrewServiceStateUnknown ? .orange : .secondary
                        )
                    }
                }
                .font(.caption.weight(.semibold))
                .padding(.leading, 38)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(AppTheme.cardSurface, in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(installation.error == nil ? Color.primary.opacity(0.10) : Color.orange.opacity(0.45))
        }
    }

    private func databaseVersion(_ database: DatabaseInstallationOverview) -> String {
        database.installations.first?.version
            ?? database.installations.first?.error
            ?? databaseDiscoveryStyle(database.discoveryState).title
    }

    private func databaseDiscoveryStyle(_ state: DatabaseDiscoveryState) -> (title: String, symbol: String, color: Color) {
        switch state {
        case .discovered: ("已发现", "checkmark.circle.fill", .green)
        case .notFound: ("未发现", "circle.fill", .secondary)
        case .unknown: ("发现状态未知", "exclamationmark.circle.fill", .orange)
        }
    }

    private func databaseListeningStyle(_ state: DatabaseListeningState) -> (title: String, symbol: String, color: Color) {
        switch state {
        case .listening: ("正在监听", "checkmark.circle.fill", .green)
        case .notListening: ("未监听", "circle.fill", .secondary)
        case .unknown: ("监听状态未知", "exclamationmark.circle.fill", .orange)
        }
    }

    private func databaseTint(_ database: DatabaseInstallationOverview) -> Color {
        if database.installations.contains(where: { $0.error != nil }) { return .orange }
        if database.discoveryState == .unknown || database.listeningState == .unknown { return .orange }
        return database.listeningState == .listening ? .green : .secondary
    }

    private func toggleCard(_ id: String, expandedID: Binding<String?>, fullyShownID: Binding<String?>) {
        let nextID = expandedID.wrappedValue == id ? nil : id
        if reduceMotion {
            expandedID.wrappedValue = nextID
            fullyShownID.wrappedValue = nil
        } else {
            withAnimation(.smooth(duration: 0.32)) {
                expandedID.wrappedValue = nextID
                fullyShownID.wrappedValue = nil
            }
        }
    }

    private func toggleInstallationLimit(_ id: String, fullyShownID: Binding<String?>) {
        let nextID = fullyShownID.wrappedValue == id ? nil : id
        if reduceMotion {
            fullyShownID.wrappedValue = nextID
        } else {
            withAnimation(.snappy(duration: 0.25, extraBounce: 0.02)) {
                fullyShownID.wrappedValue = nextID
            }
        }
    }

    private func localServiceMetricCard(
        _ value: Int,
        title: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 46, height: 46)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(value.formatted())
                    .font(.title2.bold())
                    .monospacedDigit()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.cardSurface)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.primary.opacity(0.10))
                }
        }
        .accessibilityElement(children: .combine)
    }

    private func localServicesSection(_ snapshot: MachineSnapshot) -> some View {
        let groups = groupLocalServicesForDisplay(snapshot.localServices)
        let portCount = groups.reduce(0) { $0 + Set($1.bindings.map(\.port)).count }
        let exposedPortCount = groups.reduce(0) { $0 + $1.bindings.count { !$0.isLoopback } }

        return VStack(alignment: .leading, spacing: 18) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4),
                spacing: 12
            ) {
                localServiceMetricCard(
                    groups.count,
                    title: "服务类别",
                    systemImage: "globe",
                    tint: .blue
                )
                localServiceMetricCard(
                    groups.count,
                    title: "正在运行",
                    systemImage: "waveform.path.ecg",
                    tint: .green
                )
                localServiceMetricCard(
                    portCount,
                    title: "监听端口",
                    systemImage: "cable.connector",
                    tint: .blue
                )
                localServiceMetricCard(
                    exposedPortCount,
                    title: "异常端口",
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .orange
                )
            }

            serviceTabSwitcher(
                localCount: groups.count,
                homebrewCount: model.homebrewServiceList?.services.count ?? 0
            )

            switch selectedServiceTab {
            case .local:
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
                    VStack(spacing: 10) {
                        ForEach(groups) { group in
                            localServiceRow(group)
                        }
                    }
                }
            case .homebrew:
                homebrewServicesSection(snapshot)
            }
        }
        .onAppear(perform: model.refreshHomebrewServices)
    }

    private func serviceTabSwitcher(localCount: Int, homebrewCount: Int) -> some View {
        HStack(spacing: 4) {
            serviceTabButton(
                .local,
                title: "本地服务",
                systemImage: "server.rack",
                count: localCount
            )
            serviceTabButton(
                .homebrew,
                title: "Homebrew 服务",
                systemImage: "shippingbox",
                count: homebrewCount
            )
        }
        .padding(4)
        .background(AppTheme.cardSubtle, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.primary.opacity(0.10))
        }
    }

    private func serviceTabButton(
        _ tab: ServiceTab,
        title: String,
        systemImage: String,
        count: Int
    ) -> some View {
        let isSelected = selectedServiceTab == tab
        return Button {
            selectedServiceTab = tab
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                Text(title)
                    .fontWeight(.semibold)
                Text(count.formatted())
                    .font(.caption.bold())
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(isSelected ? Color.white : Color.secondary.opacity(0.12), in: Capsule())
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(isSelected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)，\(count) 项")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func homebrewServicesSection(_ snapshot: MachineSnapshot) -> some View {
        Button(action: model.refreshHomebrewServices) {
            if model.isRefreshingHomebrewServices {
                ProgressView().controlSize(.small)
            } else {
                Label("刷新", systemImage: "arrow.clockwise")
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityLabel(model.isRefreshingHomebrewServices ? "正在刷新 Homebrew Service" : "刷新 Homebrew Service")
        .disabled(model.isBusy || !snapshot.homebrew.available)

        homebrewServiceFeedback

        if !snapshot.homebrew.available || snapshot.homebrew.executable == nil {
            ContentUnavailableView("Homebrew 不可用", systemImage: "shippingbox")
                .frame(maxWidth: .infinity, minHeight: 110)
        } else if model.homebrewServiceList == nil && model.isRefreshingHomebrewServices {
            ProgressView("正在读取 Homebrew Service…")
                .frame(maxWidth: .infinity, minHeight: 110)
        } else if model.homebrewServiceList == nil {
            ContentUnavailableView("尚未读取 Homebrew Service", systemImage: "shippingbox")
                .frame(maxWidth: .infinity, minHeight: 110)
        } else if let list = model.homebrewServiceList, list.services.isEmpty {
            ContentUnavailableView(
                list.error == nil ? "没有可管理的 Homebrew Service" : "无法读取 Homebrew Service",
                systemImage: list.error == nil ? "shippingbox" : "exclamationmark.triangle"
            )
            .frame(maxWidth: .infinity, minHeight: 110)
        } else if let services = model.homebrewServiceList?.services {
            VStack(spacing: 10) {
                ForEach(services) { service in
                    homebrewServiceRow(service, executable: snapshot.homebrew.executable ?? "")
                }
            }
        }
    }

    @ViewBuilder
    private var homebrewServiceFeedback: some View {
        if let result = model.homebrewServiceActionResult {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: result.kind == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.message).fontWeight(.semibold)
                    if let output = result.output, result.kind != .success {
                        Text(output).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
            .foregroundStyle(result.kind == .success ? Color.green : Color.orange)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((result.kind == .success ? Color.green : Color.orange).opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }

        if let list = model.homebrewServiceList, let error = list.error {
            Label(list.isStale ? "\(error)；继续显示上次成功结果" : error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private func homebrewServiceRow(_ service: HomebrewService, executable: String) -> some View {
        let isRunning = model.homebrewServiceActionFormula == service.formula
        let descriptor = homebrewServiceDescriptor(for: service.formula)
        let statusTint = homebrewServiceColor(service.status)
        return HStack(alignment: .center, spacing: 16) {
            serviceDescriptorIcon(descriptor)
                .frame(width: 54, height: 54)
                .shadow(color: .black.opacity(0.14), radius: 7, y: 4)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusTint)
                        .frame(width: 9, height: 9)
                        .shadow(color: statusTint.opacity(0.65), radius: 4)
                        .accessibilityHidden(true)
                    Text(service.formula)
                        .font(.title3.bold())
                }
                Text("Homebrew 管理的当前用户后台服务")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(homebrewServiceDetail(service))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()
            if isRunning {
                ProgressView("正在处理")
                    .controlSize(.small)
                    .accessibilityLabel("正在\(service.formula)执行 Homebrew Service 操作")
            } else {
                ForEach(service.allowedActions, id: \.self) { action in
                    homebrewServiceActionButton(action, service: service, executable: executable)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(AppTheme.cardSubtle)
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(Color.primary.opacity(0.10))
                }
        }
        .disabled(model.isBusy || model.homebrewServiceList?.isStale == true)
    }

    private func homebrewServiceDetail(_ service: HomebrewService) -> String {
        if service.status == .error, let exitCode = service.exitCode {
            return "\(homebrewServiceStatusTitle(service.status)) · 退出码 \(exitCode)"
        }
        return homebrewServiceStatusTitle(service.status)
    }

    @ViewBuilder
    private func homebrewServiceActionButton(
        _ action: HomebrewServiceAction,
        service: HomebrewService,
        executable: String
    ) -> some View {
        let button = Button(action.title) {
            pendingHomebrewServiceAction = PendingHomebrewServiceAction(
                service: service,
                action: action,
                executable: executable
            )
        }
        .accessibilityLabel(Text(action.title + " Homebrew Service " + service.formula))

        if action == .start {
            button.buttonStyle(.borderedProminent)
        } else if action == .stop {
            button.buttonStyle(.bordered).tint(.red)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private func homebrewServiceStatusTitle(_ status: HomebrewServiceStatus) -> String {
        switch status {
        case .none: "未注册"
        case .stopped: "已停止"
        case .started: "已启动"
        case .scheduled: "已计划"
        case .error: "异常"
        case .unknown: "状态未知"
        }
    }

    private func homebrewServiceColor(_ status: HomebrewServiceStatus) -> Color {
        switch status {
        case .started, .scheduled: .green
        case .error, .unknown: .orange
        case .none, .stopped: .secondary
        }
    }

    private func localServiceRow(_ group: LocalServiceDisplayGroup) -> some View {
        let descriptor = localServiceDescriptor(for: group.processName)
        let applicationIcon: NSImage? = switch group.attribution?.kind {
        case .application:
            group.attribution.map { NSWorkspace.shared.icon(forFile: $0.path) }
        case .project:
            nil
        case nil:
            runningApplicationIcon(for: group.pids)
        }
        let explanation = switch group.attribution?.kind {
        case .project:
            "\(descriptor.displayName) 项目服务 · \(group.attribution.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "")"
        case .application:
            "\(descriptor.displayName) 运行时服务"
        case nil:
            descriptor.explanation
        }
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
                } else {
                    serviceDescriptorIcon(descriptor)
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
                    Text(group.displayName)
                        .font(.title3.bold())
                }
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(processText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2),
                alignment: .trailing,
                spacing: 7
            ) {
                ForEach(group.bindings, id: \.self) { binding in
                    listenerBindingBadge(binding)
                }
            }
            .frame(minWidth: 190, maxWidth: 480, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(AppTheme.cardSubtle)
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(Color.primary.opacity(0.10))
                }
        }
    }

    @ViewBuilder
    private func serviceDescriptorIcon(_ descriptor: ServiceDisplayDescriptor) -> some View {
        if let assetName = descriptor.assetName {
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

    private func runningApplicationIcon(for pids: [Int32]) -> NSImage? {
        for pid in pids {
            if let icon = NSRunningApplication(processIdentifier: pid)?.icon { return icon }
        }
        return nil
    }

    private func listenerBindingBadge(_ binding: ListenerBinding) -> some View {
        let tint = binding.family == .ipv4 ? Color.blue : Color.purple

        return HStack(spacing: 6) {
            Text(binding.family.rawValue)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
                .fixedSize(horizontal: true, vertical: false)
            Text(listenerBindingText(binding))
                .font(.caption.monospaced())
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .layoutPriority(1)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            if !binding.isLoopback {
                ListenerExposureIcon()
            }
        }
        .padding(.horizontal, 7)
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
        let highlightsStatus = runtime.hasPathVersionConflict || runtime.state == .failed
        let showsAllInstallations = fullyShownRuntimeID == runtime.id
        let visibleInstallations = showsAllInstallations
            ? runtime.installations
            : Array(runtime.installations.prefix(3))

        return Group {
            if isExpanded {
                VStack(alignment: .leading, spacing: 16) {
                    Button {
                        toggleCard(runtime.id, expandedID: $expandedRuntimeID, fullyShownID: $fullyShownRuntimeID)
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
                                toggleInstallationLimit(runtime.id, fullyShownID: $fullyShownRuntimeID)
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
                            toggleCard(runtime.id, expandedID: $expandedRuntimeID, fullyShownID: $fullyShownRuntimeID)
                        } label: {
                            runtimeSummary(runtime)
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue("已折叠")
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.cardRaised)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(
                            highlightsStatus
                                ? status.color.opacity(0.55)
                                : Color.primary.opacity(0.09)
                        )
                }
        }
    }

    private func runtimeExpandedSummary(_ runtime: RuntimeSnapshot) -> some View {
        let brand = runtimeBrand(runtime)
        let status = runtimeCardStatus(runtime)
        let pathVersionCount = Set(runtime.installations.filter(\.isInPath).compactMap(\.version)).count

        return HStack(alignment: .center, spacing: 18) {
            runtimeLogo(brand, size: 64, padding: 11, cornerRadius: 14)

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
                .background(Color.primary.opacity(0.045), in: Capsule())
            }
            .frame(width: 150, alignment: .leading)

            HStack(spacing: 10) {
                environmentMetric(
                    title: "当前生效",
                    value: effectiveVersion(for: runtime),
                    systemImage: "checkmark.circle",
                    tint: runtime.state == .failed ? .orange : .green,
                    usesNeutralBackground: true
                )
                environmentMetric(
                    title: "PATH 版本",
                    value: "\(pathVersionCount)",
                    systemImage: "exclamationmark.circle",
                    tint: runtime.hasPathVersionConflict ? .orange : .secondary,
                    usesNeutralBackground: true,
                    emphasizesBorder: runtime.hasPathVersionConflict
                )
                environmentMetric(
                    title: "已发现",
                    value: "\(runtime.installations.count)",
                    systemImage: "square.stack.3d.up.fill",
                    tint: .blue,
                    usesNeutralBackground: true
                )
            }
            .frame(maxWidth: .infinity)
        }
        .contentShape(Rectangle())
    }

    private func environmentMetric(
        title: String,
        value: String,
        systemImage: String,
        tint: Color,
        usesNeutralBackground: Bool = false,
        emphasizesBorder: Bool = false
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
        .background(
            usesNeutralBackground ? Color.primary.opacity(0.025) : tint.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 11)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(
                    usesNeutralBackground
                        ? (emphasizesBorder ? tint.opacity(0.45) : Color.primary.opacity(0.10))
                        : tint.opacity(0.25)
                )
        }
    }

    private func runtimeSummary(_ runtime: RuntimeSnapshot) -> some View {
        let brand = runtimeBrand(runtime)
        let status = runtimeCardStatus(runtime)

        return environmentCardSummary(
            title: runtime.name,
            primaryValue: effectiveVersion(for: runtime),
            subtitle: runtime.installations.isEmpty
                ? "未检测到安装版本"
                : "\(runtime.installations.count) 个安装版本",
            status: status.title,
            statusImage: status.pillSymbol,
            statusColor: status.color,
            showsDisclosure: !runtime.installations.isEmpty
        ) {
            runtimeLogo(brand, size: 50)
        }
    }

    private func runtimeCardStatus(_ runtime: RuntimeSnapshot) -> (
        title: String,
        pillSymbol: String,
        color: Color,
        explanation: String?
    ) {
        if runtime.hasPathVersionConflict {
            return (
                "PATH 版本冲突",
                "exclamationmark.triangle.fill",
                .orange,
                "当前 PATH 中存在该开发语言的多个不同版本。终端默认使用 PATH 顺序最靠前的版本，其他工具或项目可能解析到不同版本。"
            )
        }
        if runtime.state == .failed {
            return (
                "读取失败",
                "exclamationmark.circle.fill",
                .orange,
                "已找到开发语言，但无法读取可用版本。常见原因包括命令超时、文件不可执行或版本输出无法识别。"
            )
        }
        if runtime.state == .discovered {
            return ("已安装", "checkmark.circle.fill", .green, nil)
        }
        return ("未发现", "circle.fill", .secondary, nil)
    }

    private func runtimeBrand(_ runtime: RuntimeSnapshot) -> (assetName: String, color: Color) {
        runtimeBrand(runtime.id) ?? ("RuntimeNodeLogo", .secondary)
    }

    private func runtimeBrand(_ id: String) -> (assetName: String, color: Color)? {
        switch id {
        case "node": ("RuntimeNodeLogo", Color(red: 0.37, green: 0.63, blue: 0.31))
        case "python": ("RuntimePythonLogo", Color(red: 0.22, green: 0.46, blue: 0.67))
        case "go": ("RuntimeGoLogo", Color(red: 0, green: 0.68, blue: 0.85))
        case "java": ("RuntimeJavaLogo", Color(red: 0.26, green: 0.45, blue: 0.57))
        case "rust": ("RuntimeRustLogo", .primary)
        case "ruby": ("RuntimeRubyLogo", Color(red: 0.80, green: 0.20, blue: 0.18))
        case "lua": ("RuntimeLuaLogo", Color(red: 0.17, green: 0.18, blue: 0.45))
        default: nil
        }
    }

    private func runtimeLogo(
        _ brand: (assetName: String, color: Color),
        size: CGFloat = 48,
        padding: CGFloat = 8,
        cornerRadius: CGFloat = 11
    ) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(brand.color.opacity(0.10))
            Image(brand.assetName)
                .resizable()
                .scaledToFit()
                .foregroundStyle(brand.color)
                .padding(padding)
        }
        .frame(width: size, height: size)
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(brand.color.opacity(0.12))
        }
        .accessibilityHidden(true)
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
        let state = installation.isEffective
            ? "当前生效"
            : (installation.isInPath ? "PATH" : "未进入 PATH")

        return HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24)

            Text(installation.version ?? "读取失败")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .frame(width: 90, alignment: .leading)

            HStack(spacing: 5) {
                ForEach(installation.sources.filter { $0 != .path }, id: \.self) { source in
                    Text(source.displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                }

                Text(state)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(installation.isEffective ? .green : .secondary)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            }

            VStack(alignment: .leading, spacing: 5) {
                copyablePath(installation.executable)
                if let actual = installation.actualExecutable {
                    copyablePath(actual, prefix: "实际路径")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if installation.state == .failed {
                helpIcon("该安装已被发现，但版本读取失败或可执行文件不可用；它不会阻止其他安装版本继续扫描。")
            } else if isConflictingPath {
                Text("可能冲突")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(
                    installation.state == .failed || isConflictingPath
                        ? Color.orange.opacity(0.45)
                        : Color.primary.opacity(0.10)
                )
        }
    }

    private func helpIcon(_ explanation: String) -> some View {
        RuntimeHelpIcon(explanation: explanation)
            .frame(width: 16, height: 16)
    }

    private func environmentSection(_ snapshot: MachineSnapshot) -> some View {
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 28, height: 28)
                Text("环境配置")
                    .font(.title3.bold())
            }

            if expandedEnvironmentCard == .packageManagers {
                packageManagerCard(snapshot.homebrew, managers: snapshot.packageManagers)
                environmentCardGrid(snapshot, excluding: .packageManagers)
            } else if expandedEnvironmentCard == .git {
                gitCard(
                    snapshot.gitCLI,
                    lfs: snapshot.gitLFS,
                    configuration: snapshot.userGitConfiguration,
                    signing: snapshot.gitSigningConfiguration,
                    credentialHelpers: snapshot.gitCredentialHelpers,
                    github: snapshot.githubAuthenticationConfiguration
                )
                environmentCardGrid(snapshot, excluding: .git)
            } else if expandedEnvironmentCard == .terminal {
                terminalCard(snapshot.terminalApplications)
                environmentCardGrid(snapshot, excluding: .terminal)
            } else if expandedEnvironmentCard == .shell {
                shellCard(snapshot.shellInstallations)
                environmentCardGrid(snapshot, excluding: .shell)
            } else {
                environmentCardGrid(snapshot)
            }
        }
        .onPreferenceChange(EnvironmentCardUpperContentHeightKey.self) {
            environmentCardUpperContentHeight = $0
        }
        .onChange(of: snapshot.terminalApplications.isEmpty) { _, isEmpty in
            if isEmpty, expandedEnvironmentCard == .terminal { expandedEnvironmentCard = nil }
        }
        .onChange(of: snapshot.shellInstallations.isEmpty) { _, isEmpty in
            if isEmpty, expandedEnvironmentCard == .shell { expandedEnvironmentCard = nil }
        }
    }

    private func environmentCardGrid(
        _ snapshot: MachineSnapshot,
        excluding excludedCard: EnvironmentCard? = nil
    ) -> some View {
        VStack(spacing: 14) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: 2),
                alignment: .leading,
                spacing: 14
            ) {
                if excludedCard != .packageManagers {
                    packageManagerCard(snapshot.homebrew, managers: snapshot.packageManagers)
                }
                if excludedCard != .git {
                    gitCard(
                        snapshot.gitCLI,
                        lfs: snapshot.gitLFS,
                        configuration: snapshot.userGitConfiguration,
                        signing: snapshot.gitSigningConfiguration,
                        credentialHelpers: snapshot.gitCredentialHelpers,
                        github: snapshot.githubAuthenticationConfiguration
                    )
                }
                if excludedCard != .terminal {
                    terminalCard(snapshot.terminalApplications)
                }
                if excludedCard != .shell {
                    shellCard(snapshot.shellInstallations)
                }
            }

        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func gitCard(
        _ git: GitCLISnapshot,
        lfs: GitLFSSnapshot?,
        configuration: UserGitConfigurationSnapshot?,
        signing: GitSigningConfigurationSnapshot?,
        credentialHelpers: [String]?,
        github: GitHubAuthenticationConfigurationSnapshot
    ) -> some View {
        let isExpanded = expandedEnvironmentCard == .git
        let appearance: (color: Color, status: String, badge: String, pill: String) = switch git.state {
        case .available: (.green, "可用", "checkmark", "checkmark.circle.fill")
        case .failed: (.orange, "读取失败", "exclamationmark", "exclamationmark.circle.fill")
        case .unavailable: (.secondary, "未发现", "questionmark", "circle.fill")
        }

        return VStack(alignment: .leading, spacing: 12) {
            Button {
                toggleEnvironmentCard(.git)
            } label: {
                Group {
                    if isExpanded {
                        gitExpandedSummary(
                            git,
                            lfs: lfs,
                            configuration: configuration,
                            github: github,
                            status: appearance.status,
                            statusColor: appearance.color,
                            statusImage: appearance.pill
                        )
                    } else {
                        HStack(alignment: .center, spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(Color.orange.opacity(0.09))
                                Image("GitLogo")
                                    .resizable()
                                    .scaledToFit()
                                    .foregroundStyle(.orange)
                                    .padding(10)
                            }
                            .frame(width: 50, height: 50)
                            .overlay {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .stroke(Color.primary.opacity(0.07))
                            }
                            .accessibilityHidden(true)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Git")
                                    .font(.headline)
                                Text(git.version ?? appearance.status)
                                    .font(.title3.bold())
                                    .monospacedDigit()
                                Text("当前生效 CLI")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 8)

                            Label(appearance.status, systemImage: appearance.pill)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(appearance.color)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(appearance.color.opacity(0.10), in: Capsule())

                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "已展开" : "已折叠")

            if git.state != .available {
                Divider()
                if let executable = git.executable {
                    copyablePath(executable)
                } else {
                    Text("当前 PATH 未发现 Git")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if isExpanded {
                gitConfigurationDetails(
                    configuration,
                    lfs: lfs,
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
                .fill(AppTheme.cardRaised)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.primary.opacity(0.09))
                }
        }
    }

    private func gitExpandedSummary(
        _ git: GitCLISnapshot,
        lfs: GitLFSSnapshot?,
        configuration: UserGitConfigurationSnapshot?,
        github: GitHubAuthenticationConfigurationSnapshot,
        status: String,
        statusColor: Color,
        statusImage: String
    ) -> some View {
        let lfsValue = lfs?.version ?? (lfs?.state == .failed ? "读取失败" : "未发现")
        let lfsColor: Color = lfs?.state == .failed ? .orange : (lfs?.state == .available ? .green : .secondary)
        let githubStatus = switch github.cliState {
        case .available: "已发现"
        case .unavailable: "未发现"
        case .failed: "读取失败"
        }
        let githubColor: Color = switch github.cliState {
        case .available: .green
        case .unavailable: .secondary
        case .failed: .orange
        }

        return HStack(alignment: .center, spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.orange.opacity(0.10))
                Image("GitLogo")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.orange)
                    .padding(13)
            }
            .frame(width: 64, height: 64)
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.orange.opacity(0.16))
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text("Git")
                    .font(.title3.bold())
                Text(git.version ?? status)
                    .font(.title2.bold())
                    .monospacedDigit()
                Text("当前生效 CLI")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label(status, systemImage: statusImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(statusColor.opacity(0.10), in: Capsule())
            }
            .frame(width: 150, alignment: .leading)

            HStack(spacing: 10) {
                environmentMetric(
                    title: "Git LFS",
                    value: lfsValue,
                    systemImage: "externaldrive",
                    tint: lfsColor
                )
                environmentMetric(
                    title: "默认分支",
                    value: configuration?.defaultBranch ?? "未配置",
                    systemImage: "arrow.triangle.branch",
                    tint: .indigo
                )
                environmentMetric(
                    title: "认证",
                    value: "GitHub CLI \(githubStatus)",
                    systemImage: "person.crop.circle.badge.checkmark",
                    tint: githubColor
                )
            }
            .frame(maxWidth: .infinity)
        }
        .contentShape(Rectangle())
    }

    private func gitConfigurationDetails(
        _ configuration: UserGitConfigurationSnapshot?,
        lfs: GitLFSSnapshot?,
        signing: GitSigningConfigurationSnapshot?,
        credentialHelpers: [String]?,
        executable: String?,
        github: GitHubAuthenticationConfigurationSnapshot
    ) -> some View {
        let lfsValue = lfs?.version ?? (lfs?.state == .failed ? "读取失败" : "未发现")
        let defaultBranch = configuration?.defaultBranch ?? "未配置"
        let githubCLIStatus = switch github.cliState {
        case .available: "已发现"
        case .unavailable: "未发现"
        case .failed: "读取失败"
        }
        let githubCLIColor: Color = switch github.cliState {
        case .available: .green
        case .unavailable: .secondary
        case .failed: .orange
        }

        return VStack(alignment: .leading, spacing: 12) {
            if let executable {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Git CLI 路径")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    copyablePath(executable)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.primary.opacity(0.09))
                }
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 280), spacing: 12, alignment: .top)],
                alignment: .leading,
                spacing: 12
            ) {
                if let configuration {
                    gitDetailCard("基础信息", systemImage: "info.circle") {
                        gitDetailRow("Git LFS", lfsValue)
                        gitDetailRow(
                            "Excludes File 来源",
                            configuration.excludesFile.source == .explicitConfiguration ? "显式配置" : "Git 默认"
                        )
                        VStack(alignment: .leading, spacing: 5) {
                            Text("User Excludes File")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            copyablePath(configuration.excludesFile.path)
                        }
                        gitStatusPill(
                            configuration.excludesFile.exists ? "文件存在" : "文件不存在",
                            color: configuration.excludesFile.exists ? .green : .secondary,
                            systemImage: configuration.excludesFile.exists ? "checkmark.circle.fill" : "minus.circle"
                        )
                    }

                    gitDetailCard("Default Git Identity", systemImage: "person") {
                        gitDetailRow("名称", configuration.defaultIdentity.name ?? "未配置")
                        gitDetailRow("邮箱", configuration.defaultIdentity.email ?? "未配置")
                        gitDetailRow("默认分支", defaultBranch)
                    }
                } else {
                    gitDetailCard("User Git Configuration", systemImage: "exclamationmark.triangle") {
                        Text("读取失败，请查看 Scan Notice")
                            .foregroundStyle(.orange)
                    }
                }

                gitDetailCard("签名配置", systemImage: "checkmark.shield") {
                    if let signing {
                        gitDetailRow("格式", signing.format ?? "未配置")
                        gitDetailRow("签名标识", signing.signingKey ?? "未配置")
                        gitDetailRow("提交签名", signing.commitSigning ?? "未配置")
                        gitDetailRow("标签签名", signing.tagSigning ?? "未配置")
                    } else {
                        Text("读取失败，请查看 Scan Notice")
                            .foregroundStyle(.orange)
                    }
                }

                gitDetailCard("Credential Helper Chain", systemImage: "key") {
                    if let credentialHelpers {
                        if credentialHelpers.isEmpty {
                            gitStatusPill("未配置", color: .secondary, systemImage: "minus.circle")
                        } else {
                            ForEach(Array(credentialHelpers.enumerated()), id: \.offset) { index, helper in
                                gitDetailRow("\(index + 1)", helper)
                            }
                        }
                    } else {
                        Text("读取失败，请查看 Scan Notice")
                            .foregroundStyle(.orange)
                    }
                }
            }

            gitDetailCard("GitHub Authentication Configuration", systemImage: "person.crop.circle") {
                VStack(spacing: 0) {
                    gitAuthenticationRow("GitHub CLI", value: githubCLIStatus, color: githubCLIColor)
                    Divider()
                    gitAuthenticationRow(
                        "git_protocol",
                        value: github.gitProtocol ?? (github.cliState == .failed ? "读取失败" : "未配置"),
                        color: github.gitProtocol == nil ? .secondary : .primary
                    )
                    Divider()
                    gitAuthenticationRow("本地配置", configured: github.localConfigurationExists)
                    Divider()
                    gitAuthenticationRow("进程 GH_TOKEN", configured: github.ghTokenExists)
                    Divider()
                    gitAuthenticationRow("进程 GITHUB_TOKEN", configured: github.githubTokenExists)
                }
                .background(Color.primary.opacity(0.018), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.08))
                }
            }
        }
    }

    private func gitDetailCard<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(Color.primary.opacity(0.09))
        }
    }

    private func gitDetailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private func gitStatusPill(_ value: String, color: Color, systemImage: String) -> some View {
        Label(value, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.09), in: Capsule())
    }

    private func gitAuthenticationRow(_ label: String, value: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .frame(width: 180, alignment: .leading)
            Text(value)
                .font(.callout.weight(.medium))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func gitAuthenticationRow(_ label: String, configured: Bool) -> some View {
        gitAuthenticationRow(
            label,
            value: configured ? "已配置" : "未配置",
            color: configured ? .green : .secondary
        )
    }

    private func toggleEnvironmentCard(_ card: EnvironmentCard) {
        let nextCard = expandedEnvironmentCard == card ? nil : card
        if reduceMotion {
            expandedEnvironmentCard = nextCard
            showsAllPathEntries = false
        } else {
            withAnimation(.smooth(duration: 0.32)) {
                expandedEnvironmentCard = nextCard
                showsAllPathEntries = false
            }
        }
    }

    private func togglePathEntryLimit() {
        if reduceMotion {
            showsAllPathEntries.toggle()
        } else {
            withAnimation(.snappy(duration: 0.25, extraBounce: 0.02)) {
                showsAllPathEntries.toggle()
            }
        }
    }

    private func terminalCard(_ applications: [TerminalApplicationSnapshot]) -> some View {
        inventoryEnvironmentCard(
            card: .terminal,
            title: "Terminal",
            primaryValue: applications.isEmpty ? "未发现" : "\(applications.count) 个应用",
            subtitle: "Terminal Application",
            systemImage: "macwindow.on.rectangle",
            tint: .cyan,
            status: applications.isEmpty ? "未发现" : "\(applications.count) 个应用",
            statusImage: applications.isEmpty ? "circle" : "checkmark.circle.fill",
            statusColor: applications.isEmpty ? .secondary : .green,
            hasDetails: !applications.isEmpty
        ) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(applications) { application in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(application.name)
                                .font(.callout.weight(.semibold))
                            Spacer()
                            Text(application.version ?? "版本未知")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        copyablePath(application.path)
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.primary.opacity(0.09))
                    }
                }
            }
        }
    }

    private func shellCard(_ installations: [ShellInstallationSnapshot]) -> some View {
        let defaultShell = installations.first(where: \.isDefault)
        let hasWarning = defaultShell == nil || defaultShell?.isAvailable == false
        let status = if defaultShell == nil {
            "默认项未读取"
        } else if hasWarning {
            "默认项不可用"
        } else {
            "\(installations.count) 个 Shell"
        }

        return inventoryEnvironmentCard(
            card: .shell,
            title: "Shell",
            primaryValue: defaultShell?.name ?? "未读取",
            subtitle: "\(installations.count) 个 Shell Installation",
            systemImage: "terminal",
            tint: .indigo,
            status: status,
            statusImage: hasWarning ? "exclamationmark.circle.fill" : "checkmark.circle.fill",
            statusColor: hasWarning ? .orange : .green,
            hasDetails: !installations.isEmpty
        ) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(installations) { installation in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(installation.name)
                                .font(.callout.weight(.semibold))
                            if installation.isDefault {
                                Text("默认登录 Shell")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Color.accentColor.opacity(0.10), in: Capsule())
                            }
                            Spacer()
                            Label(
                                installation.isAvailable ? "可用" : "不可用",
                                systemImage: installation.isAvailable ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
                            )
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(installation.isAvailable ? Color.green : Color.orange)
                        }
                        copyablePath(installation.path)
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.primary.opacity(0.09))
                    }
                }
            }
        }
    }

    private func inventoryEnvironmentCard<Details: View>(
        card: EnvironmentCard,
        title: String,
        primaryValue: String,
        subtitle: String,
        systemImage: String,
        tint: Color,
        status: String,
        statusImage: String,
        statusColor: Color,
        hasDetails: Bool,
        @ViewBuilder details: () -> Details
    ) -> some View {
        let isExpanded = expandedEnvironmentCard == card

        return VStack(alignment: .leading, spacing: 12) {
            if hasDetails {
                Button {
                    toggleEnvironmentCard(card)
                } label: {
                    inventoryEnvironmentCardSummary(
                        title: title,
                        primaryValue: primaryValue,
                        subtitle: subtitle,
                        systemImage: systemImage,
                        tint: tint,
                        status: status,
                        statusImage: statusImage,
                        statusColor: statusColor,
                        showsDisclosure: hasDetails
                    )
                }
                .buttonStyle(.plain)
                .accessibilityValue(isExpanded ? "已展开" : "已折叠")
            } else {
                inventoryEnvironmentCardSummary(
                    title: title,
                    primaryValue: primaryValue,
                    subtitle: subtitle,
                    systemImage: systemImage,
                    tint: tint,
                    status: status,
                    statusImage: statusImage,
                    statusColor: statusColor,
                    showsDisclosure: false
                )
            }

            if isExpanded {
                details()
                    .transition(.opacity)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.cardRaised)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.primary.opacity(0.09))
                }
        }
    }

    private func inventoryEnvironmentCardSummary(
        title: String,
        primaryValue: String,
        subtitle: String,
        systemImage: String,
        tint: Color,
        status: String,
        statusImage: String,
        statusColor: Color,
        showsDisclosure: Bool
    ) -> some View {
        environmentCardSummary(
            title: title,
            primaryValue: primaryValue,
            subtitle: subtitle,
            status: status,
            statusImage: statusImage,
            statusColor: statusColor,
            showsDisclosure: showsDisclosure
        ) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(tint.opacity(0.09))
                Image(systemName: systemImage)
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(tint)
            }
            .frame(width: 50, height: 50)
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(Color.primary.opacity(0.07))
            }
            .accessibilityHidden(true)
        }
    }

    private func environmentCardSummary<Icon: View>(
        title: String,
        primaryValue: String,
        subtitle: String,
        status: String,
        statusImage: String,
        statusColor: Color,
        showsDisclosure: Bool,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            icon()

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(primaryValue)
                    .font(.title3.bold())
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Label(status, systemImage: statusImage)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(statusColor)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(statusColor.opacity(0.10), in: Capsule())

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .opacity(showsDisclosure ? 1 : 0)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func packageManagerCard(
        _ homebrew: HomebrewSnapshot,
        managers: [PackageManagerSnapshot]
    ) -> some View {
        let discoveredCount = (homebrew.executable == nil ? 0 : 1)
            + managers.count { $0.state != .unavailable }
        let hasFailure = homebrew.error != nil || managers.contains { $0.state == .failed }
        let statusColor: Color = hasFailure ? .orange : (discoveredCount == 6 ? .green : .secondary)

        return inventoryEnvironmentCard(
            card: .packageManagers,
            title: "包管理器",
            primaryValue: "\(discoveredCount) / 6",
            subtitle: "Homebrew 与当前 PATH 工具",
            systemImage: "shippingbox",
            tint: .orange,
            status: "已发现 \(discoveredCount) / 6",
            statusImage: hasFailure ? "exclamationmark.circle.fill" : (discoveredCount == 6 ? "checkmark.circle.fill" : "circle"),
            statusColor: statusColor,
            hasDetails: true
        ) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 320), spacing: 12, alignment: .top)],
                alignment: .leading,
                spacing: 12
            ) {
                packageManagerDetailRow(
                    id: "homebrew",
                    name: "Homebrew",
                    version: homebrew.version,
                    executable: homebrew.executable,
                    actualExecutable: nil,
                    status: homebrew.available ? "已安装" : (homebrew.error == nil ? "未发现" : "读取失败"),
                    statusColor: homebrew.available ? .green : (homebrew.error == nil ? .secondary : .orange),
                    statusImage: homebrew.available ? "checkmark.circle.fill" : (homebrew.error == nil ? "circle" : "exclamationmark.circle.fill")
                )
                ForEach(managers) { manager in
                    packageManagerDetailRow(manager)
                }
            }
        }
    }

    private func packageManagerDetailRow(_ manager: PackageManagerSnapshot) -> some View {
        let appearance: (status: String, color: Color, image: String) = switch manager.state {
        case .available: ("已安装", .green, "checkmark.circle.fill")
        case .configured: ("已配置", .green, "checkmark.circle.fill")
        case .unavailable: ("未发现", .secondary, "circle")
        case .failed: ("读取失败", .orange, "exclamationmark.circle.fill")
        }
        return packageManagerDetailRow(
            id: manager.id,
            name: manager.name,
            version: manager.version ?? (manager.state == .configured ? "版本无法判断" : nil),
            executable: manager.executable,
            actualExecutable: manager.actualExecutable,
            status: appearance.status,
            statusColor: appearance.color,
            statusImage: appearance.image
        )
    }

    private func packageManagerDetailRow(
        id: String,
        name: String,
        version: String?,
        executable: String?,
        actualExecutable: String?,
        status: String,
        statusColor: Color,
        statusImage: String
    ) -> some View {
        let brand = packageManagerBrand(id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(id == "bun" ? Color.white.opacity(0.92) : brand.tint.opacity(0.10))
                    Image(brand.assetName)
                        .resizable()
                        .scaledToFit()
                        .padding(9)
                }
                .frame(width: 44, height: 44)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(brand.tint.opacity(0.18))
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.callout.weight(.semibold))
                    Text(version ?? status)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(version == nil ? .secondary : .primary)
                }
                Spacer(minLength: 8)
                Label(status, systemImage: statusImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(statusColor.opacity(0.10), in: Capsule())
            }
            if let executable {
                copyablePath(executable)
                if let actualExecutable { copyablePath(actualExecutable, prefix: "实际路径") }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(statusColor == .orange ? Color.orange.opacity(0.35) : Color.primary.opacity(0.09))
        }
        .accessibilityElement(children: .combine)
    }

    private func packageManagerBrand(_ id: String) -> (assetName: String, tint: Color) {
        switch id {
        case "homebrew": ("PackageManagerHomebrewLogo", Color(red: 0.98, green: 0.69, blue: 0.25))
        case "uv": ("PackageManagerUVLogo", Color(red: 0.87, green: 0.37, blue: 0.91))
        case "bun": ("PackageManagerBunLogo", .primary)
        case "npm": ("PackageManagerNPMLogo", Color(red: 0.80, green: 0.22, blue: 0.22))
        case "pnpm": ("PackageManagerPNPMLogo", Color(red: 0.96, green: 0.57, blue: 0.13))
        default: ("PackageManagerYarnLogo", Color(red: 0.17, green: 0.56, blue: 0.73))
        }
    }

    private func pathCard(_ path: [String], warningCount: Int) -> some View {
        let isExpanded = expandedEnvironmentCard == .path

        return VStack(alignment: .leading, spacing: 12) {
            Group {
                if isExpanded {
                    Button {
                        toggleEnvironmentCard(.path)
                    } label: {
                        pathExpandedSummary(path, warningCount: warningCount)
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue("已展开")
                } else if path.isEmpty {
                    pathCardSummary(path, warningCount: warningCount)
                } else {
                    Button {
                        toggleEnvironmentCard(.path)
                    } label: {
                        pathCardSummary(path, warningCount: warningCount)
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(isExpanded ? "已展开" : "已折叠")
                }
            }

            if isExpanded {
                pathDetails(path)
                    .transition(.opacity)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.cardRaised)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.primary.opacity(0.09))
                }
        }
    }

    private func pathExpandedSummary(_ path: [String], warningCount: Int) -> some View {
        let tint: Color = warningCount > 0 ? .orange : .green

        return HStack(alignment: .center, spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.opacity(0.10))
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 27, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 64, height: 64)
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.16))
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text("PATH")
                    .font(.title3.bold())
                Text("\(path.count) 个目录")
                    .font(.title2.bold())
                    .monospacedDigit()
                Text("环境变量路径扫描")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label(
                    warningCount > 0 ? "\(warningCount) 个开发语言冲突" : "未发现开发语言冲突",
                    systemImage: warningCount > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(tint.opacity(0.10), in: Capsule())
            }
            .frame(width: 190, alignment: .leading)

            HStack(spacing: 10) {
                environmentMetric(
                    title: "目录总数",
                    value: path.count.formatted(),
                    systemImage: "folder",
                    tint: .green
                )
                environmentMetric(
                    title: "开发语言冲突",
                    value: warningCount.formatted(),
                    systemImage: warningCount > 0 ? "exclamationmark.triangle" : "checkmark.circle",
                    tint: tint
                )
            }
            .frame(maxWidth: .infinity)
        }
        .contentShape(Rectangle())
    }

    private func pathCardSummary(_ path: [String], warningCount: Int) -> some View {
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
            .synchronizedEnvironmentCardUpperContent(minHeight: environmentCardUpperContentHeight)

            Divider()

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
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func pathDetails(_ path: [String]) -> some View {
        let visibleEntries = showsAllPathEntries ? path : Array(path.prefix(3))

        return VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(visibleEntries.enumerated()), id: \.offset) { index, entry in
                HStack(spacing: 10) {
                    Text("\(index + 1)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(index == 0 ? Color.accentColor : Color.secondary)
                        .frame(width: 28, height: 28)
                        .background(
                            (index == 0 ? Color.accentColor : Color.secondary).opacity(0.09),
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                    copyablePath(entry)
                    if index == 0 {
                        Text("最高优先级")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.09), in: Capsule())
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.primary.opacity(0.09))
                }
            }

            if path.count > 3 {
                Button {
                    togglePathEntryLimit()
                } label: {
                    Label(
                        showsAllPathEntries
                            ? "收起至 3 个目录"
                            : "展开其余 \(path.count - 3) 个目录",
                        systemImage: showsAllPathEntries ? "chevron.up" : "chevron.down"
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
            copyButton(path, help: "复制路径")
            .opacity(showsCopyButton ? 1 : 0)
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

    private func copyButton(_ value: String, help: String) -> some View {
        Button {
            copy(value)
        } label: {
            Label(copiedPath == value ? "已复制" : "复制", systemImage: copiedPath == value ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .focused($focusedCopyPath, equals: value)
        .help(help)
    }

    private var currentNotices: [OverviewAttentionItem] { currentOverviewAttentionItems }

    private var hasUnreadNotices: Bool {
        !currentNoticeIdentities.isEmpty && !currentNoticeIdentities.isSubset(of: readNoticeIdentities)
    }

    private func notificationsPopover(_ notices: [OverviewAttentionItem]) -> some View {
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
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(notices.enumerated()), id: \.element.id) { index, notice in
                            overviewAttentionRow(notice)
                            if index < notices.count - 1 { Divider().padding(.leading, 42) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 420)
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private func markCurrentNoticesRead() {
        readNoticeIdentities = currentNoticeIdentities
    }

    private var currentNoticeIdentities: Set<NoticeIdentity> {
        Set(currentOverviewAttentionItems.map { .overview($0.id) })
    }

    private var currentEnvironmentNotices: [EnvironmentNotice] {
        guard let snapshot = model.snapshot else { return [] }
        let messages = snapshot.runtimes
            .filter(\.hasPathVersionConflict)
            .map { "\($0.name)：PATH 版本冲突" }
            + snapshot.issues
        return messages.map { EnvironmentNotice(identities: [.message($0)], message: $0) }
            + localServiceNotices(snapshot.localServices)
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
