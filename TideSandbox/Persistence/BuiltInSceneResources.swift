import Foundation

nonisolated enum BuiltInSceneResources {
    static func packageURLs(in bundle: Bundle = .main) -> [URL] {
        let urls = bundle.urls(
            forResourcesWithExtension: ScenePackageCodec.packageExtension,
            subdirectory: "BuiltInScenes"
        ) ?? []
        return urls.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }
}
