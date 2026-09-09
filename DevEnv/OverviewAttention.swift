import Foundation

enum OverviewAttentionSeverity: String, Sendable {
    case critical
    case warning
}

enum OverviewAttentionTarget: Hashable, Sendable {
    case run(String)
    case project(String, capability: String?)
    case runtime(String)
    case database(String)
    case localServices
    case environmentRefresh
    case dynamicRefresh
    case storage
}

enum OverviewAttentionKind: String, Sendable {
    case runFailure
    case runEvidence
    case refresh
    case projectRequirementsEvidence
    case projectRequirement
    case exposedPort
    case pathConflict
    case disk
}

struct OverviewAttentionRunInput: Sendable {
    let configuration: ProjectRunConfiguration
    let project: ProjectRecord
    let state: ProjectRunSessionState
    let lastSuccessfulCommand: String?
    let startedAt: Date?
    let failureMessage: String?
    let failureAt: Date?
    let ownedProcessIDs: Set<Int32>?
    let physicalMemoryBytes: UInt64?
    let repositoryState: ProjectRepositoryState
}

struct OverviewAttentionInput: Sendable {
    let snapshot: MachineSnapshot
    let runs: [OverviewAttentionRunInput]
    let analyses: [String: ProjectRequirementsAnalysis]
    let staleProjectIDs: Set<String>
    let refreshingProjectIDs: Set<String>
    let scanError: String?
    let dynamicRefreshError: String?
    let dynamicStatusRefreshedAt: Date?
}

struct OverviewRunProjection: Identifiable, Sendable {
    var id: String { configuration.id }

    let configuration: ProjectRunConfiguration
    let project: ProjectRecord
    let state: ProjectRunSessionState
    let lastSuccessfulCommand: String?
    let startedAt: Date?
    let failureMessage: String?
    let failureAt: Date?
    let ownedProcessIDs: Set<Int32>?
    let physicalMemoryBytes: UInt64?
    let bindings: [ListenerBinding]?
    let repositoryState: ProjectRepositoryState
}

struct OverviewAttentionItem: Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String
    let severity: OverviewAttentionSeverity
    let kind: OverviewAttentionKind
    let occurredAt: Date?
    let target: OverviewAttentionTarget
}

struct OverviewAttentionResult: Sendable {
    let runs: [OverviewRunProjection]
    let items: [OverviewAttentionItem]
}

enum OverviewAttention {
    private static let runtimeCapabilities: Set<String> = ["node", "python", "go", "java", "rust", "ruby", "lua"]
    private static let databaseCapabilities: Set<String> = ["postgresql", "mysql", "mariadb", "mongodb", "redis", "mysql-compatible"]
    private static let runStatusFreshness: TimeInterval = 60
    private static let environmentFreshness: TimeInterval = 24 * 60 * 60
    private static let lowDiskBytes: UInt64 = 20 * 1_024 * 1_024 * 1_024

