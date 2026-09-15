import Testing

/// Entry point for the MikeyTests executable.
///
/// Command Line Tools (no Xcode) has no XCTest host, so SwiftPM's `.testTarget`
/// output — an `.xctest` Mach-O bundle — can never execute. This executable
/// embeds the test files directly and hands control to Swift Testing's own
/// runner, exactly as SwiftPM's generated
/// `.build/…/MikeyPackageTests.derived/runner.swift` does with
/// `--testing-library swift-testing`.
///
/// CLI args pass through to swift-testing (`--filter`, `--skip`,
/// `--list-tests`, `--verbose`, …) and the process exits nonzero when any
/// test fails — `Scripts/test.sh` relies on that for pass/fail.
@main
struct MikeyTestRunner {
    static func main() async {
        await Testing.__swiftPMEntryPoint() as Never
    }
}
