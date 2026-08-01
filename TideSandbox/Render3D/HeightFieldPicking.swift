import CoreGraphics
import simd

struct HeightFieldPickRay: Sendable, Equatable {
    let origin: SIMD3<Float>
    let direction: SIMD3<Float>
}

struct HeightFieldPickContext: Sendable {
    let width: Int
    let height: Int
    let domainWidth: Float
    let domainHeight: Float
    let bedElevation: [Float]
    let waterDepth: [Float]
    let verticalScale: Float
    let renderBias: Float
    let minimumWetDepth: Float

    init?(
        snapshot: SimulationSnapshot,
        verticalScale: Float,
        renderBias: Float,
        minimumWetDepth: Float
    ) {
        guard snapshot.width >= 2,
              snapshot.height >= 2,
              snapshot.bedElevation.count == snapshot.width * snapshot.height,
              snapshot.waterDepth.count == snapshot.width * snapshot.height,
              snapshot.domainWidth.isFinite,
              snapshot.domainWidth > 0,
              snapshot.domainHeight.isFinite,
              snapshot.domainHeight > 0,
              verticalScale.isFinite,
              verticalScale > 0,
              renderBias.isFinite,
              minimumWetDepth.isFinite,
              minimumWetDepth >= 0 else { return nil }
        self.width = snapshot.width
        self.height = snapshot.height
        domainWidth = Float(snapshot.domainWidth)
        domainHeight = Float(snapshot.domainHeight)
        bedElevation = snapshot.bedElevation
        waterDepth = snapshot.waterDepth
        self.verticalScale = verticalScale
        self.renderBias = renderBias
        self.minimumWetDepth = minimumWetDepth
    }

    var cellWidth: Float { domainWidth / Float(width) }
    var cellHeight: Float { domainHeight / Float(height) }
    var minimumX: Float { -domainWidth * 0.5 + cellWidth * 0.5 }
    var maximumX: Float { domainWidth * 0.5 - cellWidth * 0.5 }
    var minimumZ: Float { -domainHeight * 0.5 + cellHeight * 0.5 }
    var maximumZ: Float { domainHeight * 0.5 - cellHeight * 0.5 }

    func physicalPoint(for ray: HeightFieldPickRay) -> CGPoint? {
        guard ray.origin.x.isFinite, ray.origin.y.isFinite, ray.origin.z.isFinite,
              ray.direction.x.isFinite, ray.direction.y.isFinite, ray.direction.z.isFinite,
              simd_length_squared(ray.direction) > Float.leastNonzeroMagnitude,
              let interval = horizontalInterval(ray: ray) else { return nil }
        let epsilon: Float = 1.0e-5
        let start = max(interval.lowerBound, 0)
        let end = interval.upperBound
        guard end >= start else { return nil }
        let initial = ray.origin + ray.direction * min(start + epsilon, end)
        var column = min(max(Int((initial.x - minimumX) / cellWidth), 0), width - 2)
        var row = min(max(Int((initial.z - minimumZ) / cellHeight), 0), height - 2)
        let stepX = ray.direction.x > 0 ? 1 : (ray.direction.x < 0 ? -1 : 0)
        let stepZ = ray.direction.z > 0 ? 1 : (ray.direction.z < 0 ? -1 : 0)
        let nextBoundaryX = stepX > 0
            ? minimumX + Float(column + 1) * cellWidth
            : minimumX + Float(column) * cellWidth
        let nextBoundaryZ = stepZ > 0
            ? minimumZ + Float(row + 1) * cellHeight
            : minimumZ + Float(row) * cellHeight
        var nextX = stepX == 0 ? Float.infinity : (nextBoundaryX - ray.origin.x) / ray.direction.x
        var nextZ = stepZ == 0 ? Float.infinity : (nextBoundaryZ - ray.origin.z) / ray.direction.z
        let deltaX = stepX == 0 ? Float.infinity : abs(cellWidth / ray.direction.x)
        let deltaZ = stepZ == 0 ? Float.infinity : abs(cellHeight / ray.direction.z)
        var entry = start

        while column >= 0, column < width - 1, row >= 0, row < height - 1, entry <= end {
            let exit = min(nextX, nextZ, end)
            if let worldPoint = nearestSurfaceHit(
                ray: ray,
                column: column,
                row: row,
                minimumDistance: entry - epsilon,
                maximumDistance: exit + epsilon
            ) {
                return CGPoint(
                    x: CGFloat(min(max(worldPoint.x + domainWidth * 0.5, 0), domainWidth)),
                    y: CGFloat(min(max(worldPoint.z + domainHeight * 0.5, 0), domainHeight))
                )
            }
            if nextX < nextZ {
                column += stepX
                entry = nextX
                nextX += deltaX
            } else {
                row += stepZ
                entry = nextZ
                nextZ += deltaZ
            }
        }
        return nil
    }

