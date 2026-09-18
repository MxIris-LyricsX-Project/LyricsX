// swift-tools-version:6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import Foundation

func envEnable(_ key: String, default defaultValue: Bool = false) -> Bool {
    guard let value = Context.environment[key] else {
        return defaultValue
    }
    if value == "1" {
        return true
    } else if value == "0" {
        return false
    } else {
        return defaultValue
    }
}

let useLocalDependency = envEnable("LYRICSX_USE_LOCAL_DEPENDENCY", default: false)

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
    platforms: [.macOS(.v12)],
    products: [
        .library(
            name: "LyricsXFoundation",
            targets: ["LyricsXFoundation"]
        ),
        .library(
            name: "AppleMusicLyricsPanel",
            targets: ["AppleMusicLyricsPanel"]
        ),
        .library(
            name: "LyricsXWidgetShared",
            targets: ["LyricsXWidgetShared"]
        ),
    ],
    dependencies: [
        .package(
            local: .package(
                path: "../../LyricsKit",
                isRelative: true,
                isEnabled: useLocalDependency
            ),
            remote: .package(
                url: "https://github.com/MxIris-LyricsX-Project/LyricsKit",
                exact: "1.12.0"
            )
        ),
        .package(
            local: .package(
                path: "../../MusicPlayer",
                isRelative: true,
                isEnabled: useLocalDependency
            ),
            remote: .package(
                url: "https://github.com/MxIris-LyricsX-Project/MusicPlayer",
                exact: "1.10.0"
            )
        ),
        .package(
            url: "https://github.com/Mx-Iris/FrameworkToolbox",
            from: "0.12.0"
        ),
        .package(
            url: "https://github.com/Mx-Iris/UIFoundation",
            from: "0.21.0"
        ),
        .package(
            url: "https://github.com/Lakr233/MSDisplayLink",
            from: "2.0.0"
        ),
    ],
    targets: [
        .target(
            name: "LyricsXFoundation",
            dependencies: [
                .product(name: "LyricsKit", package: "LyricsKit"),
                .product(name: "MusicPlayer", package: "MusicPlayer"),
                .product(name: "FoundationToolbox", package: "FrameworkToolbox"),
            ]
        ),
        .target(
            name: "LyricsXWidgetShared",
            dependencies: [
                .product(name: "FoundationToolbox", package: "FrameworkToolbox"),
            ]
        ),
        .target(
            name: "AppleMusicLyricsPanel",
            dependencies: [
                "LyricsXFoundation",
                .product(name: "MusicPlayer", package: "MusicPlayer"),
                .product(name: "OSToolbox", package: "FrameworkToolbox"),
                .product(name: "UIFoundation", package: "UIFoundation"),
                .product(name: "MSDisplayLink", package: "MSDisplayLink"),
            ],
            resources: [
                .process("ArtworkGradientShaders.metal"),
            ],
            swiftSettings: [
                // The sources moved here verbatim from the app target, which
                // builds with SWIFT_VERSION 5 — this keeps them compiling
                // identically instead of also taking on a strict-concurrency
                // migration in the same change.
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "AppleMusicLyricsPanelTests",
            dependencies: [
                "AppleMusicLyricsPanel",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "LyricsXFoundationTests",
            dependencies: [
                "LyricsXFoundation",
            ]
        ),
        .testTarget(
            name: "LyricsXWidgetSharedTests",
            dependencies: ["LyricsXWidgetShared"]
        ),
    ]
)
