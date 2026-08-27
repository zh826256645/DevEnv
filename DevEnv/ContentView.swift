import AppKit
import SwiftUI

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

enum NoticeIdentity: Hashable {
    case message(String)
    case localService(ListenerBinding)
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

    private enum Page: CaseIterable, Hashable {
        case overview
        case projects
        case runtimes
        case databases
        case localServices
        case settings

        static var primaryPages: [Page] { allCases.filter { $0 != .settings } }

        var title: String {
            switch self {
            case .overview: "总览"
            case .projects: "项目"
            case .runtimes: "开发语言"
            case .databases: "数据库"
            case .localServices: "本地服务"
            case .settings: "设置"
            }
        }

        var systemImage: String {
            switch self {
            case .overview: "square.grid.2x2"
            case .projects: "folder"
            case .runtimes: "terminal"
            case .databases: "cylinder"
            case .localServices: "network"
            case .settings: "gearshape"
            }
        }
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
    @StateObject private var model = EnvironmentViewModel()
    @StateObject private var projectsModel = ProjectsViewModel()
    @State private var selectedPage: Page? = .overview
    @State private var copiedPath: String?
    @State private var hoveredPath: String?
    @State private var expandedRuntimeID: String?
    @State private var fullyShownRuntimeID: String?
    @State private var expandedDatabaseID: String?
    @State private var fullyShownDatabaseID: String?
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
    @FocusState private var focusedCopyPath: String?
    @FocusState private var projectSearchIsFocused: Bool
    @FocusState private var projectAddIsFocused: Bool

