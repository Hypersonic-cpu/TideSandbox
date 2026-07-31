import Foundation
import ImageIO

nonisolated enum SceneInitializationMode: String, Codable, Sendable {
    case explicitDepth
    case levelSurface
}

nonisolated enum SceneSourceType: String, Codable, Sendable {
    case builtIn
    case user
    case imported
}

nonisolated struct SceneSolverParameters: Codable, Equatable, Sendable {
    let gravity: Double
    let linearDamping: Double
    let cflNumber: Double
    let minimumWetDepth: Double
    let workerCount: Int

    static let defaults = SceneSolverParameters(
        gravity: 9.81,
        linearDamping: 0.08,
        cflNumber: 0.3,
        minimumWetDepth: 1.0e-6,
        workerCount: 0
    )

    var isValid: Bool {
        gravity.isFinite && gravity > 0 &&
            linearDamping.isFinite && linearDamping >= 0 &&
            cflNumber.isFinite && cflNumber > 0 && cflNumber <= 1 &&
            minimumWetDepth.isFinite && minimumWetDepth >= 0 &&
            workerCount >= 0
    }
}

nonisolated struct SceneWorldLimits: Codable, Equatable, Sendable {
    let minimumBedElevation: Double
    let maximumSurfaceElevation: Double

    static let defaults = SceneWorldLimits(
        minimumBedElevation: -1_000,
        maximumSurfaceElevation: 1_000
    )

    var isValid: Bool {
        minimumBedElevation.isFinite && maximumSurfaceElevation.isFinite &&
            minimumBedElevation <= maximumSurfaceElevation
    }
}

nonisolated struct SceneResourceNames: Codable, Equatable, Sendable {
    let bedElevation: String
    let initialWaterDepth: String
    let preview: String?
    let notes: String?

    static let standard = SceneResourceNames(
        bedElevation: "bed_elevation.bin",
        initialWaterDepth: "initial_water_depth.bin",
        preview: "preview.png",
        notes: nil
    )

    var allNames: [String] {
        [bedElevation, initialWaterDepth] + [preview, notes].compactMap { $0 }
    }
}

nonisolated struct SceneManifest: Codable, Equatable, Identifiable, Sendable {
    static let currentSchemaVersion = 1
    static let byteOrder = "little-endian"
    static let scalarType = "float32"
    static let rowOrder = "row-major-bottom-to-top"

    let schemaVersion: Int
    let id: UUID
    let name: String
    let createdAt: Date
    let modifiedAt: Date
    let gridWidth: Int
    let gridHeight: Int
    let domainWidth: Double
    let domainHeight: Double
    let initializationMode: SceneInitializationMode
    let solver: SceneSolverParameters
    let worldLimits: SceneWorldLimits?
    let resources: SceneResourceNames
    let source: SceneSourceType
    let description: String?
    let tags: [String]
    let storedByteOrder: String
    let storedScalarType: String
    let storedRowOrder: String

    init(
        schemaVersion: Int = SceneManifest.currentSchemaVersion,
        id: UUID,
        name: String,
        createdAt: Date,
        modifiedAt: Date,
        gridWidth: Int,
        gridHeight: Int,
        domainWidth: Double,
        domainHeight: Double,
        initializationMode: SceneInitializationMode = .explicitDepth,
        solver: SceneSolverParameters = .defaults,
        worldLimits: SceneWorldLimits = .defaults,
        resources: SceneResourceNames = .standard,
        source: SceneSourceType,
        description: String? = nil,
        tags: [String] = [],
        storedByteOrder: String = SceneManifest.byteOrder,
        storedScalarType: String = SceneManifest.scalarType,
        storedRowOrder: String = SceneManifest.rowOrder
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.gridWidth = gridWidth
        self.gridHeight = gridHeight
        self.domainWidth = domainWidth
        self.domainHeight = domainHeight
        self.initializationMode = initializationMode
        self.solver = solver
        self.worldLimits = worldLimits
        self.resources = resources
        self.source = source
        self.description = description
        self.tags = tags
        self.storedByteOrder = storedByteOrder
        self.storedScalarType = storedScalarType
        self.storedRowOrder = storedRowOrder
    }

    var cellCount: Int? {
        guard gridWidth > 0, gridHeight > 0,
              gridWidth <= Int.max / gridHeight else { return nil }
        return gridWidth * gridHeight
    }

    var resolvedWorldLimits: SceneWorldLimits { worldLimits ?? .defaults }
}