    static func project(_ input: OverviewAttentionInput, now: Date) -> OverviewAttentionResult {
        let runs = input.runs
            .filter { $0.state.isLive || $0.failureMessage != nil }
            .map { run in
                let bindings: [ListenerBinding]? = if run.state == .running, let processIDs = run.ownedProcessIDs {
                    Array(Set(input.snapshot.localServices
                        .filter { processIDs.contains($0.pid) }
                        .flatMap(\.bindings)))
                        .sorted { $0.port == $1.port ? $0.address < $1.address : $0.port < $1.port }
                } else { nil }
                return OverviewRunProjection(
                    configuration: run.configuration,
                    project: run.project,
                    state: run.state,
                    lastSuccessfulCommand: run.lastSuccessfulCommand,
                    startedAt: run.startedAt,
                    failureMessage: run.failureMessage,
                    failureAt: run.failureAt,
                    ownedProcessIDs: run.ownedProcessIDs,
                    physicalMemoryBytes: run.physicalMemoryBytes,
                    bindings: bindings,
                    repositoryState: run.repositoryState
                )
            }
            .sorted { lhs, rhs in
                let lhsStarting = lhs.state == .starting
                let rhsStarting = rhs.state == .starting
                if lhsStarting != rhsStarting { return lhsStarting }
                let lhsDate = lhs.startedAt ?? .distantPast
                let rhsDate = rhs.startedAt ?? .distantPast
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return lhs.id < rhs.id
            }

        var items: [OverviewAttentionItem] = []
        func add(
            _ id: String,
            _ title: String,
            _ detail: String,
            _ severity: OverviewAttentionSeverity,
            _ kind: OverviewAttentionKind,
            _ occurredAt: Date?,
            _ target: OverviewAttentionTarget
        ) {
            items.append(OverviewAttentionItem(id: id, title: title, detail: detail, severity: severity, kind: kind, occurredAt: occurredAt, target: target))
        }

        for run in runs {
            guard let message = run.failureMessage else { continue }
            add("run-failure:\(run.id)", "\(run.project.title) 运行失败", "\(run.configuration.name)：\(message)", .critical, .runFailure, run.failureAt, .run(run.id))
        }

        for run in runs where run.state == .running && run.ownedProcessIDs == nil {
            add("run-evidence:\(run.id)", "\(run.project.title) 运行证据不足", "无法确证该运行会话的进程归属，端口与内存状态可能不完整", .warning, .runEvidence, run.startedAt, .run(run.id))
        }

        let dynamicUpdatedAt = input.dynamicStatusRefreshedAt ?? input.snapshot.scannedAt
        if let error = input.dynamicRefreshError {
            add("dynamic-refresh-failed", "运行状态刷新失败", error, .warning, .refresh, dynamicUpdatedAt, .dynamicRefresh)
        } else if now.timeIntervalSince(dynamicUpdatedAt) > runStatusFreshness {
            add("dynamic-status-stale", "运行状态已过期", "超过 60 秒没有成功刷新监听状态", .warning, .refresh, dynamicUpdatedAt, .dynamicRefresh)
        }

        if let error = input.scanError {
            add("environment-scan-failed", "环境扫描失败", error, .warning, .refresh, input.snapshot.scannedAt, .environmentRefresh)
        } else if now.timeIntervalSince(input.snapshot.scannedAt) > environmentFreshness {
            add("environment-snapshot-stale", "环境扫描结果已过期", "超过 24 小时没有完成一次环境扫描", .warning, .refresh, input.snapshot.scannedAt, .environmentRefresh)
        }

        let activeProjects = Dictionary(grouping: runs.filter { $0.state.isLive }, by: { $0.project.path })
            .values.compactMap { group in
                let projects = group.map(\.project).sorted { $0.id < $1.id }
                return projects.first { input.analyses[$0.id] != nil && !input.staleProjectIDs.contains($0.id) }
                    ?? projects.first { input.analyses[$0.id] != nil }
                    ?? projects.first
            }.sorted { $0.path < $1.path }
        var requirementRiskIDs: Set<String> = []
        var requirementItemIDs: Set<String> = []
        var pathConflictIDs: Set<String> = []
        for project in activeProjects {
            let projectID = project.id
            guard let analysis = input.analyses[projectID] else {
                if !input.refreshingProjectIDs.contains(projectID) {
                add("project-requirements-unavailable:\(project.path)", "\(project.title) 项目要求证据不可用", "尚未取得 Project Requirements 分析结果", .warning, .projectRequirementsEvidence, nil, .project(projectID, capability: nil))
                }
                continue
            }
            if input.staleProjectIDs.contains(projectID) {
                add("project-requirements-stale:\(project.path)", "\(project.title) 项目要求证据已过期", "当前显示上次成功分析结果，尚未取得最新证据", .warning, .projectRequirementsEvidence, nil, .project(projectID, capability: nil))
            }
            for requirement in analysis.requirements {
                let itemID = "project-requirement:\(project.path):\(requirement.capability)"
                guard requirementItemIDs.insert(itemID).inserted else { continue }
                if requirement.satisfaction == .unsatisfied, databaseCapabilities.contains(requirement.capability) {
                    requirementRiskIDs.insert(itemID)
                    add(itemID, "\(project.title) 缺少 \(capabilityTitle(requirement.capability))", "未发现满足项目要求的数据库安装", .critical, .projectRequirement, nil, .database(databaseID(for: requirement.capability)))
                    continue
                }
                if requirement.satisfaction == .unsatisfied || requirement.satisfaction == .declarationConflict {
                    requirementRiskIDs.insert(itemID)
                    let detail = requirement.satisfaction == .declarationConflict ? "项目内存在无法同时满足的版本声明" : "要求 \(requirement.expression)"
                    add(itemID, "\(project.title) 的 \(capabilityTitle(requirement.capability)) 要求未满足", detail, .critical, .projectRequirement, nil, .project(projectID, capability: requirement.capability))
                    continue
                }
                if requirement.satisfaction == .undetermined {
                    requirementRiskIDs.insert(itemID)
                    add(itemID, "\(project.title) 的 \(capabilityTitle(requirement.capability)) 要求证据不足", "无法确认本机是否满足要求 \(requirement.expression)", .warning, .projectRequirement, nil, .project(projectID, capability: requirement.capability))
                    continue
                }
                guard databaseCapabilities.contains(requirement.capability), !requirement.matches.isEmpty else { continue }
                let listeningStates = requirement.matches.map { $0.listeningState ?? .unknown }
                if listeningStates.contains(.listening) { continue }
                let target = OverviewAttentionTarget.database(databaseID(for: requirement.capability))
                if listeningStates.allSatisfy({ $0 == .notListening }) {
                    add(itemID, "\(capabilityTitle(requirement.capability)) 当前未监听", "\(project.title) 的数据库要求已匹配安装，但没有 TCP Listener Binding", .critical, .projectRequirement, nil, target)
                } else {
                    add(itemID, "\(capabilityTitle(requirement.capability)) 监听证据不足", "\(project.title) 的数据库安装缺少明确的监听结果", .warning, .projectRequirement, nil, target)
                }
            }
        }

        for project in activeProjects {
            guard let analysis = input.analyses[project.id] else { continue }
            for requirement in analysis.requirements where runtimeCapabilities.contains(requirement.capability) {
                let requirementID = "project-requirement:\(project.path):\(requirement.capability)"
                guard !requirementRiskIDs.contains(requirementID),
                      let runtime = input.snapshot.runtimes.first(where: { $0.id == requirement.capability }),
                      runtime.hasPathVersionConflict else { continue }
                guard pathConflictIDs.insert(requirementID).inserted else { continue }
                let effectiveVersion = runtime.installations.first(where: \.isEffective)?.version ?? "未知"
                add("path-conflict:\(project.path):\(requirement.capability)", "\(capabilityTitle(requirement.capability)) PATH 版本冲突", "\(project.title)：要求 \(requirement.expression) · 当前生效 \(effectiveVersion)", .warning, .pathConflict, nil, .runtime(requirement.capability))
            }
        }

        for run in runs {
            let exposed = (run.bindings ?? []).filter { !$0.isLoopback }.sorted { $0.port == $1.port ? $0.address < $1.address : $0.port < $1.port }
            guard !exposed.isEmpty else { continue }
            add("exposed-run:\(run.id)", "\(run.project.title) 可能对局域网开放", "监听地址：\(exposed.map(bindingText).joined(separator: " · "))", .warning, .exposedPort, run.startedAt, .localServices)
        }

        if let free = input.snapshot.system.diskFreeBytes, free < lowDiskBytes {
            add("low-disk-space", "系统卷可用空间不足", "当前可用 \(ByteCountFormatter.string(fromByteCount: Int64(free), countStyle: .memory))，低于 20 GB", .warning, .disk, input.snapshot.scannedAt, .storage)
        }

        return OverviewAttentionResult(runs: runs, items: items.sorted { lhs, rhs in
            let lhsRank = rank(lhs.kind)
            let rhsRank = rank(rhs.kind)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            let lhsDate = lhs.occurredAt ?? .distantPast
            let rhsDate = rhs.occurredAt ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        })
    }

