import Foundation

@main
struct GenerateBuiltInScenes {
    private struct Specification {
        let preset: SimulationPreset
        let id: UUID
        let filename: String
        let description: String
        let tags: [String]
    }

    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 2 else {
            throw GeneratorError.usage
        }
        let outputRoot = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let timestamp = Date(timeIntervalSince1970: 1_785_510_000)
        let specifications = [
            Specification(
                preset: .flat16,
                id: UUID(uuidString: "10000000-0000-4000-8000-000000000016")!,
                filename: "Flat16.waterscene",
                description: "A still level lake over a flat bed for small-grid inspection.",
                tags: ["built-in", "flat", "debug"]
            ),
            Specification(
                preset: .centerBump32,
                id: UUID(uuidString: "10000000-0000-4000-8000-000000000032")!,
                filename: "CenterBump32.waterscene",
                description: "A level lake over a smooth centered Gaussian bed bump.",
                tags: ["built-in", "bump", "debug"]
            ),
            Specification(
                preset: .unevenBed128,
                id: UUID(uuidString: "10000000-0000-4000-8000-000000000128")!,
                filename: "UnevenBed128.waterscene",
                description: "A level lake over multi-frequency uneven terrain.",
                tags: ["built-in", "uneven", "medium"]
            ),
            Specification(
                preset: .coastChannel512,
                id: UUID(uuidString: "10000000-0000-4000-8000-000000000512")!,
                filename: "CoastChannel512.waterscene",
                description: "A tidal-bore/tsunami-like initial surface-step stress visualization over exposed coastal terrain.",
                tags: ["built-in", "coast", "channel", "initial-step", "large"]
            ),
            Specification(
                preset: .drivenOceanWave512,
                id: UUID(uuidString: "10000000-0000-4000-8000-000000000513")!,
                filename: "DrivenOceanWave512.waterscene",
                description: "A continuously driven right-boundary ocean-wave stress visualization over exposed coastal terrain.",
                tags: ["built-in", "coast", "driven-boundary", "wave", "large"]
            ),
        ]

        for specification in specifications {
            let seed = specification.preset.makeSeed()
            let preview = try ScenePreviewRenderer.pngData(
                width: seed.width,
                height: seed.height,
                waterDepth: seed.waterDepth
            )
            let manifest = SceneManifest(
                id: specification.id,
                name: specification.preset.title,
                createdAt: timestamp,
                modifiedAt: timestamp,
                gridWidth: seed.width,
                gridHeight: seed.height,
                domainWidth: seed.domainWidth,
                domainHeight: seed.domainHeight,
                initializationMode: .explicitDepth,
                solver: .defaults,
                worldLimits: seed.worldLimits,
                boundaries: seed.boundaries,
                source: .builtIn,
                description: specification.description,
                tags: specification.tags
            )
            let document = SceneDocument(
                manifest: manifest,
                bedElevation: seed.bedElevation,
                initialWaterDepth: seed.waterDepth,
                previewPNG: preview,
                isReadOnly: true
            )
            try ScenePackageCodec.writeAtomically(
                document,
                to: outputRoot.appendingPathComponent(specification.filename, isDirectory: true)
            )
        }
    }

    private enum GeneratorError: LocalizedError {
        case usage

        var errorDescription: String? {
            "Usage: GenerateBuiltInScenes <output-directory>"
        }
    }
}