    private func horizontalInterval(ray: HeightFieldPickRay) -> ClosedRange<Float>? {
        var lower = -Float.infinity
        var upper = Float.infinity
        for (origin, direction, minimum, maximum) in [
            (ray.origin.x, ray.direction.x, minimumX, maximumX),
            (ray.origin.z, ray.direction.z, minimumZ, maximumZ),
        ] {
            if abs(direction) <= Float.leastNonzeroMagnitude {
                guard origin >= minimum, origin <= maximum else { return nil }
                continue
            }
            let first = (minimum - origin) / direction
            let second = (maximum - origin) / direction
            lower = max(lower, min(first, second))
            upper = min(upper, max(first, second))
        }
        return lower <= upper ? lower...upper : nil
    }

    private func nearestSurfaceHit(
        ray: HeightFieldPickRay,
        column: Int,
        row: Int,
        minimumDistance: Float,
        maximumDistance: Float
    ) -> SIMD3<Float>? {
        let indices = [
            row * width + column,
            (row + 1) * width + column,
            row * width + column + 1,
            (row + 1) * width + column + 1,
        ]
        guard indices.allSatisfy({
            bedElevation[$0].isFinite && waterDepth[$0].isFinite
        }) else { return nil }
        let terrain = indices.map { terrainVertex(index: $0) }
        var candidates = [Float]()
        appendTerrainTriangleHits(
            ray: ray, vertices: terrain, minimumDistance: minimumDistance,
            maximumDistance: maximumDistance, into: &candidates
        )
        if indices.contains(where: { waterDepth[$0] > minimumWetDepth }) {
            let water = indices.map { waterVertex(index: $0) }
            appendWaterTriangleHits(
                ray: ray,
                vertices: water,
                depths: indices.map { max(waterDepth[$0], 0) },
                minimumDistance: minimumDistance,
                maximumDistance: maximumDistance,
                into: &candidates
            )
        }
        guard let distance = candidates.min() else { return nil }
        return ray.origin + ray.direction * distance
    }

    private func appendTerrainTriangleHits(
        ray: HeightFieldPickRay,
        vertices: [SIMD3<Float>],
        minimumDistance: Float,
        maximumDistance: Float,
        into candidates: inout [Float]
    ) {
        guard vertices.count == 4 else { return }
        for triangle in [(0, 1, 2), (2, 1, 3)] {
            guard let hit = Self.rayTriangleHit(
                ray: ray,
                first: vertices[triangle.0],
                second: vertices[triangle.1],
                third: vertices[triangle.2]
            ), hit.distance >= minimumDistance,
               hit.distance <= maximumDistance else { continue }
            candidates.append(hit.distance)
        }
    }

    private func appendWaterTriangleHits(
        ray: HeightFieldPickRay,
        vertices: [SIMD3<Float>],
        depths: [Float],
        minimumDistance: Float,
        maximumDistance: Float,
        into candidates: inout [Float]
    ) {
        guard vertices.count == 4, depths.count == 4 else { return }
        for triangle in [(0, 1, 2), (2, 1, 3)] {
            guard let hit = Self.rayTriangleHit(
                ray: ray,
                first: vertices[triangle.0],
                second: vertices[triangle.1],
                third: vertices[triangle.2]
            ), hit.distance >= minimumDistance,
               hit.distance <= maximumDistance else { continue }
            let firstWeight = 1 - hit.secondWeight - hit.thirdWeight
            let interpolatedDepth = firstWeight * depths[triangle.0] +
                hit.secondWeight * depths[triangle.1] +
                hit.thirdWeight * depths[triangle.2]
            if interpolatedDepth > minimumWetDepth {
                candidates.append(hit.distance)
            }
        }
    }

