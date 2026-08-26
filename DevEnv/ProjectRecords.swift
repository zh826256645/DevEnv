import Combine
import Foundation

enum ProjectAvailability: Equatable, Sendable {
    case unknown
    case available
    case unavailable(String)
}

enum ProjectRootBoundary: String, Codable, Equatable, Sendable {
    case manifest
    case git
    case explicit
}

struct ProjectRecord: Codable, Identifiable, Equatable, Sendable {
    var id: String { path }
    var title: String { URL(fileURLWithPath: path, isDirectory: true).lastPathComponent }

    let path: String
    let firstDiscoveredAt: Date
    var lastDiscoveredAt: Date
    var isNew: Bool
    var boundary: ProjectRootBoundary
    var availability: ProjectAvailability

    private enum CodingKeys: String, CodingKey {
        case path, firstDiscoveredAt, lastDiscoveredAt, isNew, boundary
    }

    init(
        path: String,
        discoveredAt: Date,
        isNew: Bool = true,
        boundary: ProjectRootBoundary = .manifest
    ) {
        self.path = path
        firstDiscoveredAt = discoveredAt
        lastDiscoveredAt = discoveredAt
        self.isNew = isNew
        self.boundary = boundary
        availability = .unknown
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        path = try values.decode(String.self, forKey: .path)
        firstDiscoveredAt = try values.decode(Date.self, forKey: .firstDiscoveredAt)
        lastDiscoveredAt = try values.decode(Date.self, forKey: .lastDiscoveredAt)
        isNew = try values.decode(Bool.self, forKey: .isNew)
        boundary = try values.decodeIfPresent(ProjectRootBoundary.self, forKey: .boundary) ?? .manifest
        availability = .unknown
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(path, forKey: .path)
        try values.encode(firstDiscoveredAt, forKey: .firstDiscoveredAt)
        try values.encode(lastDiscoveredAt, forKey: .lastDiscoveredAt)
        try values.encode(isNew, forKey: .isNew)
        try values.encode(boundary, forKey: .boundary)
    }
}

struct IgnoredProject: Codable, Identifiable, Equatable, Sendable {
    var id: String { path }

    let path: String
    let ignoredAt: Date
    let boundary: ProjectRootBoundary?
}

struct ProjectRemovalSummary: Equatable, Sendable {
    let projectCount: Int
    let ignoredProjectCount: Int

    var totalCount: Int { projectCount + ignoredProjectCount }
}