nonisolated struct SceneDocument: Sendable {
    let manifest: SceneManifest
    let bedElevation: [Float]
    let initialWaterDepth: [Float]
    let previewPNG: Data?
    let notesMarkdown: String?
    let packageURL: URL?
    let isReadOnly: Bool

    init(
        manifest: SceneManifest,
        bedElevation: [Float],
        initialWaterDepth: [Float],
        previewPNG: Data? = nil,
        notesMarkdown: String? = nil,
        packageURL: URL? = nil,
        isReadOnly: Bool = false
    ) {
        self.manifest = manifest
        self.bedElevation = bedElevation
        self.initialWaterDepth = initialWaterDepth
        self.previewPNG = previewPNG
        self.notesMarkdown = notesMarkdown
        self.packageURL = packageURL
        self.isReadOnly = isReadOnly
    }

}

nonisolated enum ScenePackageError: Error, Equatable, LocalizedError, Sendable {
    case packageNotDirectory
    case missingResource(String)
    case invalidManifest(String)
    case unsupportedSchema(Int)
    case unsupportedEncoding(String)
    case invalidDimensions
    case invalidPhysicalDimensions
    case invalidSolverParameters
    case unsafeResourceName(String)
    case symbolicLinkResource(String)
    case fieldByteCount(resource: String, expected: Int, actual: Int)
    case nonFiniteField(resource: String, index: Int)
    case negativeWaterDepth(index: Int)
    case fieldOutsideWorldLimits(index: Int)
    case invalidPreview
    case catalogCorrupt(String)
    case sceneNotFound(UUID)
    case fileSystem(String)

    var errorDescription: String? {
        switch self {
        case .packageNotDirectory:
            "The selected .waterscene item is not a directory."
        case let .missingResource(name):
            "The scene is missing required resource ‘\(name)’."
        case let .invalidManifest(reason):
            "The scene manifest is invalid: \(reason)"
        case let .unsupportedSchema(version):
            "Scene schema version \(version) is not supported."
        case let .unsupportedEncoding(detail):
            "The scene field encoding is unsupported: \(detail)."
        case .invalidDimensions:
            "The scene grid dimensions are invalid or too large."
        case .invalidPhysicalDimensions:
            "The scene physical dimensions must be finite and positive."
        case .invalidSolverParameters:
            "The scene solver parameters are invalid."
        case let .unsafeResourceName(name):
            "The scene resource name ‘\(name)’ is unsafe."
        case let .symbolicLinkResource(name):
            "The scene resource ‘\(name)’ may not be a symbolic link."
        case let .fieldByteCount(resource, expected, actual):
            "The field ‘\(resource)’ has \(actual) bytes; expected \(expected)."
        case let .nonFiniteField(resource, index):
            "The field ‘\(resource)’ contains a non-finite value at cell \(index)."
        case let .negativeWaterDepth(index):
            "Initial water depth is negative at cell \(index)."
        case let .fieldOutsideWorldLimits(index):
            "The bed or water surface at cell \(index) is outside the scene world limits."
        case .invalidPreview:
            "The scene preview is not valid PNG data."
        case let .catalogCorrupt(reason):
            "The scene catalog is corrupt: \(reason)"
        case let .sceneNotFound(id):
            "Scene \(id.uuidString) could not be found."
        case let .fileSystem(reason):
            "The scene could not be stored: \(reason)"
        }
    }
}

