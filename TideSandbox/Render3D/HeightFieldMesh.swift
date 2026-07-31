import Foundation
import simd

enum HeightFieldMeshError: Error, Equatable {
    case dimensionsTooSmall
    case dimensionOverflow
    case indexRangeOverflow
}

struct HeightFieldMesh: Sendable {
    let width: Int
    let height: Int
    let indices: [UInt32]

    init(width: Int, height: Int) throws {
        let counts = try Self.validatedCounts(width: width, height: height)

        self.width = width
        self.height = height
        var indices = [UInt32]()
        indices.reserveCapacity(counts.indexCount)
        for row in 0..<(height - 1) {
            for column in 0..<(width - 1) {
                let a = UInt32(row * width + column)
                let b = a + 1
                let c = a + UInt32(width)
                let d = c + 1
                indices.append(a)
                indices.append(c)
                indices.append(b)
                indices.append(b)
                indices.append(c)
                indices.append(d)
            }
        }
        self.indices = indices
    }

    static func validatedCounts(
        width: Int,
        height: Int
    ) throws -> (vertexCount: Int, indexCount: Int) {
        guard width >= 2, height >= 2 else {
            throw HeightFieldMeshError.dimensionsTooSmall
        }
        let (vertexCount, vertexOverflow) = width.multipliedReportingOverflow(by: height)
        let (quadCount, quadOverflow) = (width - 1).multipliedReportingOverflow(
            by: height - 1
        )
        let (indexCount, indexOverflow) = quadCount.multipliedReportingOverflow(by: 6)
        guard !vertexOverflow, !quadOverflow, !indexOverflow else {
            throw HeightFieldMeshError.dimensionOverflow
        }
        guard vertexCount <= Int(UInt32.max) else {
            throw HeightFieldMeshError.indexRangeOverflow
        }
        return (vertexCount, indexCount)
    }

    var vertexCount: Int { width * height }
    var indexCount: Int { indices.count }

    static func worldPosition(
        column: Int,
        row: Int,
        width: Int,
        height: Int,
        domainWidth: Float,
        domainHeight: Float,
        elevation: Float,
        verticalScale: Float
    ) -> SIMD3<Float>? {
        guard width > 0, height > 0,
              column >= 0, column < width,
              row >= 0, row < height,
              domainWidth.isFinite, domainWidth > 0,
              domainHeight.isFinite, domainHeight > 0,
              elevation.isFinite, verticalScale.isFinite else {
            return nil
        }
        let cellWidth = domainWidth / Float(width)
        let cellHeight = domainHeight / Float(height)
        return SIMD3<Float>(
            (Float(column) + 0.5) * cellWidth - domainWidth * 0.5,
            elevation * verticalScale,
            (Float(row) + 0.5) * cellHeight - domainHeight * 0.5
        )
    }
}

struct HeightFieldResourceTracker: Sendable, Equatable {
    private(set) var width = 0
    private(set) var height = 0
    private(set) var rebuildCount = 0

    mutating func register(width: Int, height: Int) throws -> Bool {
        _ = try HeightFieldMesh.validatedCounts(width: width, height: height)
        guard self.width != width || self.height != height else { return false }
        self.width = width
        self.height = height
        rebuildCount += 1
        return true
    }
}

enum HeightFieldScalar {
    static func surfaceElevation(bedElevation: Float, waterDepth: Float) -> Float {
        bedElevation + max(waterDepth, 0)
    }

    static func isWet(waterDepth: Float, minimumWetDepth: Float) -> Bool {
        waterDepth > minimumWetDepth
    }
}