struct ProjectRecordDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    var records: [ProjectRecord]
    var ignoredProjects: [IgnoredProject]

    init(records: [ProjectRecord] = [], ignoredProjects: [IgnoredProject] = []) {
        schemaVersion = Self.currentSchemaVersion
        self.records = records
        self.ignoredProjects = ignoredProjects
    }

    mutating func mergeDiscovered(
        _ paths: [String],
        gitProjectPaths: Set<String> = [],
        at date: Date = Date()
    ) {
        for path in paths where !ignoredProjects.contains(where: {
            path == $0.path || path.hasPrefix($0.path + "/")
        }) {
            if let index = records.firstIndex(where: { $0.path == path }) {
                records[index].lastDiscoveredAt = date
                if gitProjectPaths.contains(path), records[index].boundary == .manifest {
                    records[index].boundary = .git
                }
            } else {
                records.append(ProjectRecord(
                    path: path,
                    discoveredAt: date,
                    boundary: gitProjectPaths.contains(path) ? .git : .manifest
                ))
            }
        }
        records.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    mutating func addDirect(_ paths: [String], at date: Date = Date()) {
        ignoredProjects.removeAll { paths.contains($0.path) }
        for path in paths {
            if let index = records.firstIndex(where: { $0.path == path }) {
                records[index].lastDiscoveredAt = date
                records[index].boundary = .explicit
            } else {
                records.append(ProjectRecord(path: path, discoveredAt: date, boundary: .explicit))
            }
        }
        records.removeAll { record in
            record.boundary == .manifest
                && paths.contains(where: { record.path.hasPrefix($0 + "/") })
        }
        records.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    mutating func clearNew(displayedProjectIDs: Set<String>) {
        for index in records.indices where displayedProjectIDs.contains(records[index].id) {
            records[index].isNew = false
        }
    }

    mutating func remove(projectID: String, at date: Date = Date()) {
        guard records.contains(where: { $0.id == projectID }) else { return }
        _ = remove(projectIDs: [projectID], at: date)
    }

    mutating func remove(projectIDs: Set<String>, at date: Date = Date()) -> ProjectRemovalSummary {
        let projects = records.filter { projectIDs.contains($0.id) }
        let ignoredPaths = Set(ignoredProjects.filter { projectIDs.contains($0.id) }.map(\.path))
        records.removeAll { projectIDs.contains($0.id) }
        ignoredProjects.removeAll { projectIDs.contains($0.id) }
        for project in projects where !ignoredPaths.contains(project.id) {
            ignoredProjects.append(IgnoredProject(
                path: project.id,
                ignoredAt: date,
                boundary: project.boundary
            ))
        }
        ignoredProjects.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return ProjectRemovalSummary(
            projectCount: projects.count,
            ignoredProjectCount: ignoredPaths.count
        )
    }

    mutating func restore(path: String, at date: Date = Date()) {
        let boundary = ignoredProjects.first { $0.path == path }?.boundary ?? .manifest
        ignoredProjects.removeAll { $0.path == path }
        if let index = records.firstIndex(where: { $0.path == path }) {
            records[index].lastDiscoveredAt = date
            records[index].boundary = boundary
        } else {
            records.append(ProjectRecord(path: path, discoveredAt: date, boundary: boundary))
        }
        records.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}

enum ProjectRecordStoreError: LocalizedError {
    case corrupt
    case incompatibleSchema(Int)

    var errorDescription: String? {
        switch self {
        case .corrupt: "项目记录存储损坏或无法读取"
        case let .incompatibleSchema(version): "项目记录存储版本不兼容（版本 \(version)）"
        }
    }
}

struct ProjectRecordStore: Sendable {
    private struct Header: Decodable { let schemaVersion: Int }

    private let fileURL: URL

    init(fileManager: FileManager = .default) {
        let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DevEnv", isDirectory: true)
        fileURL = directory.appendingPathComponent("project-records.json")
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load() throws -> ProjectRecordDocument {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return ProjectRecordDocument() }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let header = try? decoder.decode(Header.self, from: data) else {
            throw ProjectRecordStoreError.corrupt
        }
        guard header.schemaVersion == ProjectRecordDocument.currentSchemaVersion else {
            throw ProjectRecordStoreError.incompatibleSchema(header.schemaVersion)
        }
        do {
            return try decoder.decode(ProjectRecordDocument.self, from: data)
        } catch {
            throw ProjectRecordStoreError.corrupt
        }
    }

    func save(_ document: ProjectRecordDocument) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: fileURL, options: .atomic)
    }

    func recreatePreservingBackup() throws -> URL? {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var backupURL: URL?
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let backup = directory.appendingPathComponent("project-records.backup-\(UUID().uuidString).json")
            try FileManager.default.moveItem(at: fileURL, to: backup)
            backupURL = backup
        }
        try save(ProjectRecordDocument())
        return backupURL
    }
}

struct ProjectDiscoveryResult: Sendable {
    let projectPaths: [String]
    let gitProjectPaths: Set<String>
    let errors: [String]
    let wasCancelled: Bool
}

struct ProjectDiscovery: Sendable {
    private static let excludedDirectoryNames: Set<String> = [
        ".build", ".gradle", ".swiftpm", ".venv", "DerivedData", "Pods", "build", "dist",
        "node_modules", "target", "vendor", "venv",
    ]
    private static let primaryManifestNames: Set<String> = [
        "Cargo.toml", "Gemfile", "build.gradle", "build.gradle.kts", "compose.yaml", "compose.yml",
        "docker-compose.yaml", "docker-compose.yml", "go.mod", "go.work", "package.json", "pom.xml",
        "pyproject.toml", "settings.gradle", "settings.gradle.kts",
    ]

