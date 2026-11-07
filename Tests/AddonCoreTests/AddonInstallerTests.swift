import Foundation
import XCTest
import ZIPFoundation
@testable import AddonCore

final class AddonInstallerTests: XCTestCase {
    private var root: URL!
    private var addons: URL!

    override func setUpWithError() throws {
        let base = ProcessInfo.processInfo.environment["WOW_INSTALL_TEST_TMP"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        root = base.appendingPathComponent("addon-installer-tests-\(UUID().uuidString)", isDirectory: true)
        addons = root.appendingPathComponent("AddOns", isDirectory: true)
        try FileManager.default.createDirectory(at: addons, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    private func archive(_ files: [(String, String, Entry.EntryType)]) throws -> URL {
        let url = root.appendingPathComponent("\(UUID().uuidString).zip")
        let archive = try Archive(url: url, accessMode: .create)
        for (path, string, type) in files {
            let data = Data(string.utf8)
            try archive.addEntry(with: path, type: type, uncompressedSize: Int64(data.count)) { position, count in
                let start = Int(position)
                return data.subdata(in: start ..< min(start + count, data.count))
            }
        }
        return url
    }

    func testFirstInstallAndUpdatePreserveOtherFoldersAndBackup() throws {
        let installer = AddonInstaller()
        let other = addons.appendingPathComponent("AnotherAddon")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        let first = try archive([("Demo/Demo.toc", "v1", .file), ("Demo/lib/main.lua", "old", .file)])
        let initial = try installer.install(archive: first, destination: addons, addonDirectory: "Demo", isManaged: false)
        XCTAssertNil(initial.backupURL)
        let update = try archive([("Demo.toc", "v2", .file), ("lib/main.lua", "new", .file)])
        let result = try installer.install(archive: update, destination: addons, addonDirectory: "Demo", isManaged: true)
        XCTAssertEqual(try String(contentsOf: addons.appendingPathComponent("Demo/Demo.toc"), encoding: .utf8), "v2")
        let backup = try XCTUnwrap(result.backupURL)
        XCTAssertEqual(try String(contentsOf: backup.appendingPathComponent("Demo.toc"), encoding: .utf8), "v1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    func testUnmanagedDirectoryIsNeverOverwritten() throws {
        let existing = addons.appendingPathComponent("Demo", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        try "user".write(to: existing.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
        let zip = try archive([("Demo/Demo.toc", "new", .file)])
        XCTAssertThrowsError(try AddonInstaller().install(archive: zip, destination: addons, addonDirectory: "Demo", isManaged: false))
        XCTAssertEqual(try String(contentsOf: existing.appendingPathComponent("keep.txt"), encoding: .utf8), "user")
    }

    func testUnsafeArchiveAndLinksDoNotChangeManagedVersion() throws {
        let installer = AddonInstaller()
        let old = try archive([("Demo/Demo.toc", "old", .file)])
        _ = try installer.install(archive: old, destination: addons, addonDirectory: "Demo", isManaged: false)
        let attacks: [[(String, String, Entry.EntryType)]] = [
            [("Demo/Demo.toc", "new", .file), ("Demo/../../escape", "bad", .file)],
            [("Demo/Demo.toc", "new", .file), ("Demo/link", "../../escape", .symlink)],
            [("Demo/Demo.toc", "new", .file), ("Other/other.toc", "bad", .file)],
            [("Demo/not-the-addon.toc", "wrong", .file)]
        ]
        for attack in attacks {
            let bad = try archive(attack)
            XCTAssertThrowsError(try installer.install(archive: bad, destination: addons, addonDirectory: "Demo", isManaged: true))
            XCTAssertEqual(try String(contentsOf: addons.appendingPathComponent("Demo/Demo.toc"), encoding: .utf8), "old")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escape").path))
    }

    func testRejectsUnixSpecialFileAndTruncatedCentralDirectory() throws {
        let special = try archive([("Demo/Demo.toc", "new", .file)])
        var bytes = [UInt8](try Data(contentsOf: special))
        let central = try XCTUnwrap(bytes.indices.dropLast(3).first(where: {
            Array(bytes[$0 ..< $0 + 4]) == [0x50, 0x4b, 0x01, 0x02]
        }))
        bytes[central + 5] = 3 // Unix creator
        bytes[central + 40] = 0x00
        bytes[central + 41] = 0x10 // FIFO file mode
        try Data(bytes).write(to: special)
        XCTAssertThrowsError(try AddonInstaller().install(archive: special, destination: addons, addonDirectory: "Demo", isManaged: false))

        let truncated = try archive([("Demo/Demo.toc", "new", .file)])
        var incomplete = [UInt8](try Data(contentsOf: truncated))
        let end = try XCTUnwrap(incomplete.indices.dropLast(3).last(where: {
            Array(incomplete[$0 ..< $0 + 4]) == [0x50, 0x4b, 0x05, 0x06]
        }))
        incomplete[end + 8] = 2
        incomplete[end + 10] = 2
        try Data(incomplete).write(to: truncated)
        XCTAssertThrowsError(try AddonInstaller().install(archive: truncated, destination: addons, addonDirectory: "Demo", isManaged: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: addons.appendingPathComponent("Demo").path))
    }

    func testSymlinkTargetAndRecoveryMarkerAreRejected() throws {
        let external = root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: addons.appendingPathComponent("Demo"), withDestinationURL: external)
        let zip = try archive([("Demo/Demo.toc", "new", .file)])
        XCTAssertThrowsError(try AddonInstaller().install(archive: zip, destination: addons, addonDirectory: "Demo", isManaged: true))
        try FileManager.default.removeItem(at: addons.appendingPathComponent("Demo"))
        let recovery = addons.appendingPathComponent(".addon-manager-recovery-Demo-previous")
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: false)
        XCTAssertThrowsError(try AddonInstaller().install(archive: zip, destination: addons, addonDirectory: "Demo", isManaged: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.path))
    }
}
