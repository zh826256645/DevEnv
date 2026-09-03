import Combine
import Foundation

enum ProjectAvailability: Equatable, Sendable {
    case unknown
    case available
    case unavailable(String)

    var isUnavailable: Bool {
        if case .unavailable = self { true } else { false }
    }
}

enum ProjectRootBoundary: String, Codable, Equatable, Sendable {
    case manifest
    case git
    case explicit
}

enum ProjectRepositoryState: Equatable, Sendable {
    case branch(String)
    case detached(String)
    case nonGit
    case unknown

    static func read(projectRoot: String, fileManager: FileManager = .default) -> Self {
        var directory = URL(fileURLWithPath: projectRoot, isDirectory: true).standardizedFileURL
        while true {
            let marker = directory.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: marker.path, isDirectory: &isDirectory) {
                let gitDirectory: URL
                if isDirectory.boolValue {
                    gitDirectory = marker
                } else {
                    guard let text = try? String(contentsOf: marker, encoding: .utf8),
                          text.hasPrefix("gitdir:") else { return .unknown }
                    let path = text.dropFirst("gitdir:".count)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    gitDirectory = URL(fileURLWithPath: path, relativeTo: directory).standardizedFileURL
                }
                guard let head = try? String(
                    contentsOf: gitDirectory.appendingPathComponent("HEAD"),
                    encoding: .utf8
                ).trimmingCharacters(in: .whitespacesAndNewlines), !head.isEmpty else { return .unknown }
                if head.hasPrefix("ref: refs/heads/") {
                    return .branch(String(head.dropFirst("ref: refs/heads/".count)))
                }
                return .detached(String(head.prefix(8)))
            }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { return .nonGit }
            directory = parent
        }
    }
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