nonisolated enum Float32FieldCodec {
    static let bytesPerValue = MemoryLayout<UInt32>.size

    static func encodeLittleEndian(_ values: [Float]) -> Data {
        var data = Data(capacity: values.count * bytesPerValue)
        for value in values {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func decodeLittleEndian(
        _ data: Data,
        count: Int,
        resourceName: String
    ) throws -> [Float] {
        guard count >= 0, count <= Int.max / bytesPerValue else {
            throw ScenePackageError.invalidDimensions
        }
        let expected = count * bytesPerValue
        guard data.count == expected else {
            throw ScenePackageError.fieldByteCount(
                resource: resourceName,
                expected: expected,
                actual: data.count
            )
        }
        return data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            var result = [Float]()
            result.reserveCapacity(count)
            for index in 0..<count {
                let offset = index * bytesPerValue
                let bits = UInt32(bytes[offset]) |
                    UInt32(bytes[offset + 1]) << 8 |
                    UInt32(bytes[offset + 2]) << 16 |
                    UInt32(bytes[offset + 3]) << 24
                result.append(Float(bitPattern: bits))
            }
            return result
        }
    }
}

nonisolated enum ScenePackageCodec {
    static let packageExtension = "waterscene"
    static let manifestFilename = "manifest.json"
    static let maximumCellCount = 16_777_216

    static func read(
        from packageURL: URL,
        isReadOnly: Bool = false,
        fileManager: FileManager = .default
    ) throws -> SceneDocument {
        let values = try packageURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ScenePackageError.packageNotDirectory
        }
        let manifestURL = packageURL.appendingPathComponent(manifestFilename, isDirectory: false)
        let manifestData = try requiredData(
            at: manifestURL,
            resourceName: manifestFilename,
            fileManager: fileManager
        )
        let manifest: SceneManifest
        do {
            manifest = try decoder.decode(SceneManifest.self, from: manifestData)
        } catch {
            throw ScenePackageError.invalidManifest(error.localizedDescription)
        }
        try validate(manifest: manifest)
        guard let count = manifest.cellCount else { throw ScenePackageError.invalidDimensions }

        let bedData = try requiredData(
            in: packageURL,
            named: manifest.resources.bedElevation,
            fileManager: fileManager
        )
        let depthData = try requiredData(
            in: packageURL,
            named: manifest.resources.initialWaterDepth,
            fileManager: fileManager
        )
        let bed = try Float32FieldCodec.decodeLittleEndian(
            bedData,
            count: count,
            resourceName: manifest.resources.bedElevation
        )
        let depth = try Float32FieldCodec.decodeLittleEndian(
            depthData,
            count: count,
            resourceName: manifest.resources.initialWaterDepth
        )
        try validateFields(bedElevation: bed, waterDepth: depth, manifest: manifest)

        let preview = try manifest.resources.preview.map {
            try requiredData(in: packageURL, named: $0, fileManager: fileManager)
        }
        if let preview {
            try validatePreview(preview)
        }
        let notes = try manifest.resources.notes.map { filename in
            let data = try requiredData(in: packageURL, named: filename, fileManager: fileManager)
            guard let text = String(data: data, encoding: .utf8) else {
                throw ScenePackageError.invalidManifest("notes are not UTF-8")
            }
            return text
        }
        return SceneDocument(
            manifest: manifest,
            bedElevation: bed,
            initialWaterDepth: depth,
            previewPNG: preview,
            notesMarkdown: notes,
            packageURL: packageURL,
            isReadOnly: isReadOnly
        )
    }

    static func writeAtomically(
        _ document: SceneDocument,
        to packageURL: URL,
        fileManager: FileManager = .default
    ) throws {
        try validate(document: document)
        let parentURL = packageURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        let temporaryURL = parentURL.appendingPathComponent(
            ".\(packageURL.lastPathComponent).tmp-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(at: temporaryURL, withIntermediateDirectories: false)
            let manifestData = try encoder.encode(document.manifest)
            try manifestData.write(
                to: temporaryURL.appendingPathComponent(manifestFilename),
                options: .atomic
            )
            try Float32FieldCodec.encodeLittleEndian(document.bedElevation).write(
                to: temporaryURL.appendingPathComponent(document.manifest.resources.bedElevation),
                options: .atomic
            )
            try Float32FieldCodec.encodeLittleEndian(document.initialWaterDepth).write(
                to: temporaryURL.appendingPathComponent(document.manifest.resources.initialWaterDepth),
                options: .atomic
            )
            if let previewName = document.manifest.resources.preview,
               let preview = document.previewPNG {
                try preview.write(to: temporaryURL.appendingPathComponent(previewName), options: .atomic)
            }
            if let notesName = document.manifest.resources.notes,
               let notes = document.notesMarkdown,
               let notesData = notes.data(using: .utf8) {
                try notesData.write(to: temporaryURL.appendingPathComponent(notesName), options: .atomic)
            }

            _ = try read(from: temporaryURL, fileManager: fileManager)
            if fileManager.fileExists(atPath: packageURL.path) {
                _ = try fileManager.replaceItemAt(
                    packageURL,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fileManager.moveItem(at: temporaryURL, to: packageURL)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            if let packageError = error as? ScenePackageError { throw packageError }
            throw ScenePackageError.fileSystem(error.localizedDescription)
        }
    }

    static func manifestData(_ manifest: SceneManifest) throws -> Data {
        try validate(manifest: manifest)
        return try encoder.encode(manifest)
    }

    static func validate(document: SceneDocument) throws {
        try validate(manifest: document.manifest)
        try validateFields(
            bedElevation: document.bedElevation,
            waterDepth: document.initialWaterDepth,
            manifest: document.manifest
        )
        if document.manifest.resources.preview != nil {
            guard let preview = document.previewPNG else {
                throw ScenePackageError.invalidPreview
            }
            try validatePreview(preview)
        }
        if document.manifest.resources.notes != nil, document.notesMarkdown == nil {
            throw ScenePackageError.missingResource(document.manifest.resources.notes ?? "notes")
        }
    }

    static func validate(manifest: SceneManifest) throws {
        guard manifest.schemaVersion == SceneManifest.currentSchemaVersion else {
            throw ScenePackageError.unsupportedSchema(manifest.schemaVersion)
        }
        let trimmedName = manifest.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.count <= 200 else {
            throw ScenePackageError.invalidManifest("name must contain 1–200 non-whitespace characters")
        }
        guard let count = manifest.cellCount,
              manifest.gridWidth >= 8,
              manifest.gridHeight >= 8,
              count <= maximumCellCount,
              count <= Int.max / Float32FieldCodec.bytesPerValue else {
            throw ScenePackageError.invalidDimensions
        }
        guard manifest.domainWidth.isFinite, manifest.domainWidth > 0,
              manifest.domainHeight.isFinite, manifest.domainHeight > 0 else {
            throw ScenePackageError.invalidPhysicalDimensions
        }
        guard manifest.solver.isValid else { throw ScenePackageError.invalidSolverParameters }
        guard manifest.resolvedWorldLimits.isValid else {
            throw ScenePackageError.invalidManifest("world limits are invalid")
        }
        guard manifest.storedByteOrder == SceneManifest.byteOrder,
              manifest.storedScalarType == SceneManifest.scalarType,
              manifest.storedRowOrder == SceneManifest.rowOrder else {
            throw ScenePackageError.unsupportedEncoding(
                "\(manifest.storedByteOrder), \(manifest.storedScalarType), \(manifest.storedRowOrder)"
            )
        }
        guard Set(manifest.resources.allNames).count == manifest.resources.allNames.count else {
            throw ScenePackageError.invalidManifest("resource filenames must be unique")
        }
        for filename in manifest.resources.allNames {
            guard isSafeResourceName(filename) else {
                throw ScenePackageError.unsafeResourceName(filename)
            }
        }
        guard manifest.tags.count <= 32,
              manifest.tags.allSatisfy({ !$0.isEmpty && $0.count <= 64 }) else {
            throw ScenePackageError.invalidManifest("tags exceed the supported count or length")
        }
    }

    private static let pngSignature = Data([137, 80, 78, 71, 13, 10, 26, 10])

    private static func validatePreview(_ data: Data) throws {
        guard data.starts(with: pngSignature),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            throw ScenePackageError.invalidPreview
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func validateFields(
        bedElevation: [Float],
        waterDepth: [Float],
        manifest: SceneManifest
    ) throws {
        guard let count = manifest.cellCount else { throw ScenePackageError.invalidDimensions }
        guard bedElevation.count == count else {
            throw ScenePackageError.fieldByteCount(
                resource: manifest.resources.bedElevation,
                expected: count * Float32FieldCodec.bytesPerValue,
                actual: bedElevation.count * Float32FieldCodec.bytesPerValue
            )
        }
        guard waterDepth.count == count else {
            throw ScenePackageError.fieldByteCount(
                resource: manifest.resources.initialWaterDepth,
                expected: count * Float32FieldCodec.bytesPerValue,
                actual: waterDepth.count * Float32FieldCodec.bytesPerValue
            )
        }
        for (index, value) in bedElevation.enumerated() where !value.isFinite {
            throw ScenePackageError.nonFiniteField(resource: manifest.resources.bedElevation, index: index)
        }
        for (index, value) in waterDepth.enumerated() {
            guard value.isFinite else {
                throw ScenePackageError.nonFiniteField(
                    resource: manifest.resources.initialWaterDepth,
                    index: index
                )
            }
            guard value >= 0 else { throw ScenePackageError.negativeWaterDepth(index: index) }
            let bed = Double(bedElevation[index])
            let depth = Double(value)
            let limits = manifest.resolvedWorldLimits
            guard bed >= limits.minimumBedElevation,
                  bed + depth <= limits.maximumSurfaceElevation else {
                throw ScenePackageError.fieldOutsideWorldLimits(index: index)
            }
        }
    }

    private static func isSafeResourceName(_ filename: String) -> Bool {
        !filename.isEmpty && filename.count <= 128 &&
            filename != "." && filename != ".." &&
            !filename.contains("/") && !filename.contains(":") &&
            !filename.hasPrefix(".")
    }

    private static func requiredData(
        in packageURL: URL,
        named filename: String,
        fileManager: FileManager
    ) throws -> Data {
        guard isSafeResourceName(filename) else {
            throw ScenePackageError.unsafeResourceName(filename)
        }
        return try requiredData(
            at: packageURL.appendingPathComponent(filename, isDirectory: false),
            resourceName: filename,
            fileManager: fileManager
        )
    }

    private static func requiredData(
        at url: URL,
        resourceName: String,
        fileManager: FileManager
    ) throws -> Data {
        guard fileManager.fileExists(atPath: url.path) else {
            throw ScenePackageError.missingResource(resourceName)
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw ScenePackageError.symbolicLinkResource(resourceName)
        }
        guard values.isRegularFile == true else {
            throw ScenePackageError.missingResource(resourceName)
        }
        do {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw ScenePackageError.fileSystem(error.localizedDescription)
        }
    }
}