    private static func rank(_ kind: OverviewAttentionKind) -> Int {
        switch kind {
        case .runFailure: 0
        case .runEvidence: 1
        case .refresh: 2
        case .projectRequirementsEvidence: 3
        case .projectRequirement: 4
        case .exposedPort: 5
        case .pathConflict: 6
        case .disk: 7
        }
    }

    private static func capabilityTitle(_ capability: String) -> String {
        ["node": "Node.js", "python": "Python", "docker-compose": "Docker Compose", "go": "Go", "java": "Java", "rust": "Rust", "ruby": "Ruby", "lua": "Lua", "postgresql": "PostgreSQL", "mysql": "MySQL", "mariadb": "MariaDB", "mongodb": "MongoDB", "redis": "Redis", "mysql-compatible": "MySQL 兼容数据库要求"][capability] ?? capability
    }

    private static func databaseID(for capability: String) -> String {
        capability == "mysql-compatible" ? "mysql" : capability
    }

    private static func bindingText(_ binding: ListenerBinding) -> String {
        let rawAddress = binding.address == "*" ? (binding.family == .ipv4 ? "0.0.0.0" : "::") : binding.address
        return "\(binding.family == .ipv6 ? "[\(rawAddress)]" : rawAddress):\(binding.port)"
    }
}
