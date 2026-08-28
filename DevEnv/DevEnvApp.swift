import AppKit
import SwiftUI

@MainActor
final class DevEnvAppDelegate: NSObject, NSApplicationDelegate {
    let projectsModel: ProjectsViewModel
    let runCoordinator: ProjectRunCoordinator

    override convenience init() {
        self.init(projectsModel: ProjectsViewModel(), runCoordinator: ProjectRunCoordinator())
    }

    init(projectsModel: ProjectsViewModel, runCoordinator: ProjectRunCoordinator) {
        self.projectsModel = projectsModel
        self.runCoordinator = runCoordinator
        super.init()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        runCoordinator.terminateAllForApplicationExit() ? .terminateNow : .terminateCancel
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
        .defaultSize(width: 1280, height: 820)
    }
}