    func discover(
        searchRoots: [URL],
        ignoredPaths: Set<String>,
        explicitBoundaryPaths: Set<String> = [],
        onProgress: @Sendable (String, Int) -> Void = { _, _ in },
        isCancelled: @Sendable (String, Int) -> Bool = { _, _ in false }
    ) -> ProjectDiscoveryResult {
        let ignoredPaths = Set(ignoredPaths.map { canonicalPath(URL(fileURLWithPath: $0, isDirectory: true)) })
        let explicitBoundaryPaths = Set(explicitBoundaryPaths.map {
            canonicalPath(URL(fileURLWithPath: $0, isDirectory: true))
        })
        var projectPaths: [String] = []
        var seenProjectPaths: Set<String> = []
        var gitProjectPaths: Set<String> = []
        var errors: [String] = []
        var wasCancelled = false

        func appendProject(_ path: String, boundary: ProjectRootBoundary) {
            if boundary == .git { gitProjectPaths.insert(path) }
            guard seenProjectPaths.insert(path).inserted else { return }
            projectPaths.append(path)
        }

        func processDirectory(_ directory: URL, gitRoots: inout [String]) -> Bool {
            let path = canonicalPath(directory)
            onProgress(path, projectPaths.count)
            if isCancelled(path, projectPaths.count) {
                wasCancelled = true
                return false
            }

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                errors.append("\(path)：目录不存在")
                return true
            }
            guard isDirectory.boolValue else {
                errors.append("\(path)：不是目录")
                return true
            }
            let gitMarker = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(".git").path
            if FileManager.default.fileExists(atPath: gitMarker) {
                gitRoots.append(path)
                appendProject(path, boundary: .git)
                return true
            }
            guard !gitRoots.contains(where: { path.hasPrefix($0 + "/") }) else { return true }
            guard !explicitBoundaryPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else {
                return true
            }
            do {
                let entries = try FileManager.default.contentsOfDirectory(atPath: path)
                if entries.contains(where: isPrimaryManifest) { appendProject(path, boundary: .manifest) }
            } catch {
                errors.append("\(path)：\(error.localizedDescription)")
            }
            return true
        }

        for selectedRoot in searchRoots {
            let root = URL(fileURLWithPath: canonicalPath(selectedRoot), isDirectory: true)
            let rootPath = root.path
            if ignoredPaths.contains(where: { rootPath == $0 || rootPath.hasPrefix($0 + "/") }) { continue }
            var gitRoots: [String] = []
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDirectory),
               isDirectory.boolValue,
               !explicitBoundaryPaths.contains(where: { rootPath == $0 || rootPath.hasPrefix($0 + "/") }),
               let containingGitRoot = nearestContainingGitRoot(for: root) {
                if containingGitRoot != rootPath {
                    if isCancelled(rootPath, projectPaths.count) {
                        wasCancelled = true
                        break
                    }
                    gitRoots.append(containingGitRoot)
                    appendProject(containingGitRoot, boundary: .git)
                }
            }
            if wasCancelled { break }
            guard processDirectory(root, gitRoots: &gitRoots) else { break }
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) { url, error in
                errors.append("\(url.path)：\(error.localizedDescription)")
                return true
            }
            if let enumerator {
                while let url = enumerator.nextObject() as? URL {
                    guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                          values.isDirectory == true else { continue }
                    if values.isSymbolicLink == true
                        || Self.excludedDirectoryNames.contains(url.lastPathComponent) {
                        enumerator.skipDescendants()
                        continue
                    }
                    let path = canonicalPath(url)
                    if ignoredPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                        enumerator.skipDescendants()
                        continue
                    }
                    guard processDirectory(url, gitRoots: &gitRoots) else { break }
                }
            }
            if wasCancelled { break }
        }

        return ProjectDiscoveryResult(
            projectPaths: projectPaths,
            gitProjectPaths: gitProjectPaths,
            errors: errors,
            wasCancelled: wasCancelled
        )
    }

    func directProjectPaths(_ urls: [URL]) -> [String] {
        Array(Set(urls.map(canonicalPath))).sorted()
    }

    func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL.path
    }

    func availability(of path: String) -> ProjectAvailability {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .unavailable("项目根目录不存在")
        }
        guard isDirectory.boolValue else { return .unavailable("项目根路径不是目录") }
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: path)
            return .available
        } catch {
            return .unavailable("项目根目录不可读")
        }
    }

    private func isPrimaryManifest(_ name: String) -> Bool {
        Self.primaryManifestNames.contains(name)
            || name.hasSuffix(".gemspec")
            || name.hasSuffix(".rockspec")
    }

    private func nearestContainingGitRoot(for url: URL) -> String? {
        var candidate = url
        while true {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent(".git").path) {
                return canonicalPath(candidate)
            }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { return nil }
            candidate = parent
        }
    }
}

struct ProjectScanProgress: Equatable, Sendable {
    let currentPath: String
    let discoveredCount: Int
}

@MainActor
final class ProjectsViewModel: ObservableObject {
    @Published private(set) var document: ProjectRecordDocument
    @Published private(set) var scanProgress: ProjectScanProgress?
    @Published private(set) var resultMessage: String?
    @Published private(set) var operationError: String?
    @Published private(set) var storageError: String?
    @Published private(set) var analyses: [String: ProjectRequirementsAnalysis] = [:]
    @Published private(set) var projectNotices: [String: [ProjectNotice]] = [:]
    @Published private(set) var staleProjectIDs: Set<String> = []
    @Published private(set) var refreshingProjectIDs: Set<String> = []

