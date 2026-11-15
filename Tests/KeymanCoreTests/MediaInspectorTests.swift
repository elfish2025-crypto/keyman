import Foundation
import Testing
@testable import KeymanCore

@Test
func realVideoInspectionDistinguishesCleanAndMarkedFrames() async throws {
    let root = try #require(Bundle.module.resourceURL).appendingPathComponent("Fixtures/Media")
    let clean = await LocalMediaInspector().inspect(root.appendingPathComponent("clean-video.mp4"))
    let marked = await LocalMediaInspector().inspect(root.appendingPathComponent("marked-video.mp4"))
    #expect(clean.status == .noVisibleMarkDetected)
    #expect(marked.status == .suspectedWatermark)
    #expect(clean.inspectedFrames >= 2)
    #expect(marked.inspectedFrames >= 2)
    #expect(marked.findings.contains { $0.lowercased().contains("generated") })
}
