import Foundation

enum HomebrewServiceStatus: String, Sendable {
    case none
    case stopped
    case started
    case scheduled
    case error
    case unknown

    init(homebrewValue: String) {
        self = Self(rawValue: homebrewValue) ?? .unknown
    }
}

enum HomebrewServiceAction: String, CaseIterable, Sendable {
    case start
    case stop
    case restart

    var title: String {
        switch self {
        case .start: "启动"
        case .stop: "停止"
        case .restart: "重启"
        }
    }

    var persistentEffect: String {
        switch self {
        case .start: "服务将立即启动，并注册为登录时自动启动。"
        case .stop: "服务将立即停止，并取消登录时自动启动。"
        case .restart: "服务将重新启动，并保持登录时自动启动。"
        }
    }
}

struct HomebrewService: Identifiable, Equatable, Sendable {
    var id: String { formula }

    let formula: String
    let status: HomebrewServiceStatus
    let exitCode: Int32?

    var allowedActions: [HomebrewServiceAction] {
        switch status {
        case .none, .stopped: [.start]
        case .started, .scheduled, .error: [.stop, .restart]
        case .unknown: []
        }
    }
}

struct HomebrewServiceListState: Equatable, Sendable {
    let services: [HomebrewService]
    let isStale: Bool
    let error: String?
}

enum HomebrewServiceActionResultKind: Equatable, Sendable {
    case success
    case failure
    case unknown
}

struct HomebrewServiceActionResult: Sendable {
    let kind: HomebrewServiceActionResultKind
    let message: String
    let output: String?
    let list: HomebrewServiceListState
    let dynamicStatus: DynamicStatusSnapshot?
    let dynamicStatusError: String?
}

struct HomebrewServiceManager: Sendable {
    private struct JSONService: Decodable {
        let name: String
        let status: String
        let user: String?
        let exitCode: Int32?

        private enum CodingKeys: String, CodingKey {
            case name, status, user
            case exitCode = "exit_code"
        }
    }

    private let machine: any MachineAccess

    init(machine: any MachineAccess = LiveMachineAccess()) {
        self.machine = machine
    }

    func refresh(
        executable: String,
        previous: HomebrewServiceListState? = nil
    ) -> HomebrewServiceListState {
        let result = machine.command(
            executable: executable,
            arguments: ["services", "list", "--json"],
            timeout: 2
        )
        let error: String?
        if result.timedOut {
            error = "Homebrew Service 列表读取超时"
        } else if result.status != 0 {
            let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            error = output.isEmpty ? "Homebrew Service 列表读取失败" : "Homebrew Service 列表读取失败：\(output)"
        } else if let decoded = try? JSONDecoder().decode([JSONService].self, from: Data(result.output.utf8)) {
            let currentUser = machine.environment["USER"]
            let services = decoded.compactMap { item -> HomebrewService? in
                guard item.user == nil || item.user?.isEmpty == true || item.user == currentUser else { return nil }
                return HomebrewService(
                    formula: item.name,
                    status: HomebrewServiceStatus(homebrewValue: item.status),
                    exitCode: item.exitCode
                )
            }.sorted { $0.formula.localizedStandardCompare($1.formula) == .orderedAscending }
            return HomebrewServiceListState(services: services, isStale: false, error: nil)
        } else {
            error = "Homebrew Service 列表格式不受支持"
        }

        guard let previous, previous.error == nil || !previous.services.isEmpty else {
            return HomebrewServiceListState(services: [], isStale: false, error: error)
        }
        return HomebrewServiceListState(services: previous.services, isStale: true, error: error)
    }

    func perform(
        _ action: HomebrewServiceAction,
        on service: HomebrewService,
        executable: String,
        currentServices: [HomebrewService],
        snapshot: MachineSnapshot?
    ) -> HomebrewServiceActionResult {
        guard let current = currentServices.first(where: { $0.formula == service.formula }),
              current.allowedActions.contains(action) else {
            return HomebrewServiceActionResult(
                kind: .failure,
                message: "当前状态不允许\(action.title)",
                output: nil,
                list: HomebrewServiceListState(services: currentServices, isStale: false, error: nil),
                dynamicStatus: nil,
                dynamicStatusError: nil
            )
        }

        let command = machine.command(
            executable: executable,
            arguments: ["services", action.rawValue, current.formula],
            timeout: 75
        )
        let list = refresh(
            executable: executable,
            previous: HomebrewServiceListState(services: currentServices, isStale: false, error: nil)
        )
        let dynamicRefresh = snapshot.map { EnvironmentScanner(machine: machine).refreshDynamicStatus(in: $0) }
        let dynamicStatus: DynamicStatusSnapshot? = if case let .success(status)? = dynamicRefresh { status } else { nil }
        let dynamicStatusError: String? = if case let .failure(error)? = dynamicRefresh {
            error.localizedDescription
        } else {
            nil
        }
        let output = command.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind: HomebrewServiceActionResultKind
        let detail: String
        if command.timedOut {
            kind = .unknown
            detail = "结果未知：命令超时"
        } else if command.status != 0 {
            kind = .failure
            detail = "失败"
        } else if list.error != nil {
            kind = .unknown
            detail = "结果未知：无法确认最终状态"
        } else if let finalStatus = list.services.first(where: { $0.formula == current.formula })?.status,
                  isExpected(finalStatus, after: action) {
            kind = .success
            detail = "成功"
        } else {
            kind = .unknown
            detail = "结果未知：最终状态与命令不一致"
        }
        return HomebrewServiceActionResult(
            kind: kind,
            message: "\(current.formula) \(action.title)\(detail)",
            output: output.isEmpty ? nil : output,
            list: list,
            dynamicStatus: dynamicStatus,
            dynamicStatusError: dynamicStatusError
        )
    }

    private func isExpected(_ status: HomebrewServiceStatus, after action: HomebrewServiceAction) -> Bool {
        switch action {
        case .start, .restart: status == .started || status == .scheduled
        case .stop: status == .none
        }
    }
}
