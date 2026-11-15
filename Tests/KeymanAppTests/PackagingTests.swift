import Foundation
import Testing

@Test
func testInfoPlistDeclaresVisibleAppAndMinimumSystem() throws {
    let url = repositoryRoot()
        .appendingPathComponent("Packaging/Info.plist")
    let data = try Data(contentsOf: url)
    let plist = try PropertyListSerialization.propertyList(
        from: data,
        format: nil
    ) as! [String: Any]

    #expect(plist["CFBundleIdentifier"] as? String == "com.local.keyman")
    #expect(plist["CFBundleExecutable"] as? String == "Keyman")
    #expect(plist["LSUIElement"] as? Bool == false)
    #expect(plist["LSMinimumSystemVersion"] as? String == "14.0")
}

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
