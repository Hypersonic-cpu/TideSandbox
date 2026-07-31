import AppKit
import Combine
import Foundation

@MainActor
final class SceneLibrary: ObservableObject {
    @Published private(set) var scenes: [SceneSummary] = []
    @Published private(set) var previews: [UUID: NSImage] = [:]
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?

    private let repository: SceneRepository
    private var activeOperationCount = 0

    init(repository: SceneRepository? = nil) {
        if let repository {
            self.repository = repository
        } else {
            do {
                self.repository = try Self.makeDefaultRepository()
            } catch {
                let fallback = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "WaterSandbox-Recovery",
                    isDirectory: true
                )
                self.repository = SceneRepository(
                    rootURL: fallback,
                    builtInPackageURLs: BuiltInSceneResources.packageURLs()
                )
                errorMessage = error.localizedDescription
            }
        }
        reload()
    }

    private static func makeDefaultRepository() throws -> SceneRepository {
        let fileManager = FileManager.default
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        var root = support.appendingPathComponent("WaterSandbox", isDirectory: true)
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let namespace = environment["WATER_SANDBOX_STORAGE_NAMESPACE"],
           !namespace.isEmpty,
           namespace.count <= 64,
           namespace.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) {
            root = root
                .appendingPathComponent("UITestStorage", isDirectory: true)
                .appendingPathComponent(namespace, isDirectory: true)
            if ProcessInfo.processInfo.arguments.contains("--reset-scene-storage") {
                try? fileManager.removeItem(at: root)
            }
        }
#endif
        return SceneRepository(
            rootURL: root,
            builtInPackageURLs: BuiltInSceneResources.packageURLs(),
            fileManager: fileManager
        )
    }

    func reload() {
        Task {
            await perform { [self] in
                let summaries = try await repository.listScenes()
                var loadedPreviews = [UUID: NSImage]()
                for summary in summaries {
                    if let data = try await repository.previewData(for: summary),
                       let image = NSImage(data: data) {
                        loadedPreviews[summary.id] = image
                    }
                }
                scenes = summaries
                previews = loadedPreviews
            }
        }
    }

    func open(_ summary: SceneSummary, in model: SimulationViewModel) async -> Bool {
        await perform { [self] in
            let document = try await repository.load(summary)
            model.requestLoadScene(document)
        }
    }

    func save(
        model: SimulationViewModel,
        name: String,
        duplicate: Bool
    ) async -> Bool {
        await perform { [self] in
            let document = try model.persistenceDocument(named: name)
            let saved = try await repository.save(document, name: name, duplicate: duplicate)
            model.acceptSavedScene(saved)
            let summaries = try await repository.listScenes()
            scenes = summaries
            if let data = try await repository.previewData(for: try summary(for: saved, in: summaries)),
               let image = NSImage(data: data) {
                previews[saved.manifest.id] = image
            }
        }
    }

    func importPackage(from url: URL) async -> SceneSummary? {
        var result: SceneSummary?
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        let succeeded = await perform { [self] in
            let imported = try await repository.importPackage(from: url)
            let summaries = try await repository.listScenes()
            scenes = summaries
            result = try summary(for: imported, in: summaries)
            if let result,
               let data = try await repository.previewData(for: result),
               let image = NSImage(data: data) {
                previews[result.id] = image
            }
        }
        return succeeded ? result : nil
    }

    private func summary(
        for document: SceneDocument,
        in summaries: [SceneSummary]
    ) throws -> SceneSummary {
        guard let summary = summaries.first(where: { $0.id == document.manifest.id }) else {
            throw ScenePackageError.sceneNotFound(document.manifest.id)
        }
        return summary
    }

    @discardableResult
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) async -> Bool {
        activeOperationCount += 1
        isBusy = true
        defer {
            activeOperationCount -= 1
            isBusy = activeOperationCount > 0
        }
        do {
            try await operation()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
