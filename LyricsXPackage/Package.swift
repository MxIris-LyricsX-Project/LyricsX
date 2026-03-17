// swift-tools-version:6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import Foundation

extension Package.Dependency {
    enum LocalSearchPath {
        case package(path: String, isRelative: Bool, isEnabled: Bool)
    }

    static func package(local localSearchPaths: LocalSearchPath..., remote: Package.Dependency) -> Package.Dependency {
        let currentFilePath = #filePath
        let isClonedDependency = currentFilePath.contains("/checkouts/") ||
            currentFilePath.contains("/SourcePackages/") ||
            currentFilePath.contains("/.build/")

        if isClonedDependency {
            return remote
        }
        for local in localSearchPaths {
            switch local {
            case .package(let path, let isRelative, let isEnabled):
                guard isEnabled else { continue }
                let url = if isRelative {
                    URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: #filePath))
                } else {
                    URL(fileURLWithPath: path)
                }

                if FileManager.default.fileExists(atPath: url.path) {
                    return .package(path: url.path)
                }
            }
        }
        return remote
    }
}

let package = Package(
    name: "LyricsXPackage",
    platforms: [.macOS(.v11)],
    products: [
        .library(
            name: "LyricsXFoundation",
            targets: ["LyricsXFoundation"]
        ),
    ],
    dependencies: [
        .package(
            local: .package(
                path: "../../LyricsKit",
                isRelative: true,
                isEnabled: false
            ),
            remote: .package(
                url: "https://github.com/MxIris-LyricsX-Project/LyricsKit",
                from: "1.8.0"
            )
        ),
        .package(
            local: .package(
                path: "../../MusicPlayer",
                isRelative: true,
                isEnabled: false
            ),
            remote: .package(
                url: "https://github.com/MxIris-LyricsX-Project/MusicPlayer",
                from: "1.8.0"
            )
        ),
    ],
    targets: [
        .target(
            name: "LyricsXFoundation",
            dependencies: [
                .product(name: "LyricsKit", package: "LyricsKit"),
                .product(name: "MusicPlayer", package: "MusicPlayer"),
            ]
        ),
        .testTarget(
            name: "LyricsXFoundationTests",
            dependencies: [
                "LyricsXFoundation"
            ]
        ),
    ]
)

