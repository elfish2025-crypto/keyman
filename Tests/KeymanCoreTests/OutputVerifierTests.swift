import Foundation
import Testing
@testable import KeymanCore

@Test(arguments: [InspectionStatus.noVisibleMarkDetected, .suspectedWatermark, .inspectionFailed])
func outputGateKeepsResponseAndOnlyAcceptsCheckedMedia(status: InspectionStatus) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = FixtureDownloader()
    let gate = OutputVerifier(root: root, inspector: FixtureInspector(status: status), downloader: downloader)
    let body = Data(#"{"data":[{"url":"https://result.example/image.png"}]}"#.utf8)
    let result = await gate.verify(body: body, model: .seedreamFixture, profileAlias: "test")
    #expect(result.status == status)
    #expect(result.deliverable == (status == .noVisibleMarkDetected))
    let file = try #require(result.responseFile)
    #expect(try Data(contentsOf: URL(fileURLWithPath: file)) == body)
    #expect(result.receiptFile != nil)
    #expect(await downloader.calls == 1)
}

@Test
func partialFailureDoesNotDeliverOnlyTheSuccessfulImage() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = FixtureDownloader()
    let gate = OutputVerifier(root: root, inspector: FixtureInspector(status: .noVisibleMarkDetected), downloader: downloader)
    for body in [#"{"data":[{"url":"https://result.example/image.png"},{"error":{"message":"failed"}}]}"#,
                 #"{"data":[{"url":"https://result.example/image.png"},{}]}"#] {
        let result = await gate.verify(body: Data(body.utf8), model: .seedreamFixture, profileAlias: "test")
        #expect(!result.deliverable)
        #expect(result.status == .inspectionFailed)
    }
    #expect(await downloader.calls == 0)
}

@Test
func asynchronousAndUnrecognizedResponsesRemainPendingWithoutRetry() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = FixtureDownloader()
    let gate = OutputVerifier(root: root, inspector: FixtureInspector(status: .noVisibleMarkDetected), downloader: downloader)
    var model = ModelRecord.seedreamFixture; model.callTemplate?.isAsync = true
    let result = await gate.verify(body: Data(#"{"task_id":"existing-task"}"#.utf8), model: model, profileAlias: "test")
    #expect(result.status == .pending)
    #expect(!result.deliverable)
    #expect(result.responseFile != nil)
    #expect(await downloader.calls == 0)
}

@Test
func customResponsePathAndBase64AreSupported() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let gate = OutputVerifier(root: root, inspector: FixtureInspector(status: .noVisibleMarkDetected), downloader: FixtureDownloader())
    var model = ModelRecord.seedreamFixture; model.callTemplate?.outputPaths = ["result.files.*.encoded"]
    let result = await gate.verify(body: Data(#"{"result":{"files":[{"encoded":"dGVzdA=="}]}}"#.utf8), model: model, profileAlias: "test")
    #expect(result.deliverable)
    #expect(result.media.count == 1)
}

@Test
func downloadFailurePreservesReceiptWithoutAGenerationRetry() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = FixtureDownloader(fail: true)
    let gate = OutputVerifier(root: root, inspector: FixtureInspector(status: .noVisibleMarkDetected), downloader: downloader)
    let result = await gate.verify(body: Data(#"{"data":[{"url":"https://result.example/image.png"}]}"#.utf8), model: .seedreamFixture, profileAlias: "test")
    #expect(result.status == .inspectionFailed)
    #expect(result.responseFile != nil)
    #expect(await downloader.calls == 1)
}

@Test
func changedProviderModelRequiresReview() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = FixtureDownloader()
    let gate = OutputVerifier(root: root, inspector: FixtureInspector(status: .noVisibleMarkDetected), downloader: downloader)
    let result = await gate.verify(body: Data(#"{"model":"different-model","data":[{"url":"https://result.example/image.png"}]}"#.utf8), model: .seedreamFixture, profileAlias: "test")
    #expect(result.status == .inspectionFailed)
    #expect(await downloader.calls == 0)
}

private struct FixtureInspector: MediaInspecting {
    var status: InspectionStatus
    func inspect(_ url: URL) async -> MediaInspection {
        MediaInspection(file: url.path, status: status, inspectedFrames: 1, detail: "Fixture inspection")
    }
}

private actor FixtureDownloader: MediaDownloading {
    var fail: Bool
    private(set) var calls = 0
    init(fail: Bool = false) { self.fail = fail }
    func download(_ url: URL, to directory: URL, name: String) throws -> URL {
        calls += 1
        if fail { throw KeymanError.networkError("Fixture failure") }
        let file = directory.appendingPathComponent(name + ".png")
        try Data("test".utf8).write(to: file)
        return file
    }
}
