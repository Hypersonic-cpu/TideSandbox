import Foundation

nonisolated struct SceneSummary: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let modifiedAt: Date
    let gridWidth: Int
    let gridHeight: Int
    let source: SceneSourceType
    let tags: [String]
    let description: String?
    let previewResource: String?
    let packageLocation: String
    let isReadOnly: Bool

    init(document: SceneDocument, packageLocation: String, isReadOnly: Bool) {
        id = document.manifest.id
        name = document.manifest.name
        modifiedAt = document.manifest.modifiedAt
        gridWidth = document.manifest.gridWidth
        gridHeight = document.manifest.gridHeight
        source = document.manifest.source
        tags = document.manifest.tags
        description = document.manifest.description
        previewResource = document.manifest.resources.preview
        self.packageLocation = packageLocation
        self.isReadOnly = isReadOnly
    }
}

nonisolated struct SceneCatalog: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let generatedAt: Date
    let entries: [SceneSummary]
}

actor SceneRepository {
    let rootURL: URL
    let scenesURL: URL
    let catalogURL: URL

    private let fileManager: FileManager
    private let builtInPackageURLs: [URL]

    init(
        rootURL: URL,
        builtInPackageURLs: [URL] = [],
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        scenesURL = rootURL.appendingPathComponent("Scenes", isDirectory: true)
        catalogURL = rootURL.appendingPathComponent("catalog.json", isDirectory: false)
        self.builtInPackageURLs = builtInPackageURLs
        self.fileManager = fileManager
    }

    nonisolated static func applicationSupport(
        builtInPackageURLs: [URL] = [],
        fileManager: FileManager = .default
    ) throws -> SceneRepository {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return SceneRepository(
            rootURL: support.appendingPathComponent("TideSandbox", isDirectory: true),
            builtInPackageURLs: builtInPackageURLs,
            fileManager: fileManager
        )
    }

    func listScenes() throws -> [SceneSummary] {
        try ensureStorageDirectories()
        let builtIns = try builtInPackageURLs.map { url in
            let document = try ScenePackageCodec.read(from: url, isReadOnly: true, fileManager: fileManager)
            return SceneSummary(document: document, packageLocation: url.path, isReadOnly: true)
        }
        let catalog = try loadOrRebuildCatalog()
        return (builtIns + catalog.entries).sorted {
            if $0.source == .builtIn, $1.source != .builtIn { return true }
            if $0.source != .builtIn, $1.source == .builtIn { return false }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func load(_ summary: SceneSummary) throws -> SceneDocument {
        let url = try resolvedPackageURL(for: summary)
        guard fileManager.fileExists(atPath: url.path) else {
            throw ScenePackageError.sceneNotFound(summary.id)
        }
        return try ScenePackageCodec.read(
            from: url,
            isReadOnly: summary.isReadOnly,
            fileManager: fileManager
        )
    }

    func previewData(for summary: SceneSummary) throws -> Data? {
        guard let filename = summary.previewResource else { return nil }
        guard !filename.isEmpty,
              filename == URL(fileURLWithPath: filename).lastPathComponent,
              !filename.hasPrefix(".") else {
            throw ScenePackageError.unsafeResourceName(filename)
        }
        let packageURL = try resolvedPackageURL(for: summary)
        let previewURL = packageURL.appendingPathComponent(filename, isDirectory: false)
        guard fileManager.fileExists(atPath: previewURL.path) else {
            throw ScenePackageError.missingResource(filename)
        }
        let values = try previewURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ScenePackageError.symbolicLinkResource(filename)
        }
        return try Data(contentsOf: previewURL, options: .mappedIfSafe)
    }

    @discardableResult
    func save(
        _ document: SceneDocument,
        name: String? = nil,
        duplicate: Bool = false,
        now: Date = Date()
    ) throws -> SceneDocument {
        try ensureStorageDirectories()
        let mustCopy = duplicate || document.isReadOnly || document.manifest.source == .builtIn
        let id = mustCopy ? UUID() : document.manifest.id
        let trimmedName = (name ?? document.manifest.name)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let manifest = SceneManifest(
            id: id,
            name: trimmedName,
            createdAt: mustCopy ? now : document.manifest.createdAt,
            modifiedAt: now,
            gridWidth: document.manifest.gridWidth,
            gridHeight: document.manifest.gridHeight,
            domainWidth: document.manifest.domainWidth,
            domainHeight: document.manifest.domainHeight,
            initializationMode: document.manifest.initializationMode,
            solver: document.manifest.solver,
            resources: document.manifest.resources,
            source: .user,
            description: document.manifest.description,
            tags: document.manifest.tags
        )
        let destination = packageURL(for: id)
        let stored = SceneDocument(
            manifest: manifest,
            bedElevation: document.bedElevation,
            initialWaterDepth: document.initialWaterDepth,
            previewPNG: document.previewPNG,
            notesMarkdown: document.notesMarkdown,
            packageURL: destination,
            isReadOnly: false
        )
        try ScenePackageCodec.writeAtomically(stored, to: destination, fileManager: fileManager)
        _ = try rebuildCatalog()
        return try ScenePackageCodec.read(from: destination, fileManager: fileManager)
    }

    @discardableResult
    func importPackage(from sourceURL: URL, now: Date = Date()) throws -> SceneDocument {
        try ensureStorageDirectories()
        let imported = try ScenePackageCodec.read(from: sourceURL, fileManager: fileManager)
        let existingIDs = try Set(listScenes().map(\.id))
        let id = existingIDs.contains(imported.manifest.id) ? UUID() : imported.manifest.id
        let manifest = SceneManifest(
            id: id,
            name: imported.manifest.name,
            createdAt: imported.manifest.createdAt,
            modifiedAt: now,
            gridWidth: imported.manifest.gridWidth,
            gridHeight: imported.manifest.gridHeight,
            domainWidth: imported.manifest.domainWidth,
            domainHeight: imported.manifest.domainHeight,
            initializationMode: imported.manifest.initializationMode,
            solver: imported.manifest.solver,
            resources: imported.manifest.resources,
            source: .imported,
            description: imported.manifest.description,
            tags: imported.manifest.tags
        )
        let destination = packageURL(for: id)
        let stored = SceneDocument(
            manifest: manifest,
            bedElevation: imported.bedElevation,
            initialWaterDepth: imported.initialWaterDepth,
            previewPNG: imported.previewPNG,
            notesMarkdown: imported.notesMarkdown,
            packageURL: destination,
            isReadOnly: false
        )
        try ScenePackageCodec.writeAtomically(stored, to: destination, fileManager: fileManager)
        _ = try rebuildCatalog()
        return try ScenePackageCodec.read(from: destination, fileManager: fileManager)
    }

    @discardableResult
    func rebuildCatalog(now: Date = Date()) throws -> SceneCatalog {
        try ensureStorageDirectories()
        let packageURLs = try fileManager.contentsOfDirectory(
            at: scenesURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var entries = [SceneSummary]()
        for url in packageURLs where url.pathExtension == ScenePackageCodec.packageExtension {
            guard let document = try? ScenePackageCodec.read(from: url, fileManager: fileManager) else {
                continue
            }
            entries.append(SceneSummary(
                document: document,
                packageLocation: url.lastPathComponent,
                isReadOnly: false
            ))
        }
        entries.sort {
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        let catalog = SceneCatalog(
            schemaVersion: SceneCatalog.currentSchemaVersion,
            generatedAt: now,
            entries: entries
        )
        do {
            try catalogEncoder.encode(catalog).write(to: catalogURL, options: .atomic)
        } catch {
            throw ScenePackageError.fileSystem(error.localizedDescription)
        }
        return catalog
    }

    func catalog() throws -> SceneCatalog {
        try ensureStorageDirectories()
        return try loadOrRebuildCatalog()
    }

    private func loadOrRebuildCatalog() throws -> SceneCatalog {
        guard fileManager.fileExists(atPath: catalogURL.path) else {
            return try rebuildCatalog()
        }
        do {
            let data = try Data(contentsOf: catalogURL)
            let catalog = try catalogDecoder.decode(SceneCatalog.self, from: data)
            guard catalog.schemaVersion == SceneCatalog.currentSchemaVersion,
                  catalog.entries.allSatisfy({ !$0.isReadOnly && isSafePackageLocation($0.packageLocation) }) else {
                return try rebuildCatalog()
            }
            for entry in catalog.entries {
                let url = scenesURL.appendingPathComponent(entry.packageLocation, isDirectory: true)
                guard fileManager.fileExists(atPath: url.path),
                      let document = try? ScenePackageCodec.read(from: url, fileManager: fileManager),
                      SceneSummary(
                        document: document,
                        packageLocation: entry.packageLocation,
                        isReadOnly: false
                      ) == entry else {
                    return try rebuildCatalog()
                }
            }
            return catalog
        } catch {
            return try rebuildCatalog()
        }
    }

    private func ensureStorageDirectories() throws {
        do {
            try fileManager.createDirectory(at: scenesURL, withIntermediateDirectories: true)
        } catch {
            throw ScenePackageError.fileSystem(error.localizedDescription)
        }
    }

    private func packageURL(for id: UUID) -> URL {
        scenesURL.appendingPathComponent(
            "\(id.uuidString.lowercased()).\(ScenePackageCodec.packageExtension)",
            isDirectory: true
        )
    }

    private func resolvedPackageURL(for summary: SceneSummary) throws -> URL {
        if summary.isReadOnly {
            return URL(fileURLWithPath: summary.packageLocation, isDirectory: true)
        }
        guard isSafePackageLocation(summary.packageLocation) else {
            throw ScenePackageError.catalogCorrupt("unsafe package location")
        }
        return scenesURL.appendingPathComponent(summary.packageLocation, isDirectory: true)
    }

    private func isSafePackageLocation(_ location: String) -> Bool {
        !location.isEmpty && location == URL(fileURLWithPath: location).lastPathComponent &&
            !location.hasPrefix(".") &&
            URL(fileURLWithPath: location).pathExtension == ScenePackageCodec.packageExtension
    }

    private let catalogEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private let catalogDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
