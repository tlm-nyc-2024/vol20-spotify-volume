// swift-tools-version:5.9
//
// Package.swift — Swift Package Manager manifest for Vol20 v2.0.
//
// This file is what `swift build` reads to know what to compile. Think of it
// as the equivalent of a package.json (Node) or pyproject.toml (Python). It
// declares:
//   - which Swift language version we want
//   - the minimum macOS version we target (macOS 14 "Sonoma" or newer,
//     because SwiftUI's MenuBarExtra needs at least macOS 13, and we use a
//     couple of conveniences that landed in 14)
//   - one executable product called "Vol20v2" whose source lives in
//     Sources/Vol20v2/
//
// Run `swift build` in this folder and SPM produces .build/debug/Vol20v2
// (or .build/release/Vol20v2 with `-c release`). The build-app.sh script
// then wraps that binary in a proper .app bundle.

import PackageDescription

let package = Package(
    name: "Vol20v2",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Vol20v2",
            path: "Sources/Vol20v2"
        )
    ]
)