    var body: some View {
        navigation(model.snapshot)
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

                Button {
                    if selectedPage == .projects {
                        projectsModel.refreshProjects()
                    } else {
                        model.scan()
                    }
                } label: {
                    if selectedPage == .projects
                        ? (projectsModel.isScanning || projectsModel.isRefreshingProjects)
                        : model.isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .accessibilityLabel(
                    selectedPage == .projects
                        ? (projectsModel.isScanning || projectsModel.isRefreshingProjects
                            ? "正在刷新项目"
                            : "刷新项目")
                        : (model.busyDescription ?? "重新扫描")
                )
                .help(selectedPage == .projects ? "刷新项目状态" : (model.busyDescription ?? "重新扫描"))
                .keyboardShortcut("r", modifiers: .command)
                .disabled(
                    selectedPage == .projects
                        ? (projectsModel.isScanning || projectsModel.isRefreshingProjects)
                        : model.isBusy
                )
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
        .onAppear(perform: updateRefreshActivity)
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
            if selectedPage == .projects {
                projectsModel.refreshRequirements(machineSnapshot: model.snapshot)
            }
        }
        .sheet(isPresented: $isShowingSettingsExitConfirmation, onDismiss: {
            pendingPage = nil
        }) {
            settingsExitConfirmation
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
                let succeeded = projectsModel.remove(projectIDs: projectIDs) != nil
                pendingProjectRemovalIDs.removeAll()
                guard succeeded else { return }
                selectedProjectIDs.removeAll()
                isSelectingProjects = false
                selectFirstProjectIfNeeded()
                projectSearchIsFocused = true
            }
        } message: {
            let summary = projectsModel.removalSummary(for: pendingProjectRemovalIDs)
            Text("将移除 \(summary.projectCount) 个项目记录并清除 \(summary.ignoredProjectCount) 个忽略记录？不会删除、移动或修改原项目文件。项目记录会进入 Ignored Projects；忽略记录会从 DevEnv 中移除。")
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
        NavigationSplitView {
            VStack(spacing: 0) {
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

                Divider()

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
                .padding(.top, 14)

                Divider()

                Button {
                    requestPage(.settings)
                } label: {
                    Label(Page.settings.title, systemImage: Page.settings.systemImage)
                        .font(.system(size: 15, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            selectedPage == .settings ? Color.accentColor.opacity(0.15) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                }
                .buttonStyle(.plain)
                .padding(10)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            page(snapshot)
        }
        .navigationTitle("")
    }

    @ViewBuilder
    private func page(_ snapshot: MachineSnapshot?) -> some View {
        if selectedPage == .projects {
            populatedPage(.projects, snapshot: snapshot)
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
        if page == .projects {
            projectsPage
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(page, snapshot: snapshot)
                if let scanError = model.scanError, let snapshot, page != .projects {
                    scanErrorBanner(scanError, snapshot: snapshot)
                }
                if let dynamicRefreshError = model.dynamicRefreshError,
                   page == .databases || page == .localServices {
                    dynamicRefreshErrorBanner(dynamicRefreshError)
                }

                switch page {
                case .overview:
                    if let snapshot {
                        overviewMetricsSection(snapshot)
                        topOverviewSection(snapshot)
                        environmentSection(snapshot)
                    }
                case .projects:
                    EmptyView()
                case .runtimes:
                    if let snapshot { runtimePage(snapshot.runtimes) }
                case .databases:
                    if let snapshot { databasePage(snapshot.databaseInstallationOverviews) }
                case .localServices:
                    if let snapshot { localServicesSection(snapshot) }
                case .settings:
                    settingsPage
                }
            }
            .frame(
                maxWidth: page == .overview || page == .projects || page == .runtimes || page == .databases || page == .localServices
                    ? 1100
                    : 900
            )
            .frame(maxWidth: .infinity)
            .padding(28)
            }
            .id(page)
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
            projectsModel.refreshRequirements(machineSnapshot: model.snapshot)
            DispatchQueue.main.async { projectSearchIsFocused = true }
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
                    if page == .databases || page == .localServices {
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
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("项目")
                        .font(.title2.bold())
                    Text("\(projectsModel.records.count) 个项目  ·  本次新增 \(projectsModel.records.filter(\.isNew).count) 个")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 20)
                Button { chooseProjectDirectories(forBatchScan: false) } label: {
                    Label("添加项目", systemImage: "plus")
                }
                .focused($projectAddIsFocused)
                .disabled(projectsModel.mutationsArePaused || projectsModel.isScanning)
                Button("扫描目录…") { chooseProjectDirectories(forBatchScan: true) }
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
                        .disabled(projectsModel.mutationsArePaused || projectsModel.isScanning)
                }
            }
            .controlSize(.regular)
            .padding(.horizontal, 28)
            .padding(.vertical, 17)

            Divider()

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
                .padding(.horizontal, 28)
                .padding(.top, 12)
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
                .padding(.horizontal, 28)
                .padding(.top, 12)
            }

            if let error = projectsModel.operationError {
                GroupBox {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityLabel("项目操作失败，\(error)")
                .padding(.horizontal, 28)
                .padding(.top, 12)
            } else if let message = projectsModel.resultMessage {
                Label(message, systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(message)
                    .padding(.horizontal, 28)
                    .padding(.top, 10)
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
            } else {
                HSplitView {
                    projectList
                        .frame(minWidth: 220, idealWidth: 250, maxWidth: 360)
                    projectDetail
                        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                        .layoutPriority(1)
                }
                .accessibilityElement(children: .contain)
            }
        }
        .onAppear(perform: selectFirstProjectIfNeeded)
        .onChange(of: projectsModel.records.map(\.id)) { _, _ in
            selectFirstProjectIfNeeded()
        }
        .onChange(of: selectedProjectID) { _, _ in
            expandedProjectRequirementID = nil
        }
    }

    private var projectList: some View {
        VStack(spacing: 0) {
            TextField("搜索项目或路径", text: $projectSearchText)
                .textFieldStyle(.roundedBorder)
                .focused($projectSearchIsFocused)
                .accessibilityLabel("搜索项目标题或路径")
                .padding(16)
            List(selection: $selectedProjectID) {
                Section("项目列表") {
                    ForEach(projectsModel.records(matching: projectSearchText)) { project in
                        HStack(spacing: 8) {
                            if isSelectingProjects {
                                Toggle("", isOn: projectSelectionBinding(project.id))
                                    .labelsHidden()
                                    .toggleStyle(.checkbox)
                                    .accessibilityLabel("选择 \(project.title)")
                            }
                            projectListRow(project)
                        }
                        .tag(project.id)
                        .padding(.vertical, 4)
                        .onAppear { projectsModel.markDisplayed(project.id) }
                    }
                    if !projectSearchText.isEmpty && projectsModel.records(matching: projectSearchText).isEmpty {
                        Text("没有匹配的项目")
                            .foregroundStyle(.secondary)
                    }
                }
                if !projectsModel.ignoredProjects.isEmpty {
                    Section("已忽略的项目  \(projectsModel.ignoredProjects.count)") {
                        ForEach(projectsModel.ignoredProjects) { project in
                            HStack(spacing: 12) {
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
                            .padding(.vertical, 3)
                        }
                    }
                }
            }
            .accentColor(Color(red: 143.0 / 255, green: 203.0 / 255, blue: 235.0 / 255))
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }

    private func projectListRow(_ project: ProjectRecord) -> some View {
        let summary = projectsModel.summary(for: project)
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
                    .padding(28)
                }
                Divider()
                HStack(spacing: 12) {
                    Text("最近发现：\(formatted(project.lastDiscoveredAt))")
                        .foregroundStyle(.secondary)
                    Button("重新扫描", action: projectsModel.refreshProjects)
                        .disabled(projectsModel.isScanning || projectsModel.isRefreshingProjects)
                    Spacer()
                    Label(
                        project.availability == .available ? "项目可访问" : "项目不可访问",
                        systemImage: project.availability == .available ? "checkmark.circle" : "questionmark.circle"
                    )
                    .foregroundStyle(project.availability == .available ? .green : .secondary)
                }
                .font(.caption)
                .padding(.horizontal, 30)
                .padding(.vertical, 13)
            }
            .id(project.id)
        } else {
            ContentUnavailableView {
                Label("选择一个项目", systemImage: "sidebar.left")
            } description: {
                Text("从列表中选择项目以查看声明来源和 Machine Environment 证据。")
            }
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
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
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
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.22), in: RoundedRectangle(cornerRadius: 14))
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
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.45))
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
                .fill(Color.primary.opacity(0.018))
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
                .background(Color.primary.opacity(0.018), in: RoundedRectangle(cornerRadius: 10))
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
            Text("开发语言列表")
                .font(.title3.bold())

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

    @ViewBuilder
    private func runtimePage(_ runtimes: [RuntimeSnapshot]) -> some View {
        runtimeMetricsSection(runtimes)
        runtimesSection(runtimes)
    }

    private func runtimeMetricsSection(_ runtimes: [RuntimeSnapshot]) -> some View {
        let discoveredCount = runtimes.count { $0.state == .discovered }
        let installationCount = runtimes.reduce(0) { $0 + $1.installations.count }
        let conflictCount = runtimes.count { $0.hasPathVersionConflict }
        let unavailableCount = runtimes.count { $0.state == .unavailable }

        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4),
            spacing: 12
        ) {
            runtimeMetricCard(
                discoveredCount,
                title: "开发语言类别",
                systemImage: "terminal",
                tint: .blue
            )
            runtimeMetricCard(
                installationCount,
                title: "已发现版本",
                systemImage: "checkmark.circle.fill",
                tint: .green
            )
            runtimeMetricCard(
                conflictCount,
                title: "PATH 冲突",
                systemImage: "exclamationmark.triangle.fill",
                tint: .orange
            )
            runtimeMetricCard(
                unavailableCount,
                title: "未发现",
                systemImage: "questionmark",
                tint: .secondary
            )
        }
    }

    private func runtimeMetricCard(
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
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.45))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.primary.opacity(0.10))
                }
        }
        .accessibilityElement(children: .combine)
    }

    private func databaseInstallationsSection(_ overviews: [DatabaseInstallationOverview]) -> some View {
        let shouldCollapseExpanded = expandedDatabaseID.map { id in
            overviews.first(where: { $0.id == id })?.installations.isEmpty ?? true
        } ?? false

        return VStack(alignment: .leading, spacing: 16) {
            Text("Database 列表")
                .font(.title3.bold())

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

    @ViewBuilder
    private func databasePage(_ overviews: [DatabaseInstallationOverview]) -> some View {
        homebrewServiceFeedback
        databaseMetricsSection(overviews)
            .onAppear(perform: model.refreshHomebrewServices)
        databaseInstallationsSection(overviews)
    }

    private func databaseMetricsSection(_ overviews: [DatabaseInstallationOverview]) -> some View {
        let discoveredCount = overviews.count { $0.discoveryState == .discovered }
        let listeningCount = overviews.count { $0.listeningState == .listening }
        let unavailableCount = overviews.count { $0.discoveryState == .notFound }

        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4),
            spacing: 12
        ) {
            runtimeMetricCard(
                overviews.count,
                title: "数据库类别",
                systemImage: "cylinder.split.1x2.fill",
                tint: .blue
            )
            runtimeMetricCard(
                discoveredCount,
                title: "已发现安装",
                systemImage: "checkmark.circle.fill",
                tint: .green
            )
            runtimeMetricCard(
                listeningCount,
                title: "正在监听",
                systemImage: "waveform.path.ecg",
                tint: .green
            )
            runtimeMetricCard(
                unavailableCount,
                title: "未发现",
                systemImage: "questionmark",
                tint: .secondary
            )
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
        .padding(isExpanded ? 16 : 10)
        .frame(
            maxWidth: .infinity,
            minHeight: isExpanded ? nil : 100,
            alignment: isExpanded ? .topLeading : .leading
        )
        .background {
            RoundedRectangle(cornerRadius: isExpanded ? 16 : 14, style: .continuous)
                .fill(Color.primary.opacity(0.018))
                .overlay {
                    RoundedRectangle(cornerRadius: isExpanded ? 16 : 14, style: .continuous)
                        .stroke(highlightsStatus ? Color.orange.opacity(0.55) : Color.primary.opacity(0.10))
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

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                databaseLogo(database, size: 48, padding: 8)

                VStack(alignment: .leading, spacing: 5) {
                    Text(database.name)
                        .font(.headline)
                    Text(databaseVersion(database))
                        .font(.title3.bold())
                        .monospacedDigit()
                        .foregroundStyle(database.installations.contains { $0.error != nil } ? .orange : .primary)
                }

                Spacer(minLength: 8)

                ZStack {
                    Circle().fill(statusColor.opacity(0.13))
                    Image(systemName: statusSymbol)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(statusColor)
                }
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            }

            Text(
                database.installations.isEmpty
                    ? "未检测到 Database Installation"
                    : "\(database.installations.count) 个安装 · \(database.listeningCount) 个正在监听"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, 60)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
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
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 11))
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

    private func localServicesSection(_ snapshot: MachineSnapshot) -> some View {
        let groups = groupLocalServicesForDisplay(snapshot.localServices)
        let portCount = groups.reduce(0) { $0 + Set($1.bindings.map(\.port)).count }
        let exposedPortCount = groups.reduce(0) { $0 + $1.bindings.count { !$0.isLoopback } }

        return VStack(alignment: .leading, spacing: 18) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4),
                spacing: 12
            ) {
                runtimeMetricCard(
                    groups.count,
                    title: "服务类别",
                    systemImage: "globe",
                    tint: .blue
                )
                runtimeMetricCard(
                    groups.count,
                    title: "正在运行",
                    systemImage: "waveform.path.ecg",
                    tint: .green
                )
                runtimeMetricCard(
                    portCount,
                    title: "监听端口",
                    systemImage: "cable.connector",
                    tint: .blue
                )
                runtimeMetricCard(
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
        .background(Color.primary.opacity(0.018), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
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
                .fill(Color.primary.opacity(0.018))
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
                .fill(Color.primary.opacity(0.018))
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
        .padding(isExpanded ? 16 : 10)
        .frame(
            maxWidth: .infinity,
            minHeight: isExpanded ? nil : 100,
            alignment: isExpanded ? .topLeading : .leading
        )
        .background {
            RoundedRectangle(cornerRadius: isExpanded ? 16 : 14, style: .continuous)
                .fill(Color.primary.opacity(0.018))
                .overlay {
                    RoundedRectangle(cornerRadius: isExpanded ? 16 : 14, style: .continuous)
                        .stroke(
                            highlightsStatus
                                ? status.color.opacity(0.55)
                                : Color.primary.opacity(0.10)
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

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                runtimeLogo(brand)

                VStack(alignment: .leading, spacing: 5) {
                    Text(runtime.name)
                        .font(.headline)

                    Text(effectiveVersion(for: runtime))
                        .font(.title3.bold())
                        .monospacedDigit()
                        .foregroundStyle(runtime.state == .failed ? .orange : .primary)
                }

                Spacer(minLength: 8)

                ZStack {
                    Circle()
                        .fill(status.color.opacity(0.08))
                    Image(systemName: status.badgeSymbol)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(status.color)
                }
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            }

            HStack(spacing: 8) {
                Text(
                    runtime.installations.isEmpty
                        ? "未检测到安装版本"
                        : "\(runtime.installations.count) 个安装版本"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if runtime.hasPathVersionConflict || runtime.state == .failed {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(status.title)
                        .foregroundStyle(status.color)
                }
            }
            .font(.caption)
            .padding(.leading, 60)
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
                "当前 PATH 中存在该开发语言的多个不同版本。终端默认使用 PATH 顺序最靠前的版本，其他工具或项目可能解析到不同版本。"
            )
        }
        if runtime.state == .failed {
            return (
                "读取失败",
                "exclamationmark.triangle.fill",
                "exclamationmark.circle.fill",
                .orange,
                "已找到开发语言，但无法读取可用版本。常见原因包括命令超时、文件不可执行或版本输出无法识别。"
            )
        }
        if runtime.state == .discovered {
            return ("已安装", "checkmark", "checkmark.circle.fill", .green, nil)
        }
        return ("未发现", "questionmark", "circle.fill", .secondary, nil)
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
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.018))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.primary.opacity(0.08))
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
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
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
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
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
        HStack(alignment: .center, spacing: 14) {
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

            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
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
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
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
        currentEnvironmentNotices.map(\.message)
    }

    private var hasUnreadNotices: Bool {
        !currentNoticeIdentities.isEmpty && !currentNoticeIdentities.isSubset(of: readNoticeIdentities)
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
        readNoticeIdentities = currentNoticeIdentities
    }

    private var currentNoticeIdentities: Set<NoticeIdentity> {
        Set(currentEnvironmentNotices.flatMap(\.identities))
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
