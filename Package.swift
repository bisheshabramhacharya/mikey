// swift-tools-version: 6.2
import PackageDescription

// Full Xcode is not installed — Command Line Tools only. XCTest is Xcode-only,
// so a SwiftPM `.testTarget` produces an `.xctest` bundle (Mach-O MH_BUNDLE)
// that nothing can host: `swift test` builds it and exits without running a
// single test. Instead, MikeyTests below is a plain *executable* containing
// the test files plus `Runner.swift`, which calls Swift Testing's own entry
// point (`Testing.__swiftPMEntryPoint()`). Testing.framework ships in the CLT
// at the path below, so the target needs explicit search/rpath flags.
//
// `Mikey` is therefore a regular library target (Sources/Mikey) — SwiftPM does
// not link an executable *dependency's* objects into a dependent executable,
// but it does for a library. The app itself is the thin `MikeyApp` executable
// (Sources/MikeyApp, just the `@main` SwiftUI App) exposed as the `Mikey`
// product.
//
// Run the suite with `Scripts/test.sh` (or `swift run MikeyTests`).
// `swift test` builds but executes nothing on this toolchain — known CLT gap.
let developerFrameworks =
    "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let developerLibraries =
    "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

// `@testable import Mikey` from the test runner requires the Mikey module to
// be built with -enable-testing — the flag SwiftPM applies automatically to
// testTarget dependencies. Applied debug-only so release .app builds are
// unaffected.
let testableDebug: [SwiftSetting] = [
    .unsafeFlags(["-enable-testing"], .when(configuration: .debug))
]

let package = Package(
    name: "Mikey",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Mikey", targets: ["MikeyApp"]),
    ],
    targets: [
        // All app logic + the SwiftUI menu views. A library so MikeyTests can
        // statically link and `@testable`-import it.
        .target(
            name: "Mikey",
            path: "Sources/Mikey",
            swiftSettings: testableDebug
        ),
        // The menu-bar app entry point; produces the `Mikey` binary.
        .executableTarget(
            name: "MikeyApp",
            dependencies: ["Mikey"],
            path: "Sources/MikeyApp"
        ),
        .executableTarget(
            name: "MikeyTests",
            dependencies: ["Mikey"],
            path: "Tests/MikeyTests",
            swiftSettings: testableDebug + [
                .unsafeFlags(["-F", developerFrameworks])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-F", "-Xlinker", developerFrameworks,
                    "-Xlinker", "-framework", "-Xlinker", "Testing",
                    "-Xlinker", "-rpath", "-Xlinker", developerFrameworks,
                    // Testing.framework loads @rpath/lib_TestingInterop.dylib,
                    // which lives in usr/lib next to the frameworks dir.
                    "-Xlinker", "-rpath", "-Xlinker", developerLibraries,
                ])
            ]
        ),
    ]
)
