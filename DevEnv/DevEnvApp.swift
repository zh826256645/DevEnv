import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    static let devEnvStatusBarAction = Notification.Name("DevEnv.statusBarAction")
}

enum DevEnvStatusBarAction: String {
    case open
    case showRuns
}

@MainActor
final class DevEnvAppDelegate: NSObject, NSApplicationDelegate {
    let projectsModel: ProjectsViewModel
    let runCoordinator: ProjectRunCoordinator
    private(set) var statusItem: NSStatusItem?
    private(set) var statusMenu = NSMenu()
    private var cancellables: Set<AnyCancellable> = []
    private var windowObservers: [NSObjectProtocol] = []
    private var fallbackWindow: NSWindow?
    private let statusBarRunPageHandoff: (() -> Void)?

    override convenience init() {
        let projectsModel = ProjectsViewModel()
        self.init(
            projectsModel: projectsModel,
            runCoordinator: ProjectRunCoordinator(projectsModel: projectsModel)
        )
    }

    init(
        projectsModel: ProjectsViewModel,
        runCoordinator: ProjectRunCoordinator,
        statusBarRunPageHandoff: (() -> Void)? = nil
    ) {
        self.projectsModel = projectsModel
        self.runCoordinator = runCoordinator
        self.statusBarRunPageHandoff = statusBarRunPageHandoff
        super.init()
        observeStatusMenuInputs()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        observeWindowLifecycle()
        rebuildStatusMenu()
        DispatchQueue.main.async { [weak self] in
            self?.updateDockVisibility()
            self?.openMainWindow()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag { openMainWindow() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        runCoordinator.terminateAllForApplicationExit() ? .terminateNow : .terminateCancel
    }

    private func installStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = NSImage(named: "StatusBarIcon") {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            item.button?.image = image
        }
        item.button?.toolTip = "DevEnv"
        item.menu = statusMenu
        statusItem = item
    }

    private func observeStatusMenuInputs() {
        Publishers.Merge(runCoordinator.objectWillChange, projectsModel.objectWillChange)
            .sink { [weak self] _ in
                Task { @MainActor in self?.rebuildStatusMenu() }
            }
            .store(in: &cancellables)
    }

    private func observeWindowLifecycle() {
        let center = NotificationCenter.default
        for name in [
            NSWindow.didBecomeMainNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.willCloseNotification,
        ] {
            windowObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    await Task.yield()
                    self?.updateDockVisibility()
                }
            })
        }
    }

    private func updateDockVisibility() {
        let hasMainWindow = NSApplication.shared.windows.contains { window in
            window.styleMask.contains(.titled) && (window.isVisible || window.isMiniaturized)
        }
        NSApplication.shared.setActivationPolicy(hasMainWindow ? .regular : .accessory)
    }

    func openMainWindow(configurationID: String? = nil, detailTab: String? = nil) {
        NSApplication.shared.setActivationPolicy(.regular)
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
        } else if let fallbackWindow {
            fallbackWindow.makeKeyAndOrderFront(nil)
        } else {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            Self.configureMainWindow(window)
            window.contentViewController = NSHostingController(rootView: ContentView(
                projectsModel: projectsModel,
                runCoordinator: runCoordinator
            ))
            fallbackWindow = window
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        var userInfo: [AnyHashable: Any] = [:]
        if let configurationID { userInfo["configurationID"] = configurationID }
        if let detailTab { userInfo["detailTab"] = detailTab }
        let notificationInfo = userInfo.isEmpty ? nil : userInfo
        postStatusBarAction(.open, userInfo: notificationInfo)
    }

    static func configureMainWindow(_ window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.title = "DevEnv"
        window.isReleasedWhenClosed = false
    }

    private var mainWindow: NSWindow? {
        NSApplication.shared.windows.first {
            $0.styleMask.contains(.titled) && ($0.isVisible || $0.isMiniaturized)
        }
    }

    func rebuildStatusMenu() {
        let menu = makeMenu(width: 320)
        let open = menuAction("打开 DevEnv", action: #selector(openDevEnv(_:)))
        open.image = NSImage(named: "AppIcon")?.copy() as? NSImage
        open.image?.size = NSSize(width: 26, height: 26)
        menu.addItem(open)
        menu.addItem(.separator())

        let summary = NSMenuItem(title: "\(runCoordinator.sessionSummary.running) 个运行中", action: nil, keyEquivalent: "")
        summary.image = NSImage(size: NSSize(width: 14, height: 24), flipped: false) { rect in
            (self.runCoordinator.sessionSummary.running > 0 ? NSColor.systemGreen : .secondaryLabelColor).setFill()
            NSBezierPath(ovalIn: NSRect(x: 1, y: rect.midY - 6, width: 12, height: 12)).fill()
            return true
        }
        menu.addItem(summary)
        menu.addItem(.separator())

        if let workspace = projectsModel.document.workspaces.first(where: { $0.id == projectsModel.document.selectedWorkspaceID }) {
            let configurations = runCoordinator.runConfigurations(workspaceID: workspace.id)
            if projectsModel.document.workspaces.count > 1 {
                let selector = NSMenuItem(title: workspace.name, action: nil, keyEquivalent: "")
                selector.identifier = NSUserInterfaceItemIdentifier("workspaceSelector")
                selector.toolTip = "切换工作区"
                let choices = makeMenu(width: 210)
                for choice in projectsModel.document.workspaces {
                    let item = menuAction(choice.name, action: #selector(selectWorkspace(_:)), id: choice.id)
                    item.state = choice.id == workspace.id ? .on : .off
                    let button = NSButton(radioButtonWithTitle: choice.name, target: self, action: #selector(selectWorkspaceButton(_:)))
                    button.font = .menuFont(ofSize: 13)
                    button.state = item.state
                    button.sizeToFit()
                    let view = NSView(frame: NSRect(x: 0, y: 0, width: max(210, button.frame.width + 28), height: 28))
                    button.setFrameOrigin(NSPoint(x: 14, y: (28 - button.frame.height) / 2))
                    view.addSubview(button)
                    item.view = view
                    choices.addItem(item)
                }
                selector.submenu = choices
                menu.addItem(selector)
            } else {
                menu.addItem(.sectionHeader(title: workspace.name))
            }
            if configurations.isEmpty {
                let empty = NSMenuItem(title: "暂无运行配置", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                menu.addItem(empty)
            }
            for configuration in configurations {
                let item = NSMenuItem(title: configuration.name, action: nil, keyEquivalent: "")
                let command = runCoordinator.session(for: configuration.id)?.currentExecution?.command ?? configuration.command
                let summary = command.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
                item.subtitle = summary.count > 36 ? String(summary.prefix(35)) + "…" : summary
                item.image = configurationImage(configuration, showsStatus: true)
                item.representedObject = configuration.id
                item.submenu = configurationMenu(configuration)
                menu.addItem(item)
            }
            menu.addItem(.separator())
            let start = menuAction("启动未运行配置", symbol: "play", action: #selector(requestRunAll(_:)), id: workspace.id)
            start.isEnabled = runCoordinator.canStartBatch(in: configurations)
            menu.addItem(start)
            let stop = menuAction(runCoordinator.canCloseBatch(in: configurations) ? "关闭所有终端" : "停止此工作区…",
                                  symbol: "stop.fill", action: #selector(requestStopAll(_:)), id: workspace.id)
            stop.isEnabled = runCoordinator.canStopBatch(in: configurations)
            menu.addItem(stop)
            menu.addItem(.separator())
        }

        let global = NSMenuItem(title: "全局操作", action: nil, keyEquivalent: "")
        global.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        let globalMenu = makeMenu(width: 230)
        let configurations = runCoordinator.runConfigurations()
        let start = menuAction("全部工作区启动", symbol: "play", action: #selector(requestRunAll(_:)))
        start.isEnabled = runCoordinator.canStartBatch(in: configurations)
        globalMenu.addItem(start)
        let stop = menuAction(runCoordinator.canCloseBatch(in: configurations) ? "全部工作区关闭" : "全部工作区停止",
                              symbol: "stop.fill", action: #selector(requestStopAll(_:)))
        stop.isEnabled = runCoordinator.canStopBatch(in: configurations)
        globalMenu.addItem(stop)
        global.submenu = globalMenu
        menu.addItem(global)
        menu.addItem(.separator())
        let quit = menuAction("退出 DevEnv…", symbol: "rectangle.portrait.and.arrow.right", action: #selector(quitDevEnv(_:)))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
        // Keep the workspace submenu attached while its native controls update the list.
        let oldSelector = statusMenu.items.first { $0.identifier?.rawValue == "workspaceSelector" }
        let newSelector = menu.items.first { $0.identifier?.rawValue == "workspaceSelector" }
        let retainedSelector: NSMenuItem?
        if let oldSelector, let newSelector,
           oldSelector.submenu?.items.compactMap({ $0.representedObject as? String })
            == newSelector.submenu?.items.compactMap({ $0.representedObject as? String }) {
            retainedSelector = oldSelector
            oldSelector.title = newSelector.title
            for (old, new) in zip(oldSelector.submenu!.items, newSelector.submenu!.items) {
                old.title = new.title
                old.state = new.state
                if let button = old.view?.subviews.first as? NSButton {
                    button.title = new.title
                    button.state = new.state
                }
            }
        } else {
            retainedSelector = nil
        }
        for item in statusMenu.items where item !== retainedSelector { statusMenu.removeItem(item) }
        for (index, item) in menu.items.enumerated() {
            if item === newSelector, retainedSelector != nil { continue }
            menu.removeItem(item)
            statusMenu.insertItem(item, at: index)
        }
        statusMenu.minimumWidth = menu.minimumWidth
        statusMenu.font = menu.font
        statusMenu.autoenablesItems = false
    }

    @objc private func selectWorkspaceButton(_ sender: NSButton) {
        guard let item = sender.enclosingMenuItem else { return }
        selectWorkspace(item)
    }

    @objc private func selectWorkspace(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              projectsModel.selectWorkspace(id) else { return }
        rebuildStatusMenu()
    }

    private func makeMenu(width: CGFloat) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.minimumWidth = width
        menu.font = .systemFont(ofSize: 13)
        return menu
    }

    private func menuAction(_ title: String, symbol: String? = nil, action: Selector, id: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = id
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    private func configurationMenu(_ configuration: ProjectRunConfiguration) -> NSMenu {
        let menu = makeMenu(width: 210)
        let header = NSMenuItem(title: configuration.name, action: nil, keyEquivalent: "")
        header.image = configurationImage(configuration, showsStatus: false)
        menu.addItem(header)
        menu.addItem(.separator())
        menu.addItem(menuAction("打开终端", symbol: "terminal.fill", action: #selector(openSession(_:)), id: configuration.id))
        let session = runCoordinator.session(for: configuration.id)
        let state = session?.state ?? .inactive
        let project = configuration.associatedProject(in: projectsModel.records)
        let start = menuAction("启动", symbol: "play", action: #selector(startSession(_:)), id: configuration.id)
        start.isEnabled = runCoordinator.canStartBatch(in: [configuration]) && session?.isClosing != true
        menu.addItem(start)
        let restart = menuAction("重启", symbol: "arrow.clockwise", action: #selector(restartSession(_:)), id: configuration.id)
        restart.isEnabled = configuration.isEnabled && state.canRestart && session?.isClosing != true
            && !(configuration.projectID != nil && project == nil) && project?.availability.isUnavailable != true
        menu.addItem(restart)
        let stop = menuAction(state == .ready ? "关闭终端" : "停止", symbol: "stop.fill", action: #selector(stopSession(_:)), id: configuration.id)
        stop.isEnabled = state.isLive && session?.isClosing != true
        menu.addItem(stop)
        menu.addItem(.separator())
        menu.addItem(menuAction("查看配置", symbol: "doc.text", action: #selector(showConfiguration(_:)), id: configuration.id))
        return menu
    }

    private func configurationImage(_ configuration: ProjectRunConfiguration, showsStatus: Bool) -> NSImage? {
        let state = runCoordinator.session(for: configuration.id)?.state ?? .inactive
        let content = HStack(spacing: 10) {
            if showsStatus {
                Circle().fill(Color(nsColor: statusColor(for: state))).frame(width: 8, height: 8)
            }
            if let brand = devEnvRunConfigurationBrand(configuration, projectsModel: projectsModel) {
                devEnvRuntimeLogo(brand, size: 26, padding: 26 * 7 / 40, cornerRadius: 26 * 9 / 40)
            } else {
                Image(systemName: "terminal")
                    .font(.system(size: 15)).foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            }
        }.padding(.vertical, 3)
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage
    }

    private func statusColor(for state: ProjectRunSessionState) -> NSColor {
        switch state {
        case .starting, .ready: .systemBlue
        case .running: .systemGreen
        case .stopping: .systemOrange
        case .restarting: .systemPurple
        case .stopFailed, .restartFailed: .systemRed
        default: .secondaryLabelColor
        }
    }

    @objc private func openSession(_ sender: NSMenuItem) {
        guard let configuration = menuConfiguration(sender) else { return }
        openMainWindow(configurationID: configuration.id, detailTab: "终端")
        runCoordinator.openTerminal(configuration)
    }

    @objc private func showConfiguration(_ sender: NSMenuItem) {
        openMainWindow(configurationID: sender.representedObject as? String, detailTab: "详情")
    }

    private func menuConfiguration(_ sender: NSMenuItem) -> ProjectRunConfiguration? {
        runCoordinator.runConfigurations().first { $0.id == sender.representedObject as? String }
    }

    @objc private func startSession(_ sender: NSMenuItem) {
        guard let configuration = menuConfiguration(sender),
              runCoordinator.canStartBatch(in: [configuration]),
              runCoordinator.session(for: configuration.id)?.isClosing != true else { return }
        _ = runCoordinator.run(configuration, project: configuration.associatedProject(in: projectsModel.records))
    }

    @objc private func restartSession(_ sender: NSMenuItem) {
        guard let configuration = menuConfiguration(sender) else { return }
        runCoordinator.restart(configuration, project: configuration.associatedProject(in: projectsModel.records))
    }

    @objc private func stopSession(_ sender: NSMenuItem) {
        guard let configuration = menuConfiguration(sender) else { return }
        runCoordinator.stopOrCloseTerminal(configurationID: configuration.id)
    }

    @objc private func requestRunAll(_ sender: NSMenuItem) {
        let scope = runCoordinator.runConfigurations(workspaceID: sender.representedObject as? String)
        guard runCoordinator.canStartBatch(in: scope) else { return }
        let intent = runCoordinator.makeBatchStartIntent(in: scope)
        handoffToRunsPage()
        runCoordinator.requestBatchStart(intent)
    }

    @objc private func requestStopAll(_ sender: NSMenuItem) {
        let scope = runCoordinator.runConfigurations(workspaceID: sender.representedObject as? String)
        guard runCoordinator.canStopBatch(in: scope) else { return }
        runCoordinator.requestBatchStop(in: scope, closeReadyTerminals: true)
        handoffToRunsPage()
    }

    private func handoffToRunsPage() {
        if let statusBarRunPageHandoff {
            statusBarRunPageHandoff()
        } else {
            openMainWindow()
            postStatusBarAction(.showRuns)
        }
    }

    @objc private func openDevEnv(_: NSMenuItem) {
        openMainWindow()
    }

    @objc private func quitDevEnv(_: NSMenuItem) {
        NSApplication.shared.terminate(nil)
    }

    private func postStatusBarAction(
        _ action: DevEnvStatusBarAction,
        userInfo: [AnyHashable: Any]? = nil
    ) {
        DispatchQueue.main.async {
            var info = userInfo ?? [:]
            info["action"] = action.rawValue
            NotificationCenter.default.post(name: .devEnvStatusBarAction, object: nil, userInfo: info)
        }
    }
}

@main
struct DevEnvApp: App {
    @NSApplicationDelegateAdaptor(DevEnvAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(
                projectsModel: appDelegate.projectsModel,
                runCoordinator: appDelegate.runCoordinator
            )
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
    }
}
