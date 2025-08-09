// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import Foundation

extension Package.Dependency {
    static func package(path: String, isRelative: Bool, alternative: Package.Dependency) -> Package.Dependency {
        let url = if isRelative, let resolvedURL = URL(string: path, relativeTo: URL(fileURLWithPath: #filePath)) {
            resolvedURL
        } else {
            URL(fileURLWithPath: path)
        }

        if FileManager.default.fileExists(atPath: url.path) {
            return .package(path: url.path)
        } else {
            return alternative
        }
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
        .package(path: "../../../Library/LyricsKit", isRelative: true, alternative: .package(url: "https://github.com/MxIris-LyricsX-Project/LyricsKit", branch: "main")),
    ],
    targets: [
        .target(
            name: "LyricsXFoundation",
            dependencies: [
                .product(name: "LyricsKit", package: "LyricsKit"),
            ]
        ),
        .testTarget(
            name: "LyricsXFoundationTests",
            dependencies: ["LyricsXFoundation"]
        ),
    ]
)

