import Foundation
import Testing
@testable import Mikey

/// The `whisperModel` config name → WhisperKit repo-variant mapping and the
/// offline readiness check on the local model cache (no network — the fake
/// cache is a temp dir laid out like the real Hub download tree).
struct WhisperKitTranscriberTests {
    private let tempDir: URL
    private let transcriber: WhisperKitTranscriber

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appending(path: "mikey-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        transcriber = WhisperKitTranscriber(downloadBase: tempDir)
    }

    private func cleanup() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Lays down a fake variant folder in the Hub cache layout:
    /// `<base>/models/argmaxinc/whisperkit-coreml/<folder>/<components…>`.
    @discardableResult
    private func fakeVariant(_ folder: String, components: [String] = [
        "MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc",
    ]) throws -> URL {
        let dir = tempDir
            .appending(path: "models/argmaxinc/whisperkit-coreml/\(folder)")
        for component in components {
            let file = dir.appending(path: "\(component)/model.mlmodel")
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data([0x00]).write(to: file)
        }
        return dir
    }

    @Test func configNameResolvesToRepoVariant() {
        #expect(WhisperKitTranscriber.resolveVariant("large-v3-turbo") == "large-v3_turbo")
        #expect(WhisperKitTranscriber.resolveVariant("large-v3") == "large-v3")
        #expect(WhisperKitTranscriber.resolveVariant("tiny") == "tiny")
        #expect(
            WhisperKitTranscriber.resolveVariant("openai_whisper-large-v3_turbo")
                == "large-v3_turbo"
        )
        #expect(
            WhisperKitTranscriber.resolveVariant("  distil-large-v3-turbo  ")
                == "distil-large-v3_turbo"
        )
    }

    @Test func readyWhenCompleteVariantFolderExists() async throws {
        defer { cleanup() }
        try fakeVariant("openai_whisper-large-v3_turbo")

        let ready = await transcriber.isModelReady("large-v3-turbo")

        #expect(ready)
    }

    @Test func notReadyWhenCacheEmptyOrIncomplete() async throws {
        defer { cleanup() }
        #expect(await transcriber.isModelReady("large-v3-turbo") == false)

        // Half-downloaded folder (no TextDecoder) doesn't count — the
        // download path resumes it instead of loading a broken model.
        try fakeVariant(
            "openai_whisper-large-v3_turbo",
            components: ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc"]
        )
        #expect(await transcriber.isModelReady("large-v3-turbo") == false)
    }

    @Test func openaiVariantWinsOverDistilTiebreak() throws {
        defer { cleanup() }
        try fakeVariant("openai_whisper-large-v3_turbo")
        try fakeVariant("distil-whisper_distil-large-v3_turbo")

        let folder = transcriber.localModelFolder(for: "large-v3_turbo")

        #expect(folder?.lastPathComponent == "openai_whisper-large-v3_turbo")
    }

    @Test func explicitRepoFolderNameResolvesLocally() throws {
        defer { cleanup() }
        // A user pinning the quantized variant by its full repo name.
        try fakeVariant("openai_whisper-large-v3_turbo_954MB")

        let folder = transcriber.localModelFolder(for: "large-v3_turbo_954MB")

        #expect(folder?.lastPathComponent == "openai_whisper-large-v3_turbo_954MB")
        // …and plain "large-v3_turbo" does not claim the quantized folder.
        #expect(transcriber.localModelFolder(for: "large-v3_turbo") == nil)
    }
}
