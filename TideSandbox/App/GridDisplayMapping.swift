import CoreGraphics

struct GridCell: Equatable, Sendable {
    let column: Int
    let row: Int
}

struct GridDisplayMapping: Equatable, Sendable {
    let gridWidth: Int
    let gridHeight: Int
    let viewSize: CGSize
    let tileSize: CGFloat
    let contentFrame: CGRect

    init?(gridWidth: Int, gridHeight: Int, viewSize: CGSize) {
        guard gridWidth > 0, gridHeight > 0, viewSize.width > 0, viewSize.height > 0 else {
            return nil
        }
        let tileSize = min(
            viewSize.width / CGFloat(gridWidth),
            viewSize.height / CGFloat(gridHeight)
        )
        let contentSize = CGSize(
            width: tileSize * CGFloat(gridWidth),
            height: tileSize * CGFloat(gridHeight)
        )
        self.gridWidth = gridWidth
        self.gridHeight = gridHeight
        self.viewSize = viewSize
        self.tileSize = tileSize
        contentFrame = CGRect(
            x: (viewSize.width - contentSize.width) * 0.5,
            y: (viewSize.height - contentSize.height) * 0.5,
            width: contentSize.width,
            height: contentSize.height
        )
    }

    func cell(at point: CGPoint) -> GridCell? {
        guard point.x >= contentFrame.minX, point.x < contentFrame.maxX,
              point.y >= contentFrame.minY, point.y < contentFrame.maxY else {
            return nil
        }
        let column = Int((point.x - contentFrame.minX) / tileSize)
        let displayRow = Int((point.y - contentFrame.minY) / tileSize)
        return GridCell(column: column, row: gridHeight - displayRow - 1)
    }

    func tileRect(column: Int, row: Int) -> CGRect? {
        guard column >= 0, column < gridWidth, row >= 0, row < gridHeight else { return nil }
        let displayRow = gridHeight - row - 1
        return CGRect(
            x: contentFrame.minX + CGFloat(column) * tileSize,
            y: contentFrame.minY + CGFloat(displayRow) * tileSize,
            width: tileSize,
            height: tileSize
        )
    }

    func physicalPoint(
        at viewPoint: CGPoint,
        domainWidth: Double,
        domainHeight: Double
    ) -> CGPoint? {
        guard cell(at: viewPoint) != nil else { return nil }
        let normalizedX = (viewPoint.x - contentFrame.minX) / contentFrame.width
        let normalizedY = 1 - (viewPoint.y - contentFrame.minY) / contentFrame.height
        return CGPoint(
            x: CGFloat(Double(normalizedX) * domainWidth),
            y: CGFloat(Double(normalizedY) * domainHeight)
        )
    }

    func viewPoint(
        forPhysicalPoint point: CGPoint,
        domainWidth: Double,
        domainHeight: Double
    ) -> CGPoint {
        CGPoint(
            x: contentFrame.minX + point.x / CGFloat(domainWidth) * contentFrame.width,
            y: contentFrame.maxY - point.y / CGFloat(domainHeight) * contentFrame.height
        )
    }
}
