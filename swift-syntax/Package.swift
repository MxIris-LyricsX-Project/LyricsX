// swift-tools-version: 5.9

import PackageDescription

let tag = "603.0.1"

let package = Package(
    name: "swift-syntax",
    platforms: [
        .iOS(.v13),
        .macCatalyst(.v13),
        .macOS(.v10_15),
        .tvOS(.v13),
        .watchOS(.v6),
    ],
    products: [
        .library(name: "SwiftBasicFormat", targets: ["SwiftBasicFormat_Aggregation"]),
        .library(name: "SwiftCompilerPlugin", targets: ["SwiftCompilerPlugin_Aggregation"]),
        .library(name: "SwiftDiagnostics", targets: ["SwiftDiagnostics_Aggregation"]),
        .library(name: "SwiftIDEUtils", targets: ["SwiftIDEUtils_Aggregation"]),
        .library(name: "SwiftIfConfig", targets: ["SwiftIfConfig_Aggregation"]),
        .library(name: "SwiftLexicalLookup", targets: ["SwiftLexicalLookup_Aggregation"]),
        .library(name: "SwiftOperators", targets: ["SwiftOperators_Aggregation"]),
        .library(name: "SwiftParser", targets: ["SwiftParser_Aggregation"]),
        .library(name: "SwiftParserDiagnostics", targets: ["SwiftParserDiagnostics_Aggregation"]),
        .library(name: "SwiftRefactor", targets: ["SwiftRefactor_Aggregation"]),
        .library(name: "SwiftSyntax", targets: ["SwiftSyntax_Aggregation"]),
        .library(name: "SwiftSyntaxBuilder", targets: ["SwiftSyntaxBuilder_Aggregation"]),
        .library(name: "SwiftSyntaxMacros", targets: ["SwiftSyntaxMacros_Aggregation"]),
        .library(name: "SwiftSyntaxMacroExpansion", targets: ["SwiftSyntaxMacroExpansion_Aggregation"]),
        .library(name: "SwiftSyntaxMacrosTestSupport", targets: ["SwiftSyntaxMacrosTestSupport_Aggregation"]),
        .library(name: "SwiftSyntaxMacrosGenericTestSupport", targets: ["SwiftSyntaxMacrosGenericTestSupport_Aggregation"]),
        .library(name: "SwiftWarningControl", targets: ["SwiftWarningControl_Aggregation"]),
        .library(name: "_SwiftCompilerPluginMessageHandling", targets: ["SwiftCompilerPluginMessageHandling_Aggregation"]),
        .library(name: "_SwiftLibraryPluginProvider", targets: ["SwiftLibraryPluginProvider_Aggregation"]),
    ],
    targets: [
        // MARK: - SwiftBasicFormat
        .target(
            name: "SwiftBasicFormat_Aggregation",
            dependencies: [
                .target(name: "SwiftBasicFormat"),
                "SwiftSyntax_Aggregation",
            ]
        ),
        .binaryTarget(
            name: "SwiftBasicFormat",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/603.0.1/SwiftBasicFormat.xcframework.zip",
            checksum: "c618343f8fa52d0e5b7e105c399ebdb1614fe9bfc0b00e979f1899cec016013a"
        ),

        // MARK: - SwiftCompilerPlugin
        .target(
            name: "SwiftCompilerPlugin_Aggregation",
            dependencies: [
                .target(name: "SwiftCompilerPlugin"),
                "SwiftCompilerPluginMessageHandling_Aggregation",
                "SwiftSyntaxMacros_Aggregation",
            ]
        ),
        .binaryTarget(
            name: "SwiftCompilerPlugin",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/603.0.1/SwiftCompilerPlugin.xcframework.zip",
            checksum: "b111ca056c11148cd35f8c1db7cf811c39a6c1bbe0098f986241f13a15232363"
        ),

        // MARK: - SwiftDiagnostics
        .target(
            name: "SwiftDiagnostics_Aggregation",
            dependencies: [
                .target(name: "SwiftDiagnostics"),
                "SwiftSyntax_Aggregation",
            ]
        ),
        .binaryTarget(
            name: "SwiftDiagnostics",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/603.0.1/SwiftDiagnostics.xcframework.zip",
            checksum: "bf3e38730511d9b7d575f274eae7376c75da3740d26013fd81db531fb4a41bf5"
        ),

        // MARK: - SwiftIDEUtils
        .target(
            name: "SwiftIDEUtils_Aggregation",
            dependencies: [
                .target(name: "SwiftIDEUtils"),
                "SwiftSyntax_Aggregation",
                "SwiftDiagnostics_Aggregation",
                "SwiftParser_Aggregation",
            ]
        ),
        .binaryTarget(
            name: "SwiftIDEUtils",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/603.0.1/SwiftIDEUtils.xcframework.zip",
            checksum: "9292b83bf44352d41ab44897d4320354d63c4415dd407104dbf84e8d71e9c2bb"
        ),

        // MARK: - SwiftIfConfig
        .target(
            name: "SwiftIfConfig_Aggregation",
            dependencies: [
                .target(name: "SwiftIfConfig"),
                "SwiftSyntax_Aggregation",
                "SwiftSyntaxBuilder_Aggregation",
                "SwiftDiagnostics_Aggregation",
                "SwiftOperators_Aggregation",
                "SwiftParser_Aggregation",
            ]
        ),
        .binaryTarget(
            name: "SwiftIfConfig",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/603.0.1/SwiftIfConfig.xcframework.zip",
            checksum: "3ea38962cd2575045018c42ed767dcf4f0236980b64dc05815120c9d4828f4da"
        ),

        // MARK: - SwiftWarningControl
        .target(
            name: "SwiftWarningControl_Aggregation",
            dependencies: [
                .target(name: "SwiftWarningControl"),
                "SwiftSyntax_Aggregation",
                "SwiftParser_Aggregation",
                "SwiftDiagnostics_Aggregation",
            ]
        ),
        .binaryTarget(
            name: "SwiftWarningControl",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/603.0.1/SwiftWarningControl.xcframework.zip",
            checksum: "22da29cd1142ca5a6d5f6a83d17e85490aad1e0ca9aa8fba67cc9422e1237031"
        ),

        // MARK: - SwiftLexicalLookup
        .target(
            name: "SwiftLexicalLookup_Aggregation",
            dependencies: [
                .target(name: "SwiftLexicalLookup"),
                "SwiftSyntax_Aggregation",
                "SwiftIfConfig_Aggregation",
            ]
        ),
        .binaryTarget(
            name: "SwiftLexicalLookup",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/603.0.1/SwiftLexicalLookup.xcframework.zip",
            checksum: "0596aac34ce00959c7ca2118e76c4b83ae10fcb3e9fcb0acfb818f3141b954fc"
        ),

        // MARK: - SwiftOperators
        .target(
            name: "SwiftOperators_Aggregation",
            dependencies: [
                .target(name: "SwiftOperators"),
                "SwiftDiagnostics_Aggregation",
                "SwiftParser_Aggregation",
                "SwiftSyntax_Aggregation",
            ]
        ),
        .binaryTarget(
            name: "SwiftOperators",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/603.0.1/SwiftOperators.xcframework.zip",
            checksum: "5a11e8c3b0dd203ccd305c0eb9ed7aa0d4a23091e23b0b4606fc9f6f526ffa08"
        ),

        // MARK: - SwiftParser
        .target(
            name: "SwiftParser_Aggregation",
            dependencies: [
                .target(name: "SwiftParser"),
                "SwiftSyntax_Aggregation",
            ]
        ),
        .binaryTarget(
            name: "SwiftParser",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/603.0.1/SwiftParser.xcframework.zip",
            checksum: "9dab752eae2408dd22ec54de4ac5b76fb29c1c60145fda2280f74349a2a2466c"
        ),

        // MARK: - SwiftParserDiagnostics
        .target(
            name: "SwiftParserDiagnostics_Aggregation",
            dependencies: [
                .target(name: "SwiftParserDiagnostics"),
                "SwiftBasicFormat_Aggregation",
                "SwiftDiagnostics_Aggregation",
                "SwiftParser_Aggregation",
                "SwiftSyntax_Aggregation",
            ]
        ),
        .binaryTarget(
            name: "SwiftParserDiagnostics",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/603.0.1/SwiftParserDiagnostics.xcframework.zip",
            checksum: "e027f0f544a890c2ea68ee495e0087a106ab2fec29ab8a9e0c32a4aad216c435"
        ),

        // MARK: - SwiftRefactor
        .target(
            name: "SwiftRefactor_Aggregation",
            dependencies: [
                .target(name: "SwiftRefactor"),
                "SwiftBasicFormat_Aggregation",
                "SwiftParser_Aggregation",
                "SwiftSyntax_Aggregation",
                "SwiftSyntaxBuilder_Aggregation",
            ]
        ),
        .binaryTarget(
            name: "SwiftRefactor",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/603.0.1/SwiftRefactor.xcframework.zip",
            checksum: "adee4dbe5fd80014ace943540cc1d0289d1f0963d66bf0aa2a73d56803bb673a"
        ),

        // MARK: - SwiftSyntax
        .target(
            name: "SwiftSyntax_Aggregation",
            dependencies: [
                .target(name: "SwiftSyntax"),
                "_SwiftSyntaxCShims_Aggregation",
                "SwiftSyntax509_Aggregation",
                "SwiftSyntax510_Aggregation",
                "SwiftSyntax600_Aggregation",
                "SwiftSyntax601_Aggregation",
                "SwiftSyntax602_Aggregation",
                "SwiftSyntax603_Aggregation",
            ]
        ),
        .binaryTarget(
            name: "SwiftSyntax",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/603.0.1/SwiftSyntax.xcframework.zip",
            checksum: "6bc4112d83b32001aa02cda91b7095d0b2455a9d7c91f1606377c8db9108124c"
        ),

        // MARK: - SwiftSyntaxBuilder
        .target(
            name: "SwiftSyntaxBuilder_Aggregation",
            dependencies: [
                .target(name: "SwiftSyntaxBuilder"),
                "SwiftBasicFormat_Aggregation",
                "SwiftParser_Aggregation",
                "SwiftDiagnostics_Aggregation",
                "SwiftParserDiagnostics_Aggregation",
                "SwiftSyntax_Aggregation",
            ]
        ),
        .binaryTarget(
            name: "SwiftSyntaxBuilder",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/603.0.1/SwiftSyntaxBuilder.xcframework.zip",
            checksum: "71ab335736b649a03035f8cf2d953063cd184f293a761961834f1e543ccbc5d6"
        ),

        // MARK: - SwiftSyntaxMacros
        .target(
            name: "SwiftSyntaxMacros_Aggregation",
            dependencies: [
                .target(name: "SwiftSyntaxMacros"),
                "SwiftDiagnostics_Aggregation",
                "SwiftIfConfig_Aggregation",
                "SwiftParser_Aggregation",
                "SwiftSyntax_Aggregation",
                "SwiftSyntaxBuilder_Aggregation",
            ]
        ),
        .binaryTarget(
            name: "SwiftSyntaxMacros",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/603.0.1/SwiftSyntaxMacros.xcframework.zip",
            checksum: "581516c1ac947fb6445d78053b090fb1db408b38152fd7233552a81caec15275"
        ),

        // MARK: - SwiftSyntaxMacroExpansion
        .target(
            name: "SwiftSyntaxMacroExpansion_Aggregation",
            dependencies: [
                .target(name: "SwiftSyntaxMacroExpansion"),
                "SwiftSyntax_Aggregation",
                "SwiftSyntaxBuilder_Aggregation",
                "SwiftSyntaxMacros_Aggregation",
                "SwiftDiagnostics_Aggregation",
                "SwiftOperators_Aggregation",
            ]
        ),
        .binaryTarget(
            name: "SwiftSyntaxMacroExpansion",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/603.0.1/SwiftSyntaxMacroExpansion.xcframework.zip",
            checksum: "a557fd52179897ebc222391112f43698ceef3984debb186edccaafa74c38b1da"
        ),

        // MARK: - SwiftSyntaxMacrosTestSupport
        .target(
            name: "SwiftSyntaxMacrosTestSupport_Aggregation",
            dependencies: [
                .target(name: "SwiftSyntaxMacrosTestSupport"),
                "SwiftSyntax_Aggregation",
                "SwiftSyntaxMacroExpansion_Aggregation",
                "SwiftSyntaxMacros_Aggregation",
                "SwiftSyntaxMacrosGenericTestSupport_Aggregation",
            ]
        ),
        .binaryTarget(
            name: "SwiftSyntaxMacrosTestSupport",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/603.0.1/SwiftSyntaxMacrosTestSupport.xcframework.zip",
            checksum: "d3f88d08d219191ce96b010ff7d536597b7fd530fc3c6235efc8b6afcf6cc879"
        ),

        // MARK: - SwiftSyntaxMacrosGenericTestSupport
        .target(
            name: "SwiftSyntaxMacrosGenericTestSupport_Aggregation",
            dependencies: [
                .target(name: "SwiftSyntaxMacrosGenericTestSupport"),
                "_SwiftSyntaxGenericTestSupport_Aggregation",
                "SwiftDiagnostics_Aggregation",
                "SwiftIDEUtils_Aggregation",
                "SwiftIfConfig_Aggregation",
                "SwiftParser_Aggregation",
                "SwiftSyntaxMacros_Aggregation",
                "SwiftSyntaxMacroExpansion_Aggregation",
            ]
        ),
        .binaryTarget(
            name: "SwiftSyntaxMacrosGenericTestSupport",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/603.0.1/SwiftSyntaxMacrosGenericTestSupport.xcframework.zip",
            checksum: "2e5c562015c4f4a87fa702319e57824252169317282561d82c41a89cd6d77b0e"
        ),

        // MARK: - _SwiftCompilerPluginMessageHandling
        .target(
            name: "_SwiftCompilerPluginMessageHandling_Aggregation",
            dependencies: [.target(name: "_SwiftCompilerPluginMessageHandling")]
        ),
        .binaryTarget(
            name: "_SwiftCompilerPluginMessageHandling",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/603.0.1/_SwiftCompilerPluginMessageHandling.xcframework.zip",
            checksum: "b6ffe3faee8d00d06ab378fc5d21a3f9372ffed426ccf3f3afde20b649708748"
        ),

        // MARK: - _SwiftLibraryPluginProvider
        .target(
            name: "_SwiftLibraryPluginProvider_Aggregation",
            dependencies: [.target(name: "_SwiftLibraryPluginProvider")]
        ),
        .binaryTarget(
            name: "_SwiftLibraryPluginProvider",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/603.0.1/_SwiftLibraryPluginProvider.xcframework.zip",
            checksum: "7154bcca61bbfab015dea3171dd0bfdc741e6dd3133ad492146a3411b208ea11"
        ),

        // MARK: - SwiftCompilerPluginMessageHandling
        .target(
            name: "SwiftCompilerPluginMessageHandling_Aggregation",
            dependencies: [
                .target(name: "SwiftCompilerPluginMessageHandling"),
                "_SwiftSyntaxCShims_Aggregation",
                "SwiftDiagnostics_Aggregation",
                "SwiftOperators_Aggregation",
                "SwiftParser_Aggregation",
                "SwiftSyntax_Aggregation",
                "SwiftSyntaxMacros_Aggregation",
                "SwiftSyntaxMacroExpansion_Aggregation",
            ]
        ),
        .binaryTarget(
            name: "SwiftCompilerPluginMessageHandling",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/603.0.1/SwiftCompilerPluginMessageHandling.xcframework.zip",
            checksum: "5fa2ede4d41c836b479e1958d43f15796d9a054e55c647911183dc1e7a2cd8a3"
        ),

        // MARK: - SwiftLibraryPluginProvider
        .target(
            name: "SwiftLibraryPluginProvider_Aggregation",
            dependencies: [
                .target(name: "SwiftLibraryPluginProvider"),
                "SwiftSyntaxMacros_Aggregation",
                "SwiftCompilerPluginMessageHandling_Aggregation",
                "_SwiftLibraryPluginProviderCShims_Aggregation",
            ]
        ),
        .binaryTarget(
            name: "SwiftLibraryPluginProvider",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/603.0.1/SwiftLibraryPluginProvider.xcframework.zip",
            checksum: "536d4e9f39008539d2511e460a19d741d133a6f174237be90b6badb6242ef125"
        ),

        // MARK: - SwiftSyntax509
        .target(
            name: "SwiftSyntax509_Aggregation",
            dependencies: [.target(name: "SwiftSyntax509")]
        ),
        .binaryTarget(
            name: "SwiftSyntax509",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/603.0.1/SwiftSyntax509.xcframework.zip",
            checksum: "aefb80f9df4e2edcbe2e56820b7fe3f19c086d3cd5dc08a0cc30ca4baaf04076"
        ),

        // MARK: - SwiftSyntax510
        .target(
            name: "SwiftSyntax510_Aggregation",
            dependencies: [.target(name: "SwiftSyntax510")]
        ),
        .binaryTarget(
            name: "SwiftSyntax510",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/603.0.1/SwiftSyntax510.xcframework.zip",
            checksum: "bfbb9cc7985a8ab35615a63a7151b6ac056f70e6bead6beff762d618b5d62167"
        ),

        // MARK: - SwiftSyntax600
        .target(
            name: "SwiftSyntax600_Aggregation",
            dependencies: [.target(name: "SwiftSyntax600")]
        ),
        .binaryTarget(
            name: "SwiftSyntax600",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/603.0.1/SwiftSyntax600.xcframework.zip",
            checksum: "25c9a883a6c19665339810adaaa18ae93feb291e65a727e368198adb90e3ebec"
        ),

        // MARK: - SwiftSyntax601
        .target(
            name: "SwiftSyntax601_Aggregation",
            dependencies: [.target(name: "SwiftSyntax601")]
        ),
        .binaryTarget(
            name: "SwiftSyntax601",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/603.0.1/SwiftSyntax601.xcframework.zip",
            checksum: "c0fcf94b38dd1360de4792006a6032c94a5348e63f65d115e44e5a181e6d2f9d"
        ),

        // MARK: - SwiftSyntax602
        .target(
            name: "SwiftSyntax602_Aggregation",
            dependencies: [.target(name: "SwiftSyntax602")]
        ),
        .binaryTarget(
            name: "SwiftSyntax602",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/603.0.1/SwiftSyntax602.xcframework.zip",
            checksum: "0ddf958a9e254a12e43db2ed20d23f3a36411aa6ef26f960d16f4a5f5e045326"
        ),

        // MARK: - SwiftSyntax603
        .target(
            name: "SwiftSyntax603_Aggregation",
            dependencies: [.target(name: "SwiftSyntax603")]
        ),
        .binaryTarget(
            name: "SwiftSyntax603",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/603.0.1/SwiftSyntax603.xcframework.zip",
            checksum: "180fdab9b4d6379aecadbbf981a322044160931f64a0067644ae0da01db0caf9"
        ),

        // MARK: - _SwiftLibraryPluginProviderCShims
        .target(
            name: "_SwiftLibraryPluginProviderCShims_Aggregation",
            dependencies: [.target(name: "_SwiftLibraryPluginProviderCShims")]
        ),
        .binaryTarget(
            name: "_SwiftLibraryPluginProviderCShims",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/603.0.1/_SwiftLibraryPluginProviderCShims.xcframework.zip",
            checksum: "85e4d61db781898fd4618f2e122d23919c2d94b4025852ab0472bd72e5dc333d"
        ),

        // MARK: - _SwiftSyntaxCShims
        .target(
            name: "_SwiftSyntaxCShims_Aggregation",
            dependencies: [.target(name: "_SwiftSyntaxCShims")]
        ),
        .binaryTarget(
            name: "_SwiftSyntaxCShims",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/603.0.1/_SwiftSyntaxCShims.xcframework.zip",
            checksum: "f28b4f9298979aa3d437e6bda6254f580cb41bf87e3e62c47558bf97658aac29"
        ),

        // MARK: - _SwiftSyntaxGenericTestSupport
        .target(
            name: "_SwiftSyntaxGenericTestSupport_Aggregation",
            dependencies: [.target(name: "_SwiftSyntaxGenericTestSupport")]
        ),
        .binaryTarget(
            name: "_SwiftSyntaxGenericTestSupport",
            url: "https://github.com/MxIris-DeveloperTool/swift-syntax-builder/releases/download/603.0.1/_SwiftSyntaxGenericTestSupport.xcframework.zip",
            checksum: "590862887165d6c114ff0adc4dbf8049f7f9e5f86c7ccba325c477054a616980"
        ),

    ]
)