    var records: [ProjectRecord] {
        document.records.sorted { lhs, rhs in
            if lhs.isNew != rhs.isNew { return lhs.isNew }
            let lhsUnavailable = if case .unavailable = lhs.availability { true } else { false }
            let rhsUnavailable = if case .unavailable = rhs.availability { true } else { false }
            if lhsUnavailable != rhsUnavailable { return !lhsUnavailable }
            let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
            return titleOrder == .orderedSame
                ? lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
                : titleOrder == .orderedAscending
        }
    }
    var ignoredProjects: [IgnoredProject] { document.ignoredProjects }
    var isScanning: Bool { scanTask != nil }
    var isRefreshingProjects: Bool { refreshTask != nil }
    var mutationsArePaused: Bool { storageError != nil }

    private let store: ProjectRecordStore
    private let discovery: ProjectDiscovery
    private var scanTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = UUID()
    private var displayedNewProjectIDs: Set<String> = []
    private var machineSnapshot: MachineSnapshot?

    init(store: ProjectRecordStore = ProjectRecordStore(), discovery: ProjectDiscovery = ProjectDiscovery()) {
        self.store = store
        self.discovery = discovery
        do {
            document = try store.load()
        } catch {
            document = ProjectRecordDocument()
            storageError = error.localizedDescription
        }
    }

    func enterProjects() {
        displayedNewProjectIDs.removeAll()
        refreshProjects()
    }

    func leaveProjects() {
        document.clearNew(displayedProjectIDs: displayedNewProjectIDs)
        displayedNewProjectIDs.removeAll()
        persist()
    }

    func markDisplayed(_ projectID: String) {
        if document.records.first(where: { $0.id == projectID })?.isNew == true {
            displayedNewProjectIDs.insert(projectID)
        }
    }