    private func terrainVertex(index: Int) -> SIMD3<Float> {
        vertex(index: index, elevation: bedElevation[index])
    }

    private func waterVertex(index: Int) -> SIMD3<Float> {
        vertex(index: index, elevation: bedElevation[index] + max(waterDepth[index], 0),
               bias: renderBias)
    }

    private func vertex(index: Int, elevation: Float, bias: Float = 0) -> SIMD3<Float> {
        let column = index % width
        let row = index / width
        return SIMD3<Float>(
            minimumX + Float(column) * cellWidth,
            elevation * verticalScale + bias,
            minimumZ + Float(row) * cellHeight
        )
    }

    private struct TriangleHit {
        let distance: Float
        let secondWeight: Float
        let thirdWeight: Float
    }

    private static func rayTriangleHit(
        ray: HeightFieldPickRay,
        first: SIMD3<Float>,
        second: SIMD3<Float>,
        third: SIMD3<Float>
    ) -> TriangleHit? {
        let epsilon: Float = 1.0e-6
        let firstEdge = second - first
        let secondEdge = third - first
        let perpendicular = simd_cross(ray.direction, secondEdge)
        let determinant = simd_dot(firstEdge, perpendicular)
        guard abs(determinant) > epsilon else { return nil }
        let inverseDeterminant = 1 / determinant
        let originOffset = ray.origin - first
        let u = simd_dot(originOffset, perpendicular) * inverseDeterminant
        guard u >= -epsilon, u <= 1 + epsilon else { return nil }
        let q = simd_cross(originOffset, firstEdge)
        let v = simd_dot(ray.direction, q) * inverseDeterminant
        guard v >= -epsilon, u + v <= 1 + epsilon else { return nil }
        let distance = simd_dot(secondEdge, q) * inverseDeterminant
        guard distance >= 0 else { return nil }
        return TriangleHit(
            distance: distance,
            secondWeight: u,
            thirdWeight: v
        )
    }
}

enum HeightFieldPicker {
    static func ray(
        at point: CGPoint,
        drawableSize: CGSize,
        viewProjection: simd_float4x4
    ) -> HeightFieldPickRay? {
        guard point.x.isFinite, point.y.isFinite,
              drawableSize.width.isFinite, drawableSize.height.isFinite,
              drawableSize.width > 0, drawableSize.height > 0 else { return nil }
        let x = Float(point.x / drawableSize.width * 2 - 1)
        let y = Float(point.y / drawableSize.height * 2 - 1)
        let inverse = simd_inverse(viewProjection)
        let near = inverse * SIMD4<Float>(x, y, 0, 1)
        let far = inverse * SIMD4<Float>(x, y, 1, 1)
        guard near.w.isFinite, far.w.isFinite,
              abs(near.w) > Float.leastNonzeroMagnitude,
              abs(far.w) > Float.leastNonzeroMagnitude else { return nil }
        let origin = SIMD3<Float>(near.x, near.y, near.z) / near.w
        let endpoint = SIMD3<Float>(far.x, far.y, far.z) / far.w
        let direction = endpoint - origin
        guard origin.x.isFinite, origin.y.isFinite, origin.z.isFinite,
              direction.x.isFinite, direction.y.isFinite, direction.z.isFinite,
              simd_length_squared(direction) > Float.leastNonzeroMagnitude else { return nil }
        return HeightFieldPickRay(origin: origin, direction: simd_normalize(direction))
    }

    static func physicalPoint(
        at point: CGPoint,
        drawableSize: CGSize,
        viewProjection: simd_float4x4,
        context: HeightFieldPickContext
    ) -> CGPoint? {
        guard let ray = ray(at: point, drawableSize: drawableSize,
                            viewProjection: viewProjection) else { return nil }
        return context.physicalPoint(for: ray)
    }
}
