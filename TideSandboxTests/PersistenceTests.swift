import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import TideSandbox

@MainActor
final class PersistenceTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs.removeAll(keepingCapacity: true)
    }

    func testFloat32GoldenBytesAndNonSquarePackageOrientationRoundTrip() throws {
        XCTAssertEqual(
            Array(Float32FieldCodec.encodeLittleEndian([0, 1, -2.5, .infinity])),
            [
                0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x80, 0x3f,
                0x00, 0x00, 0x20, 0xc0,
                0x00, 0x00, 0x80, 0x7f,
            ]
        )

        let width = 9
        let height = 8
        let bed = field(width: width, height: height) { column, row in
            Float(row * 100 + column) + 0.25
        }
        let depth = field(width: width, height: height) { column, row in
            Float(1_000 + row * 10 + column) / 1_000
        }
        let packageURL = temporaryDirectory().appendingPathComponent("orientation.waterscene")
        let document = try makeDocument(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            name: "Non-square orientation",
            width: width,
            height: height,
            bed: bed,
            depth: depth
        )
        try ScenePackageCodec.writeAtomically(document, to: packageURL)
        let loaded = try ScenePackageCodec.read(from: packageURL)

        XCTAssertEqual(loaded.manifest, document.manifest)
        XCTAssertEqual(loaded.bedElevation, bed)
        XCTAssertEqual(loaded.initialWaterDepth, depth)
        XCTAssertEqual(loaded.bedElevation[0], 0.25)
        XCTAssertEqual(loaded.bedElevation[width], 100.25)
        XCTAssertEqual(loaded.bedElevation[height * width - 1], 708.25)

        let bedURL = packageURL.appendingPathComponent("bed_elevation.bin")
        let depthURL = packageURL.appendingPathComponent("initial_water_depth.bin")
        XCTAssertEqual(try fileSize(bedURL), width * height * MemoryLayout<Float>.size)
        XCTAssertEqual(try fileSize(depthURL), width * height * MemoryLayout<Float>.size)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: packageURL.appendingPathComponent("velocity.bin").path
        ))
    }

    func testLarge512FieldRemainsOrdinaryBinaryFilesAndRoundTripsExactly() throws {
        let size = 512
        let bed = field(width: size, height: size) { column, row in
            Float(sin(Double(column) * 0.013) + cos(Double(row) * 0.017))
        }
        let depth = bed.map { max(1.5 - $0, 0) }
        let packageURL = temporaryDirectory().appendingPathComponent("large.waterscene")
        let document = try makeDocument(
            id: UUID(),
            name: "Large matrix",
            width: size,
            height: size,
            bed: bed,
            depth: depth
        )

        try ScenePackageCodec.writeAtomically(document, to: packageURL)
        let loaded = try ScenePackageCodec.read(from: packageURL)
        XCTAssertEqual(loaded.bedElevation, bed)
        XCTAssertEqual(loaded.initialWaterDepth, depth)
        XCTAssertEqual(
            try fileSize(packageURL.appendingPathComponent("bed_elevation.bin")),
            size * size * MemoryLayout<Float>.size
        )
        XCTAssertLessThan(
            try fileSize(packageURL.appendingPathComponent("manifest.json")),
            4_096
        )
    }

    func testCorruptionUnsupportedSchemaAndFailedReplacementPreserveGoodPackage() throws {
        let root = temporaryDirectory()
        let packageURL = root.appendingPathComponent("atomic.waterscene")
        let original = try makeDocument(id: UUID(), name: "Original", width: 8, height: 8)
        try ScenePackageCodec.writeAtomically(original, to: packageURL)
        let originalManifestData = try Data(
            contentsOf: packageURL.appendingPathComponent("manifest.json")
        )

        let replacement = try makeDocument(
            id: original.manifest.id,
            name: "Replacement",
            width: 8,
            height: 8,
            bed: [Float](repeating: 0.75, count: 64),
            depth: [Float](repeating: 0.25, count: 64)
        )
        try ScenePackageCodec.writeAtomically(replacement, to: packageURL)
        XCTAssertEqual(try ScenePackageCodec.read(from: packageURL).manifest.name, "Replacement")
        try ScenePackageCodec.writeAtomically(original, to: packageURL)

        let invalid = SceneDocument(
            manifest: original.manifest,
            bedElevation: original.bedElevation,
            initialWaterDepth: original.initialWaterDepth.dropLast().map { $0 },
            previewPNG: original.previewPNG
        )
        XCTAssertThrowsError(try ScenePackageCodec.writeAtomically(invalid, to: packageURL))
        XCTAssertEqual(
            try Data(contentsOf: packageURL.appendingPathComponent("manifest.json")),
            originalManifestData
        )
        XCTAssertEqual(try ScenePackageCodec.read(from: packageURL).manifest.name, "Original")
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .allSatisfy { !$0.contains(".tmp-") }
        )

        let bedURL = packageURL.appendingPathComponent("bed_elevation.bin")
        try Data(repeating: 0, count: 7).write(to: bedURL)
        XCTAssertThrowsError(try ScenePackageCodec.read(from: packageURL)) { error in
            guard case let ScenePackageError.fieldByteCount(resource, expected, actual) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(resource, "bed_elevation.bin")
            XCTAssertEqual(expected, 8 * 8 * MemoryLayout<Float>.size)
            XCTAssertEqual(actual, 7)
        }

        try ScenePackageCodec.writeAtomically(original, to: packageURL)
        let manifestURL = packageURL.appendingPathComponent("manifest.json")
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        json["schemaVersion"] = 999
        try JSONSerialization.data(withJSONObject: json).write(to: manifestURL)
        XCTAssertThrowsError(try ScenePackageCodec.read(from: packageURL)) { error in
            XCTAssertEqual(error as? ScenePackageError, .unsupportedSchema(999))
        }

        try ScenePackageCodec.writeAtomically(original, to: packageURL)
        try Data([137, 80, 78, 71, 13, 10, 26, 10]).write(
            to: packageURL.appendingPathComponent("preview.png")
        )
        XCTAssertThrowsError(try ScenePackageCodec.read(from: packageURL)) { error in
            XCTAssertEqual(error as? ScenePackageError, .invalidPreview)
        }
    }

    func testCatalogRebuildImportCollisionAndRelaunchPersistence() async throws {
        let root = temporaryDirectory()
        let externalRoot = temporaryDirectory()
        let repository = SceneRepository(rootURL: root)
        let first = try makeDocument(id: UUID(), name: "First", width: 8, height: 8)
        let second = try makeDocument(id: UUID(), name: "Second", width: 9, height: 8)
        let savedFirst = try await repository.save(first)
        _ = try await repository.save(second)
        let savedFirstURL = try XCTUnwrap(savedFirst.packageURL)

        let externallyRenamed = renamed(savedFirst, to: "First On Disk")
        try ScenePackageCodec.writeAtomically(externallyRenamed, to: savedFirstURL)
        let authoritativeNames = try await repository.listScenes().map(\.name).sorted()
        XCTAssertEqual(authoritativeNames, ["First On Disk", "Second"])

        try FileManager.default.removeItem(at: root.appendingPathComponent("catalog.json"))
        let relaunched = SceneRepository(rootURL: root)
        let relaunchedNames = try await relaunched.listScenes().map(\.name).sorted()
        XCTAssertEqual(relaunchedNames, ["First On Disk", "Second"])

        try Data("not json".utf8).write(to: root.appendingPathComponent("catalog.json"))
        let rebuiltCatalog = try await relaunched.catalog()
        XCTAssertEqual(rebuiltCatalog.entries.count, 2)

        let externalURL = externalRoot.appendingPathComponent("first.waterscene")
        try ScenePackageCodec.writeAtomically(first, to: externalURL)
        let imported = try await relaunched.importPackage(from: externalURL)
        XCTAssertNotEqual(imported.manifest.id, first.manifest.id)
        XCTAssertEqual(imported.manifest.source, .imported)
        let postImportScenes = try await relaunched.listScenes()
        XCTAssertEqual(postImportScenes.count, 3)

        let secondRelaunch = SceneRepository(rootURL: root)
        let summaries = try await secondRelaunch.listScenes()
        XCTAssertEqual(summaries.count, 3)
        XCTAssertEqual(summaries.filter { $0.source == .imported }.count, 1)
    }

    func testBuiltInIsReadOnlyAndSaveCreatesIndependentUserCopy() async throws {
        let root = temporaryDirectory()
        let builtInRoot = temporaryDirectory()
        let builtInURL = builtInRoot.appendingPathComponent("flat.waterscene")
        let builtIn = try makeDocument(
            id: UUID(),
            name: "Built-in Flat",
            width: 16,
            height: 16,
            source: .builtIn
        )
        try ScenePackageCodec.writeAtomically(builtIn, to: builtInURL)
        let originalManifest = try Data(
            contentsOf: builtInURL.appendingPathComponent("manifest.json")
        )

        let repository = SceneRepository(rootURL: root, builtInPackageURLs: [builtInURL])
        let initialScenes = try await repository.listScenes()
        let summary = try XCTUnwrap(initialScenes.first)
        XCTAssertTrue(summary.isReadOnly)
        let loaded = try await repository.load(summary)
        XCTAssertTrue(loaded.isReadOnly)

        let copy = try await repository.save(loaded, name: "Editable Flat")
        XCTAssertNotEqual(copy.manifest.id, loaded.manifest.id)
        XCTAssertEqual(copy.manifest.source, .user)
        XCTAssertFalse(copy.isReadOnly)
        XCTAssertEqual(
            try Data(contentsOf: builtInURL.appendingPathComponent("manifest.json")),
            originalManifest
        )

        let updated = try await repository.save(copy, name: "Editable Flat Updated")
        XCTAssertEqual(updated.manifest.id, copy.manifest.id)
        XCTAssertEqual(updated.manifest.name, "Editable Flat Updated")
        let duplicated = try await repository.save(
            updated,
            name: "Independent Flat Copy",
            duplicate: true
        )
        XCTAssertNotEqual(duplicated.manifest.id, updated.manifest.id)
        XCTAssertEqual(duplicated.manifest.source, .user)
        let copiedScenes = try await repository.listScenes()
        XCTAssertEqual(copiedScenes.count, 3)
    }

    func testPreviewDimensionsAndVerticalOrientationAreDeterministic() throws {
        let width = 8
        let height = 10
        let depth = field(width: width, height: height) { column, row in
            Float(row * width + column)
        }
        let png = try ScenePreviewRenderer.pngData(
            width: width,
            height: height,
            waterDepth: depth,
            maximumDimension: 5
        )
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 4)
        XCTAssertEqual(image.height, 5)
        let data = try XCTUnwrap(image.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        XCTAssertGreaterThan(bytes[0], bytes[(image.height - 1) * image.bytesPerRow])
    }

    func testBundledScenesAreCompleteReadOnlyPackagesAtEveryRequiredScale() throws {
        let urls = BuiltInSceneResources.packageURLs()
        XCTAssertEqual(urls.count, 4)
        let documents = try urls.map {
            try ScenePackageCodec.read(from: $0, isReadOnly: true)
        }
        XCTAssertEqual(Set(documents.map { $0.manifest.id }).count, 4)
        XCTAssertEqual(documents.map { $0.manifest.gridWidth }.sorted(), [16, 32, 128, 512])
        XCTAssertTrue(documents.allSatisfy { $0.manifest.source == .builtIn && $0.isReadOnly })
        XCTAssertTrue(documents.allSatisfy { $0.previewPNG != nil })
        XCTAssertTrue(documents.contains { $0.manifest.tags.contains("coast") })
        let expectedSeeds = Dictionary(uniqueKeysWithValues: SimulationPreset.allCases.map {
            let seed = $0.makeSeed()
            return (seed.width, seed)
        })
        for document in documents {
            let count = document.manifest.gridWidth * document.manifest.gridHeight
            XCTAssertEqual(document.bedElevation.count, count)
            XCTAssertEqual(document.initialWaterDepth.count, count)
            XCTAssertTrue(document.initialWaterDepth.allSatisfy { $0.isFinite && $0 >= 0 })
            let expectedSeed = try XCTUnwrap(expectedSeeds[document.manifest.gridWidth])
            XCTAssertEqual(document.bedElevation, expectedSeed.bedElevation)
            XCTAssertEqual(document.initialWaterDepth, expectedSeed.waterDepth)
        }
    }

    private func makeDocument(
        id: UUID,
        name: String,
        width: Int,
        height: Int,
        bed: [Float]? = nil,
        depth: [Float]? = nil,
        source: SceneSourceType = .user
    ) throws -> SceneDocument {
        let count = width * height
        let resolvedBed = bed ?? [Float](repeating: 0, count: count)
        let resolvedDepth = depth ?? [Float](repeating: 1, count: count)
        let preview = try ScenePreviewRenderer.pngData(
            width: width,
            height: height,
            waterDepth: resolvedDepth
        )
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let manifest = SceneManifest(
            id: id,
            name: name,
            createdAt: timestamp,
            modifiedAt: timestamp,
            gridWidth: width,
            gridHeight: height,
            domainWidth: Double(width) * 2,
            domainHeight: Double(height) * 3,
            source: source,
            description: "Scientific persistence fixture",
            tags: ["test", "orientation"]
        )
        return SceneDocument(
            manifest: manifest,
            bedElevation: resolvedBed,
            initialWaterDepth: resolvedDepth,
            previewPNG: preview
        )
    }

    private func field(
        width: Int,
        height: Int,
        value: (_ column: Int, _ row: Int) -> Float
    ) -> [Float] {
        (0..<height).flatMap { row in
            (0..<width).map { column in value(column, row) }
        }
    }

    private func renamed(_ document: SceneDocument, to name: String) -> SceneDocument {
        let source = document.manifest
        let manifest = SceneManifest(
            id: source.id,
            name: name,
            createdAt: source.createdAt,
            modifiedAt: source.modifiedAt.addingTimeInterval(1),
            gridWidth: source.gridWidth,
            gridHeight: source.gridHeight,
            domainWidth: source.domainWidth,
            domainHeight: source.domainHeight,
            initializationMode: source.initializationMode,
            solver: source.solver,
            resources: source.resources,
            source: source.source,
            description: source.description,
            tags: source.tags
        )
        return SceneDocument(
            manifest: manifest,
            bedElevation: document.bedElevation,
            initialWaterDepth: document.initialWaterDepth,
            previewPNG: document.previewPNG,
            notesMarkdown: document.notesMarkdown,
            packageURL: document.packageURL,
            isReadOnly: document.isReadOnly
        )
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "WaterSandboxTests-\(UUID().uuidString)",
            isDirectory: true
        )
        temporaryURLs.append(url)
        return url
    }

    private func fileSize(_ url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return try XCTUnwrap(values.fileSize)
    }
}
