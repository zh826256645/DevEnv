import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    static let devEnvStatusBarAction = Notification.Name("DevEnv.statusBarAction")
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

    override convenience init() {
        let projectsModel = ProjectsViewModel()
        self.init(
            projectsModel: projectsModel,
            runCoordinator: ProjectRunCoordinator(projectsModel: projectsModel)
        )
    }

    init(projectsModel: ProjectsViewModel, runCoordinator: ProjectRunCoordinator) {
        self.projectsModel = projectsModel
        self.runCoordinator = runCoordinator
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        observeWindowLifecycle()
        rebuildStatusMenu()
        DispatchQueue.main.async { [weak self] in
            self?.updateDockVisibility()
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
        runCoordinator.objectWillChange
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

    func openMainWindow(configurationID: String? = nil) {
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
            window.title = "DevEnv"
            window.isReleasedWhenClosed = false
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
        let notificationInfo = userInfo.isEmpty ? nil : userInfo
        postStatusBarAction("open", userInfo: notificationInfo)
    }

    private var mainWindow: NSWindow? {
        NSApplication.shared.windows.first {
            $0.styleMask.contains(.titled) && ($0.isVisible || $0.isMiniaturized)
        }
    }

    func rebuildStatusMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let open = NSMenuItem(title: "打开面板", action: #selector(openDevEnv(_:)), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())

        let start = NSMenuItem(title: "全部启动", action: #selector(requestRunAll(_:)), keyEquivalent: "")
        start.target = self
        start.isEnabled = !runCoordinator.runConfigurationsToStart().isEmpty
        menu.addItem(start)
        let stop = NSMenuItem(title: "全部停止", action: #selector(requestStopAll(_:)), keyEquivalent: "")
        stop.target = self
        stop.isEnabled = !runCoordinator.activeRunConfigurationIDs.isEmpty
        menu.addItem(stop)
        menu.addItem(.separator())

        let summary = runCoordinator.sessionSummary
        let summaryItem = NSMenuItem(
            title: "\(summary.running) 运行 · \(summary.stopped) 停止 · \(summary.exceptional) 异常",
            action: nil,
            keyEquivalent: ""
        )
        summaryItem.attributedTitle = NSAttributedString(
            string: summaryItem.title,
            attributes: [.font: NSFont.menuFont(ofSize: 11)]
        )
        summaryItem.isEnabled = false
        menu.addItem(summaryItem)

        let activeConfigurations = runCoordinator.runConfigurations()
            .filter { runCoordinator.session(for: $0.id)?.state.isLive == true }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if activeConfigurations.isEmpty {
            let item = NSMenuItem(title: "没有活动会话", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for configuration in activeConfigurations {
                let state = runCoordinator.session(for: configuration.id)?.state ?? .inactive
                let item = NSMenuItem(
                    title: configuration.name + " · " + state.statusTitle,
                    action: #selector(openSession(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = configuration.id
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quitDevEnv(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusMenu = menu
        statusItem?.menu = menu
    }

    @objc private func openSession(_ sender: NSMenuItem) {
        openMainWindow(configurationID: sender.representedObject as? String)
    }

    @objc private func requestRunAll(_: NSMenuItem) {
        openMainWindow()
        postStatusBarAction("runAll")
    }

    @objc private func requestStopAll(_: NSMenuItem) {
        openMainWindow()
        postStatusBarAction("stopAll")
    }

    @objc private func openDevEnv(_: NSMenuItem) {
        openMainWindow()
    }

    @objc private func quitDevEnv(_: NSMenuItem) {
        NSApplication.shared.terminate(nil)
    }

    private func postStatusBarAction(_ action: String, userInfo: [AnyHashable: Any]? = nil) {
        DispatchQueue.main.async {
            var info = userInfo ?? [:]
            info["action"] = action
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
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1280, height: 800)
    }
}