struct ProjectRunConfiguration: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let projectID: String
    var name: String
    var command: String
    var workingDirectory: String
    let sourceIdentity: String?
    var isEnabled: Bool

    private enum CodingKeys: String, CodingKey {
        case id, projectID, name, command, workingDirectory, sourceIdentity, isEnabled
    }

    init(
        id: String = UUID().uuidString,
        projectID: String,
        name: String,
        command: String,
        workingDirectory: String,
        sourceIdentity: String? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.command = command
        self.workingDirectory = workingDirectory
        self.sourceIdentity = sourceIdentity
        self.isEnabled = isEnabled
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        projectID = try values.decode(String.self, forKey: .projectID)
        name = try values.decode(String.self, forKey: .name)
        command = try values.decode(String.self, forKey: .command)
        workingDirectory = try values.decode(String.self, forKey: .workingDirectory)
        sourceIdentity = try values.decodeIfPresent(String.self, forKey: .sourceIdentity)
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

struct ProjectRunSuggestion: Equatable, Identifiable, Sendable {
    let id: String
    let projectID: String
    let name: String
    let command: String
    let workingDirectory: String
    let sourceIdentity: String
    let sourceDescription: String

    init(
        projectID: String,
        name: String,
        command: String,
        workingDirectory: String,
        sourceIdentity: String,
        sourceDescription: String
    ) {
        self.projectID = projectID
        self.name = name
        self.command = command
        self.workingDirectory = workingDirectory
        self.sourceIdentity = sourceIdentity
        self.sourceDescription = sourceDescription
        id = "\(projectID):\(sourceIdentity)"
    }
}

/// Static, local-only run suggestion discovery. It never invokes project tools.
struct ProjectRunSuggestionScanner: Sendable {
    private static let composeNames = ["compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"]
    private static let packageManagers: Set<String> = ["npm", "pnpm", "yarn", "bun"]
    private static let runScriptBases: Set<String> = ["dev", "start", "serve"]
    private static let nonRunScriptBases: Set<String> = ["build", "test", "lint", "migrate", "migration", "check", "typecheck"]

    func scan(projectRoot: String, analysis: ProjectRequirementsAnalysis) -> [ProjectRunSuggestion] {
        let root = URL(fileURLWithPath: projectRoot, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        guard analysis.rootPath == root.path else { return [] }
        var suggestions: [ProjectRunSuggestion] = []
        for component in analysis.components {
            let directory = component.relativePath == "."
                ? root
                : root.appendingPathComponent(component.relativePath, isDirectory: true)
            if component.manifestNames.contains("package.json"),
               let manager = uniquePackageManager(component),
               let scripts = packageScripts(at: directory.appendingPathComponent("package.json")) {
                for name in scripts.keys.sorted() where isRunScript(name) {
                    let packageRelative = relativePath(directory.appendingPathComponent("package.json"), from: root)
                    let source = "\(packageRelative)#scripts.\(name)"
                    suggestions.append(ProjectRunSuggestion(
                        projectID: root.path,
                        name: "Node.js · \(name)",
                        command: "\(manager) run \(name)",
                        workingDirectory: component.relativePath,
                        sourceIdentity: source,
                        sourceDescription: "\(packageRelative) · scripts.\(name)"
                    ))
                }
            }
            if component.manifestNames.contains("pyproject.toml"),
               component.requirements.contains(where: { $0.capability == "uv" }) {
                let manifest = directory.appendingPathComponent("pyproject.toml")
                let relative = relativePath(manifest, from: root)
                for entry in pythonEntries(at: manifest) {
                    suggestions.append(ProjectRunSuggestion(
                        projectID: root.path,
                        name: "Python · \(entry)",
                        command: "uv run \(entry)",
                        workingDirectory: component.relativePath,
                        sourceIdentity: "\(relative)#project.scripts.\(entry)",
                        sourceDescription: "\(relative) · project.scripts.\(entry)"
                    ))
                }
            }
            if component.manifestNames.contains("Cargo.toml") {
                let manifest = directory.appendingPathComponent("Cargo.toml")
                let relative = relativePath(manifest, from: root)
                for target in cargoBinTargets(at: manifest) {
                    let features = target.features.isEmpty
                        ? ""
                        : " --features \(target.features.joined(separator: ","))"
                    suggestions.append(ProjectRunSuggestion(
                        projectID: root.path,
                        name: "Cargo · \(target.name)",
                        command: "cargo run --bin \(target.name)\(features)",
                        workingDirectory: component.relativePath,
                        sourceIdentity: "\(relative)#bin.\(target.name)",
                        sourceDescription: "\(relative) · bin.\(target.name)"
                    ))
                }
            }
            if let composeName = Self.composeNames.first(where: component.manifestNames.contains),
               isReadable(directory.appendingPathComponent(composeName)) {
                let relative = relativePath(directory.appendingPathComponent(composeName), from: root)
                suggestions.append(ProjectRunSuggestion(
                    projectID: root.path,
                    name: "Compose · \(composeName)",
                    command: "docker compose up",
                    workingDirectory: component.relativePath,
                    sourceIdentity: "\(relative)#compose",
                    sourceDescription: composeName
                ))
            }
        }
        return suggestions.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    private func uniquePackageManager(_ component: ProjectComponent) -> String? {
        let managers = Set(component.requirements.compactMap { requirement in
            Self.packageManagers.contains(requirement.capability) ? requirement.capability : nil
        })
        return managers.count == 1 ? managers.first : nil
    }

    private func packageScripts(at file: URL) -> [String: String]? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue <= ProjectRequirementsScanner.maxManifestBytes,
              let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = object["scripts"] as? [String: Any] else { return nil }
        return scripts.reduce(into: [:]) { result, entry in
            if let value = entry.value as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result[entry.key] = value
            }
        }
    }

    private func pythonEntries(at file: URL) -> [String] {
        guard let text = manifestText(at: file) else { return [] }
        var section: [String] = []
        var scriptsMode: String?
        var entries: [String: Int] = [:]
        func addEntry(_ name: String, _ rawValue: Substring) {
            guard isSafeCommandName(name),
                  let target = staticTomlString(rawValue),
                  target.range(
                    of: #"^[A-Za-z_][A-Za-z0-9_.]*:[A-Za-z_][A-Za-z0-9_.]*$"#,
                    options: .regularExpression
                  ) != nil else { return }
            entries[name, default: 0] += 1
        }
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = tomlLineWithoutComment(String(rawLine))
            if line.hasPrefix("[") && line.hasSuffix("]") {
                guard !line.hasPrefix("[["),
                      let path = staticTomlKeyPath(String(line.dropFirst().dropLast())) else {
                    section = []
                    continue
                }
                section = path
                if section == ["project", "scripts"] {
                    guard scriptsMode == nil else { return [] }
                    scriptsMode = "table"
                }
                continue
            }
            guard let separator = unquotedIndex(of: "=", in: line),
                  let keyPath = staticTomlKeyPath(String(line[..<separator])) else { continue }
            let value = line[line.index(after: separator)...]
            let path = section + keyPath
            if path == ["project", "dynamic"] {
                guard let dynamic = staticTomlStringArray(value) else { return [] }
                if dynamic.contains("scripts") { return [] }
            } else if section == ["project"], keyPath == ["scripts"] {
                guard scriptsMode == nil, let inlineEntries = staticTomlInlineTable(value) else { return [] }
                scriptsMode = "inline"
                for (name, target) in inlineEntries { addEntry(name, target[target.startIndex...]) }
            } else if path.count == 3, Array(path.prefix(2)) == ["project", "scripts"] {
                if section.isEmpty || section == ["project"] {
                    guard scriptsMode == nil || scriptsMode == "dotted" else { return [] }
                    scriptsMode = "dotted"
                }
                addEntry(path[2], value)
            }
        }
        guard entries.values.allSatisfy({ $0 == 1 }) else { return [] }
        return entries.keys.sorted()
    }

    private func cargoBinTargets(at file: URL) -> [(name: String, features: [String])] {
        guard let text = manifestText(at: file) else { return [] }
        var inBin = false
        var currentNames: [String] = []
        var currentFeatures: [String]? = []
        var sawRequiredFeatures = false
        var targets: [String: [[String]]] = [:]
        func finishTarget() {
            if currentNames.count == 1, let currentFeatures {
                targets[currentNames[0], default: []].append(currentFeatures)
            }
            currentNames.removeAll()
            currentFeatures = []
            sawRequiredFeatures = false
        }
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = tomlLineWithoutComment(String(rawLine))
            if line == "[[bin]]" {
                finishTarget()
                inBin = true
                continue
            }
            if line.hasPrefix("[") {
                finishTarget()
                inBin = false
                continue
            }
            guard inBin, let separator = unquotedIndex(of: "=", in: line),
                  let keyPath = staticTomlKeyPath(String(line[..<separator])),
                  keyPath.count == 1 else { continue }
            let key = keyPath[0]
            let value = line[line.index(after: separator)...]
            if key == "required-features" {
                guard !sawRequiredFeatures else { currentFeatures = nil; continue }
                sawRequiredFeatures = true
                currentFeatures = staticTomlStringArray(value).flatMap { features in
                    features.allSatisfy(isSafeCargoFeature) ? features : nil
                }
            } else if key == "name", let name = staticTomlString(value), isSafeCommandName(name) {
                currentNames.append(name)
            }
        }
        finishTarget()
        return targets.compactMap { name, declarations in
            declarations.count == 1 ? (name, declarations[0]) : nil
        }.sorted { $0.name < $1.name }
    }

    private func manifestText(at file: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue <= ProjectRequirementsScanner.maxManifestBytes,
              let data = try? Data(contentsOf: file) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func staticTomlString(_ rawValue: Substring) -> String? {
        let value = tomlLineWithoutComment(String(rawValue))
        guard value.count >= 2, let first = value.first, first == value.last,
              first == "\"" || first == "'" else { return nil }
        let result = String(value.dropFirst().dropLast())
        return result.contains(first) || result.contains("\\") ? nil : result
    }

    private func staticTomlKey(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if isSafeCommandName(value) { return value }
        return staticTomlString(value[value.startIndex...]).flatMap { isSafeCommandName($0) ? $0 : nil }
    }

    private func staticTomlKeyPath(_ rawValue: String) -> [String]? {
        guard let parts = splitStaticToml(rawValue, separator: ".") else { return nil }
        let keys = parts.compactMap(staticTomlKey)
        return keys.count == parts.count ? keys : nil
    }

    private func staticTomlStringArray(_ rawValue: Substring) -> [String]? {
        let value = tomlLineWithoutComment(String(rawValue))
        guard value.first == "[", value.last == "]",
              let parts = splitStaticToml(String(value.dropFirst().dropLast()), separator: ",") else { return nil }
        if parts.count == 1, parts[0].trimmingCharacters(in: .whitespaces).isEmpty { return [] }
        let strings = parts.compactMap { part in
            staticTomlString(part[part.startIndex...])
        }
        return strings.count == parts.count ? strings : nil
    }

    private func staticTomlInlineTable(_ rawValue: Substring) -> [(String, String)]? {
        let value = tomlLineWithoutComment(String(rawValue))
        guard value.first == "{", value.last == "}",
              let parts = splitStaticToml(String(value.dropFirst().dropLast()), separator: ",") else { return nil }
        var entries: [(String, String)] = []
        for part in parts {
            guard let separator = unquotedIndex(of: "=", in: part),
                  let key = staticTomlKey(String(part[..<separator])),
                  staticTomlString(part[part.index(after: separator)...]) != nil else { return nil }
            entries.append((key, String(part[part.index(after: separator)...])))
        }
        return entries
    }

    private func splitStaticToml(_ value: String, separator: Character) -> [String]? {
        var quote: Character?
        var start = value.startIndex
        var parts: [String] = []
        for index in value.indices {
            let character = value[index]
            if character == "\\" { return nil }
            if let currentQuote = quote {
                if character == currentQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == separator {
                parts.append(String(value[start..<index]))
                start = value.index(after: index)
            }
        }
        guard quote == nil else { return nil }
        parts.append(String(value[start...]))
        return parts
    }

    private func unquotedIndex(of needle: Character, in value: String) -> String.Index? {
        var quote: Character?
        for index in value.indices {
            let character = value[index]
            if let currentQuote = quote {
                if character == currentQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == needle {
                return index
            }
        }
        return nil
    }

    private func tomlLineWithoutComment(_ rawValue: String) -> String {
        var quote: Character?
        for index in rawValue.indices {
            let character = rawValue[index]
            if let currentQuote = quote {
                if character == currentQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" {
                return String(rawValue[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isSafeCommandName(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
    }

    private func isSafeCargoFeature(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9_./+:-]*$"#, options: .regularExpression) != nil
    }

    private func isRunScript(_ name: String) -> Bool {
        let lowercased = name.lowercased()
        guard !Self.runScriptBases.contains(lowercased) else { return true }
        let parts = lowercased.split { ":/-".contains($0) || $0 == "." }
        guard parts.count > 1,
              let runIndex = parts.firstIndex(where: { Self.runScriptBases.contains(String($0)) }),
              runIndex == parts.startIndex || runIndex == parts.index(before: parts.endIndex) else { return false }
        return !parts.contains { Self.nonRunScriptBases.contains(String($0)) }
    }

    private func isReadable(_ file: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue <= ProjectRequirementsScanner.maxManifestBytes else { return false }
        return (try? Data(contentsOf: file)) != nil
    }

    private func relativePath(_ file: URL, from root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = file.standardizedFileURL.path
        guard path != rootPath else { return "." }
        return String(path.dropFirst(rootPath.count + 1))
    }
}

struct ProjectRecordDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 4

    let schemaVersion: Int
    var records: [ProjectRecord]
    var ignoredProjects: [IgnoredProject]
    var runConfigurations: [ProjectRunConfiguration]
    var trustedProjectRoots: [String]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, records, ignoredProjects, runConfigurations, trustedProjectRoots
    }

    init(
        records: [ProjectRecord] = [],
        ignoredProjects: [IgnoredProject] = [],
        runConfigurations: [ProjectRunConfiguration] = [],
        trustedProjectRoots: [String] = []
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.records = records
        self.ignoredProjects = ignoredProjects
        self.runConfigurations = runConfigurations
        self.trustedProjectRoots = trustedProjectRoots
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let storedSchemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        schemaVersion = Self.currentSchemaVersion
        records = try values.decode([ProjectRecord].self, forKey: .records)
        ignoredProjects = try values.decode([IgnoredProject].self, forKey: .ignoredProjects)
        runConfigurations = storedSchemaVersion == 1
            ? []
            : try values.decode([ProjectRunConfiguration].self, forKey: .runConfigurations)
        trustedProjectRoots = storedSchemaVersion < 3
            ? []
            : try values.decode([String].self, forKey: .trustedProjectRoots)
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
        runConfigurations.removeAll { projectIDs.contains($0.projectID) }
        trustedProjectRoots.removeAll { projectIDs.contains($0) }
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

enum ProjectRunConfigurationError: LocalizedError {
    case projectNotFound
    case configurationNotFound
    case nameRequired
    case commandRequired
    case workingDirectoryMustBeRelative
    case workingDirectoryOutsideProject
    case workingDirectoryMissing
    case workingDirectoryNotDirectory

    var errorDescription: String? {
        switch self {
        case .projectNotFound: "所属项目记录不存在"
        case .configurationNotFound: "运行配置不存在"
        case .nameRequired: "名称不能为空"
        case .commandRequired: "命令不能为空"
        case .workingDirectoryMustBeRelative: "工作目录必须使用 Project Root 相对路径"
        case .workingDirectoryOutsideProject: "工作目录不能离开 Project Root"
        case .workingDirectoryMissing: "工作目录不存在"
        case .workingDirectoryNotDirectory: "工作目录不是目录"
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
        guard (1 ... ProjectRecordDocument.currentSchemaVersion).contains(header.schemaVersion) else {
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
        "pyproject.toml", "requirements.in", "settings.gradle", "settings.gradle.kts",
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

    func isGitRepository(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        return nearestContainingGitRoot(for: URL(fileURLWithPath: path, isDirectory: true)) != nil
    }

    func currentGitBranch(_ path: String) -> String? {
        guard let root = nearestContainingGitRoot(for: URL(fileURLWithPath: path, isDirectory: true)) else {
            return nil
        }
        let marker = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: marker.path, isDirectory: &isDirectory)
        let gitDirectory: URL
        if isDirectory.boolValue {
            gitDirectory = marker
        } else {
            guard let contents = try? String(contentsOf: marker, encoding: .utf8),
                  contents.hasPrefix("gitdir: ") else { return nil }
            let path = contents.dropFirst("gitdir: ".count).trimmingCharacters(in: .whitespacesAndNewlines)
            gitDirectory = URL(fileURLWithPath: path, relativeTo: marker.deletingLastPathComponent())
                .standardizedFileURL
        }
        guard let head = try? String(contentsOf: gitDirectory.appendingPathComponent("HEAD"), encoding: .utf8),
              head.hasPrefix("ref: refs/heads/") else { return nil }
        return head.dropFirst("ref: refs/heads/".count).trimmingCharacters(in: .whitespacesAndNewlines)
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
    @Published private(set) var suggestionStore: [String: [ProjectRunSuggestion]] = [:]
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

    func runConfigurations(projectID: String? = nil) -> [ProjectRunConfiguration] {
        document.runConfigurations
            .filter { projectID == nil || $0.projectID == projectID }
            .sorted { lhs, rhs in
                let projectOrder = lhs.projectID.localizedStandardCompare(rhs.projectID)
                if projectOrder != .orderedSame { return projectOrder == .orderedAscending }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    func runSuggestions(projectID: String? = nil) -> [ProjectRunSuggestion] {
        let savedSources: Set<String> = Set(document.runConfigurations.compactMap { configuration in
            guard projectID == nil || configuration.projectID == projectID else { return nil }
            return configuration.sourceIdentity.map { "\(configuration.projectID):\($0)" }
        })
        let values = (projectID.map { suggestionStore[$0] ?? [] } ?? suggestionStore.values.flatMap { $0 })
            .filter { !savedSources.contains($0.id) }
        return values.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    func isSuggestionSourceAvailable(_ configuration: ProjectRunConfiguration) -> Bool {
        guard let sourceIdentity = configuration.sourceIdentity else { return true }
        return suggestionStore[configuration.projectID]?.contains { $0.sourceIdentity == sourceIdentity } == true
    }

    func isProjectRunTrusted(_ projectRoot: String) -> Bool {
        document.trustedProjectRoots.contains(projectRoot)
    }

    @discardableResult
    func trustProjectRunRoot(_ projectRoot: String) -> Bool {
        guard !mutationsArePaused else { return false }
        guard !isProjectRunTrusted(projectRoot) else { return true }
        return applyDocumentChange {
            $0.trustedProjectRoots.append(projectRoot)
            $0.trustedProjectRoots.sort()
        }
    }

    @discardableResult
    func adoptSuggestion(_ suggestion: ProjectRunSuggestion) -> ProjectRunConfiguration? {
        guard !document.runConfigurations.contains(where: {
            $0.projectID == suggestion.projectID && $0.sourceIdentity == suggestion.sourceIdentity
        }) else { return nil }
        return createRunConfiguration(
            projectID: suggestion.projectID,
            name: suggestion.name,
            command: suggestion.command,
            workingDirectory: suggestion.workingDirectory,
            sourceIdentity: suggestion.sourceIdentity
        )
    }

    @discardableResult
    func createRunConfiguration(
        projectID: String,
        name: String,
        command: String,
        workingDirectory: String,
        sourceIdentity: String? = nil
    ) -> ProjectRunConfiguration? {
        guard !mutationsArePaused else { return nil }
        do {
            let input = try normalizedRunConfigurationInput(
                projectID: projectID,
                name: name,
                command: command,
                workingDirectory: workingDirectory
            )
            let sourceIdentity = sourceIdentity?.trimmingCharacters(in: .whitespacesAndNewlines)
            let configuration = ProjectRunConfiguration(
                projectID: projectID,
                name: input.name,
                command: input.command,
                workingDirectory: input.workingDirectory,
                sourceIdentity: sourceIdentity?.isEmpty == false ? sourceIdentity : nil
            )
            guard applyDocumentChange({ $0.runConfigurations.append(configuration) }) else { return nil }
            resultMessage = "已创建运行配置“\(configuration.name)”"
            return configuration
        } catch {
            operationError = "运行配置保存失败：\(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func updateRunConfiguration(
        _ configuration: ProjectRunConfiguration,
        name: String,
        command: String,
        workingDirectory: String,
        rememberCommand: Bool = true
    ) -> Bool {
        guard !mutationsArePaused else { return false }
        do {
            guard let index = document.runConfigurations.firstIndex(where: { $0.id == configuration.id }) else {
                throw ProjectRunConfigurationError.configurationNotFound
            }
            let existing = document.runConfigurations[index]
            let input = try normalizedRunConfigurationInput(
                projectID: existing.projectID,
                name: name,
                command: command,
                workingDirectory: workingDirectory,
                existingWorkingDirectory: existing.workingDirectory
            )
            let updated = ProjectRunConfiguration(
                id: existing.id,
                projectID: existing.projectID,
                name: input.name,
                command: rememberCommand ? input.command : existing.command,
                workingDirectory: input.workingDirectory,
                sourceIdentity: existing.sourceIdentity,
                isEnabled: existing.isEnabled
            )
            guard applyDocumentChange({ $0.runConfigurations[index] = updated }) else { return false }
            resultMessage = "已更新运行配置“\(updated.name)”"
            return true
        } catch {
            operationError = "运行配置保存失败：\(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func setRunConfigurationEnabled(_ configuration: ProjectRunConfiguration, isEnabled: Bool) -> Bool {
        guard !mutationsArePaused,
              let index = document.runConfigurations.firstIndex(where: { $0.id == configuration.id }) else {
            return false
        }
        guard document.runConfigurations[index].isEnabled != isEnabled else { return true }
        guard applyDocumentChange({ $0.runConfigurations[index].isEnabled = isEnabled }) else { return false }
        resultMessage = "已\(isEnabled ? "启用" : "禁用")运行配置“\(configuration.name)”"
        return true
    }

    @discardableResult
    func deleteRunConfiguration(_ configuration: ProjectRunConfiguration) -> Bool {
        guard !mutationsArePaused,
              document.runConfigurations.contains(where: { $0.id == configuration.id }) else { return false }
        guard applyDocumentChange({ document in
            document.runConfigurations.removeAll { $0.id == configuration.id }
        }) else { return false }
        resultMessage = "已删除运行配置“\(configuration.name)”"
        return true
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
        let suggestionScanner = ProjectRunSuggestionScanner()
        for (path, analysis) in analyses {
            suggestionStore[path] = suggestionScanner.scan(projectRoot: path, analysis: analysis)
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
    func remove(
        projectIDs: Set<String>,
        afterPersist: () -> Bool = { true }
    ) -> ProjectRemovalSummary? {
        guard !mutationsArePaused, !isScanning else { return nil }
        let previousDocument = document
        let summary = document.remove(projectIDs: projectIDs)
        guard summary.totalCount > 0 else { return summary }
        guard persist() else {
            document = previousDocument
            return nil
        }
        guard afterPersist() else {
            document = previousDocument
            _ = persist()
            return nil
        }
        for projectID in projectIDs {
            displayedNewProjectIDs.remove(projectID)
            analyses.removeValue(forKey: projectID)
            suggestionStore.removeValue(forKey: projectID)
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
            suggestionStore = [:]
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
        if let analysis {
            if analysis.notices.isEmpty {
                analyses[path] = ProjectRequirementsScanner().recalculate(
                    analysis,
                    machineSnapshot: machineSnapshot
                )
                projectNotices.removeValue(forKey: path)
                staleProjectIDs.remove(path)
            } else {
                projectNotices[path] = analysis.notices
                if analyses[path] == nil {
                    analyses[path] = ProjectRequirementsScanner().recalculate(
                        analysis,
                        machineSnapshot: machineSnapshot
                    )
                }
                staleProjectIDs.insert(path)
            }
            suggestionStore[path] = ProjectRunSuggestionScanner().scan(projectRoot: path, analysis: analysis)
        } else if analyses[path] != nil {
            staleProjectIDs.insert(path)
            suggestionStore.removeValue(forKey: path)
        } else {
            suggestionStore[path] = []
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

    private func normalizedRunConfigurationInput(
        projectID: String,
        name: String,
        command: String,
        workingDirectory: String,
        existingWorkingDirectory: String? = nil
    ) throws -> (name: String, command: String, workingDirectory: String) {
        guard let project = document.records.first(where: { $0.id == projectID }) else {
            throw ProjectRunConfigurationError.projectNotFound
        }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProjectRunConfigurationError.nameRequired }
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProjectRunConfigurationError.commandRequired
        }
        let relativePath = try ProjectRunWorkingDirectory.normalize(relativePath: workingDirectory)
        var projectRootIsDirectory: ObjCBool = false
        let projectRootIsAvailable = FileManager.default.fileExists(
            atPath: project.path,
            isDirectory: &projectRootIsDirectory
        ) && projectRootIsDirectory.boolValue
        if relativePath == existingWorkingDirectory, !projectRootIsAvailable {
            return (name, command, relativePath)
        }
        let directory = try ProjectRunWorkingDirectory.resolve(
            projectRoot: project.path,
            relativePath: relativePath
        )
        return (name, command, directory.relativePath)
    }

    private func applyDocumentChange(
        _ change: (inout ProjectRecordDocument) -> Void
    ) -> Bool {
        operationError = nil
        let previousDocument = document
        change(&document)
        guard persist() else {
            document = previousDocument
            return false
        }
        return true
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