    func records(matching searchText: String) -> [ProjectRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return records }
        return records.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.path.localizedCaseInsensitiveContains(query)
        }
    }

    func summary(for project: ProjectRecord) -> ProjectRequirementsSummary? {
        if case .unavailable = project.availability { return .unavailable }
        return analyses[project.id]?.summary
    }

    func addDirect(_ urls: [URL]) {
        guard !mutationsArePaused, !isScanning else { return }
        let paths = discovery.directProjectPaths(urls)
        document.addDirect(paths)
        persist()
        refreshProjects()
        resultMessage = "已添加 \(paths.count) 个项目"
    }

    func scan(_ urls: [URL]) {
        guard !mutationsArePaused, !isScanning else { return }
        cancelProjectRefresh()
        operationError = nil
        resultMessage = nil
        scanProgress = ProjectScanProgress(currentPath: urls.first?.path ?? "", discoveredCount: 0)
        let ignoredPaths = Set(document.ignoredProjects.map(\.path))
        let explicitBoundaryPaths = Set(document.records.filter { $0.boundary == .explicit }.map(\.path))
        let discovery = discovery
        let model = self
        scanTask = Task.detached(priority: .userInitiated) {
            let result = discovery.discover(
                searchRoots: urls,
                ignoredPaths: ignoredPaths,
                explicitBoundaryPaths: explicitBoundaryPaths,
                onProgress: { path, count in
                    Task { @MainActor in
                        model.scanProgress = ProjectScanProgress(currentPath: path, discoveredCount: count)
                    }
                },
                isCancelled: { _, _ in Task.isCancelled }
            )
            await model.finishScan(result)
        }
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    func refreshRequirements(machineSnapshot: MachineSnapshot?) {
        self.machineSnapshot = machineSnapshot
        let scanner = ProjectRequirementsScanner()
        analyses = analyses.mapValues {
            scanner.recalculate($0, machineSnapshot: machineSnapshot)
        }
    }

    func refreshProjects() {
        guard !isScanning else { return }
        cancelProjectRefresh()
        let paths = document.records.map(\.path)
        guard !paths.isEmpty else { return }
        let generation = UUID()
        refreshGeneration = generation
        refreshingProjectIDs = Set(paths)
        let projectBoundaryPaths = Set(paths + document.ignoredProjects.map(\.path))
        let discovery = discovery
        let scanner = ProjectRequirementsScanner()
        let model = self
        refreshTask = Task.detached(priority: .utility) {
            for path in paths {
                guard !Task.isCancelled else {
                    await model.finishProjectRefresh(generation: generation, cancelled: true)
                    return
                }
                let availability = discovery.availability(of: path)
                let analysis: ProjectRequirementsAnalysis? = if availability == .available {
                    scanner.scan(
                        projectRoot: URL(fileURLWithPath: path, isDirectory: true),
                        excludingProjectPaths: projectBoundaryPaths
                    )
                } else {
                    nil
                }
                await model.applyProjectRefresh(
                    path: path,
                    availability: availability,
                    analysis: analysis,
                    generation: generation
                )
            }
            await model.finishProjectRefresh(generation: generation, cancelled: false)
        }
    }

    func remove(_ project: ProjectRecord) {
        _ = remove(projectIDs: Set([project.id]))
    }

    @discardableResult
    func remove(projectIDs: Set<String>) -> ProjectRemovalSummary? {
        guard !mutationsArePaused, !isScanning else { return nil }
        let previousDocument = document
        let summary = document.remove(projectIDs: projectIDs)
        guard summary.totalCount > 0 else { return summary }
        guard persist() else {
            document = previousDocument
            return nil
        }
        for projectID in projectIDs {
            displayedNewProjectIDs.remove(projectID)
            analyses.removeValue(forKey: projectID)
            projectNotices.removeValue(forKey: projectID)
            staleProjectIDs.remove(projectID)
            refreshingProjectIDs.remove(projectID)
        }
        return summary
    }

    func removalSummary(for projectIDs: Set<String>) -> ProjectRemovalSummary {
        ProjectRemovalSummary(
            projectCount: document.records.filter { projectIDs.contains($0.id) }.count,
            ignoredProjectCount: document.ignoredProjects.filter { projectIDs.contains($0.id) }.count
        )
    }

    func restore(_ ignoredProject: IgnoredProject) {
        guard !mutationsArePaused, !isScanning else { return }
        document.restore(path: ignoredProject.path)
        persist()
        refreshProjects()
    }

    func recreateStore() {
        do {
            let backupURL = try store.recreatePreservingBackup()
            document = ProjectRecordDocument()
            analyses = [:]
            projectNotices = [:]
            staleProjectIDs = []
            refreshingProjectIDs = []
            storageError = nil
            operationError = nil
            resultMessage = backupURL.map { "已重新创建存储，原文件备份于 \($0.path)" } ?? "已创建新的项目记录存储"
        } catch {
            operationError = "存储重新创建失败：\(error.localizedDescription)"
        }
    }

    private func applyProjectRefresh(
        path: String,
        availability: ProjectAvailability,
        analysis: ProjectRequirementsAnalysis?,
        generation: UUID
    ) {
        guard generation == refreshGeneration else { return }
        guard let index = document.records.firstIndex(where: { $0.path == path }) else { return }
        document.records[index].availability = availability
        if let analysis, analysis.notices.isEmpty {
            analyses[path] = ProjectRequirementsScanner().recalculate(
                analysis,
                machineSnapshot: machineSnapshot
            )
            projectNotices.removeValue(forKey: path)
            staleProjectIDs.remove(path)
        } else if let analysis {
            projectNotices[path] = analysis.notices
            if analyses[path] == nil {
                analyses[path] = ProjectRequirementsScanner().recalculate(
                    analysis,
                    machineSnapshot: machineSnapshot
                )
            }
            staleProjectIDs.insert(path)
        } else if analyses[path] != nil {
            staleProjectIDs.insert(path)
        }
        refreshingProjectIDs.remove(path)
    }

    private func finishProjectRefresh(generation: UUID, cancelled: Bool) {
        guard generation == refreshGeneration else { return }
        if cancelled {
            staleProjectIDs.formUnion(refreshingProjectIDs.filter { analyses[$0] != nil })
        }
        refreshingProjectIDs.removeAll()
        refreshTask = nil
    }

    private func cancelProjectRefresh() {
        refreshGeneration = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        staleProjectIDs.formUnion(refreshingProjectIDs.filter { analyses[$0] != nil })
        refreshingProjectIDs.removeAll()
    }

    private func finishScan(_ result: ProjectDiscoveryResult) {
        document.mergeDiscovered(result.projectPaths, gitProjectPaths: result.gitProjectPaths)
        persist()
        scanProgress = nil
        scanTask = nil
        refreshProjects()
        if !result.errors.isEmpty {
            operationError = result.errors.joined(separator: "\n")
        }
        resultMessage = result.wasCancelled
            ? "扫描已取消，保留已发现的 \(result.projectPaths.count) 个项目"
            : "扫描完成，发现 \(result.projectPaths.count) 个项目"
    }

    @discardableResult
    private func persist() -> Bool {
        guard !mutationsArePaused else { return false }
        do {
            try store.save(document)
            return true
        } catch {
            operationError = "项目记录保存失败：\(error.localizedDescription)"
            return false
        }
    }
}
