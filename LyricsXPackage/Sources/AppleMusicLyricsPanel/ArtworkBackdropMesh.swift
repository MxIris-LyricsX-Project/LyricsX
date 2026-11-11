import Foundation
import simd

extension AppleMusicLyrics {
    struct ArtworkBackdropMeshVertex {
        let clipSpacePosition: SIMD2<Float>
        let destinationClipSpacePosition: SIMD2<Float>
        let textureCoordinate: SIMD2<Float>
    }

    struct ArtworkBackdropMeshTopology {
        let baseControlPointCount: Int
        let subdivisionLevel: Int

        init(baseControlPointCount: Int, subdivisionLevel: Int) {
            self.baseControlPointCount = max(2, baseControlPointCount)
            self.subdivisionLevel = min(8, max(0, subdivisionLevel))
        }

        var vertexCountPerDimension: Int {
            segmentCountPerDimension + 1
        }

        var vertexCount: Int {
            vertexCountPerDimension * vertexCountPerDimension
        }

        var indexCount: Int {
            segmentCountPerDimension * segmentCountPerDimension * 6
        }

        /// Vertices for the five-segment presets `TSLBackdropMetalView` uses;
        /// any other base grid falls back to an unwarped identity surface.
        func makeVertices(meshVariant: Int = 1) -> [ArtworkBackdropMeshVertex] {
            let controlPoints = if baseControlPointCount == 6 {
                ArtworkBackdropMeshPresets.controlPoints(variant: meshVariant)
            } else {
                identityControlPoints()
            }
            return makeVertices(
                sourceControlPoints: controlPoints.source,
                destinationControlPoints: controlPoints.destination
            )
        }

        /// Refines explicit source and destination control surfaces. Both
        /// arrays hold `baseControlPointCount²` unit-square points in row-major
        /// order; positions land in clip space as `2 × point − 1` while the
        /// texture coordinate stays the regular grid position.
        func makeVertices(
            sourceControlPoints: [SIMD2<Float>],
            destinationControlPoints: [SIMD2<Float>]
        ) -> [ArtworkBackdropMeshVertex] {
            let expectedControlPointCount = baseControlPointCount * baseControlPointCount
            precondition(
                sourceControlPoints.count == expectedControlPointCount
                    && destinationControlPoints.count == expectedControlPointCount,
                "Control surfaces must hold baseControlPointCount² points"
            )
            let vertexCountPerDimension = vertexCountPerDimension
            let segmentCountPerDimension = segmentCountPerDimension
            var controlPoints = (source: sourceControlPoints, destination: destinationControlPoints)
            var currentControlPointCount = baseControlPointCount
            for _ in 0 ..< subdivisionLevel {
                controlPoints.source = Self.subdivide(
                    controlPoints.source,
                    pointCountPerDimension: currentControlPointCount
                )
                controlPoints.destination = Self.subdivide(
                    controlPoints.destination,
                    pointCountPerDimension: currentControlPointCount
                )
                currentControlPointCount = currentControlPointCount * 2 - 1
            }
            return (0 ..< vertexCountPerDimension).flatMap { verticalVertexIndex in
                let verticalFraction = Float(verticalVertexIndex)
                    / Float(segmentCountPerDimension)
                return (0 ..< vertexCountPerDimension).map { horizontalVertexIndex in
                    let horizontalFraction = Float(horizontalVertexIndex)
                        / Float(segmentCountPerDimension)
                    let vertexIndex = verticalVertexIndex * vertexCountPerDimension
                        + horizontalVertexIndex
                    return ArtworkBackdropMeshVertex(
                        clipSpacePosition: controlPoints.source[vertexIndex] * 2 - 1,
                        destinationClipSpacePosition: controlPoints.destination[vertexIndex] * 2 - 1,
                        textureCoordinate: SIMD2(
                            horizontalFraction,
                            verticalFraction
                        )
                    )
                }
            }
        }

        private func identityControlPoints() -> (
            source: [SIMD2<Float>],
            destination: [SIMD2<Float>]
        ) {
            let points = (0 ..< baseControlPointCount * baseControlPointCount).map { pointIndex in
                SIMD2<Float>(
                    Float(pointIndex % baseControlPointCount) / Float(baseControlPointCount - 1),
                    Float(pointIndex / baseControlPointCount) / Float(baseControlPointCount - 1)
                )
            }
            return (points, points)
        }

        /// Regular-grid Catmull-Clark subdivision. Boundary curves use the
        /// same cubic refinement while the four corners remain fixed.
        private static func subdivide(
            _ points: [SIMD2<Float>],
            pointCountPerDimension: Int
        ) -> [SIMD2<Float>] {
            let refinedPointCount = pointCountPerDimension * 2 - 1
            var horizontalPoints = [SIMD2<Float>]()
            horizontalPoints.reserveCapacity(refinedPointCount * pointCountPerDimension)
            for rowIndex in 0 ..< pointCountPerDimension {
                let rowStartIndex = rowIndex * pointCountPerDimension
                let row = Array(points[rowStartIndex ..< rowStartIndex + pointCountPerDimension])
                horizontalPoints.append(contentsOf: subdivideCurve(row))
            }

            var refinedPoints = [SIMD2<Float>](repeating: .zero, count: refinedPointCount * refinedPointCount)
            for columnIndex in 0 ..< refinedPointCount {
                let column = (0 ..< pointCountPerDimension).map { rowIndex in
                    horizontalPoints[rowIndex * refinedPointCount + columnIndex]
                }
                let refinedColumn = subdivideCurve(column)
                for rowIndex in 0 ..< refinedPointCount {
                    refinedPoints[rowIndex * refinedPointCount + columnIndex] = refinedColumn[rowIndex]
                }
            }
            return refinedPoints
        }

        private static func subdivideCurve(_ points: [SIMD2<Float>]) -> [SIMD2<Float>] {
            var refinedPoints = [SIMD2<Float>]()
            refinedPoints.reserveCapacity(points.count * 2 - 1)
            for pointIndex in points.indices {
                if pointIndex == 0 || pointIndex == points.count - 1 {
                    refinedPoints.append(points[pointIndex])
                } else {
                    refinedPoints.append(
                        (points[pointIndex - 1] + points[pointIndex] * 6 + points[pointIndex + 1]) / 8
                    )
                }
                if pointIndex + 1 < points.count {
                    refinedPoints.append((points[pointIndex] + points[pointIndex + 1]) / 2)
                }
            }
            return refinedPoints
        }

        func makeIndices() -> [UInt32] {
            let vertexCountPerDimension = vertexCountPerDimension
            var indices = [UInt32]()
            indices.reserveCapacity(indexCount)

            for verticalSegmentIndex in 0 ..< segmentCountPerDimension {
                for horizontalSegmentIndex in 0 ..< segmentCountPerDimension {
                    let topLeftVertexIndex = UInt32(
                        verticalSegmentIndex * vertexCountPerDimension
                            + horizontalSegmentIndex
                    )
                    let topRightVertexIndex = topLeftVertexIndex + 1
                    let bottomLeftVertexIndex = topLeftVertexIndex
                        + UInt32(vertexCountPerDimension)
                    let bottomRightVertexIndex = bottomLeftVertexIndex + 1
                    indices.append(contentsOf: [
                        topLeftVertexIndex,
                        bottomLeftVertexIndex,
                        topRightVertexIndex,
                        topRightVertexIndex,
                        bottomLeftVertexIndex,
                        bottomRightVertexIndex,
                    ])
                }
            }
            return indices
        }

        private var segmentCountPerDimension: Int {
            (baseControlPointCount - 1) * (1 << subdivisionLevel)
        }
    }
}
