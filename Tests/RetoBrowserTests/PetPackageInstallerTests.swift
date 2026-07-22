import UIKit
import XCTest
@testable import RetoBrowser

@MainActor
final class PetPackageInstallerTests: XCTestCase {
    func testInstallsFromAWellFormedFolder() throws {
        let store = makeStore()
        let folder = try makePackageFolder(
            json: #"{"id":"grove-fox","displayName":"Grove Fox","spritesheetPath":"spritesheet.webp","columns":8,"rows":9}"#,
            image: makeImage(width: 16, height: 18)
        )

        let pet = try PetPackageInstaller.install(from: folder, into: store)

        XCTAssertEqual(pet.id, "grove-fox")
        XCTAssertEqual(pet.displayName, "Grove Fox")
        XCTAssertTrue(store.installedPets.contains(where: { $0.id == "grove-fox" }))
    }

    func testFolderMissingPetJSONThrowsMissingMetadata() throws {
        let store = makeStore()
        let folder = temporaryDirectory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try makeImage(width: 16, height: 18).pngData()!.write(to: folder.appendingPathComponent("spritesheet.webp"))

        XCTAssertThrowsError(try PetPackageInstaller.install(from: folder, into: store)) { error in
            XCTAssertEqual(error as? PetPackageError, .missingMetadata)
        }
    }

    func testCorruptSpritesheetThrowsInvalidSpritesheet() throws {
        let store = makeStore()
        let folder = temporaryDirectory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #"{"id":"broken","displayName":"Broken","spritesheetPath":"spritesheet.webp"}"#
            .write(to: folder.appendingPathComponent("pet.json"), atomically: true, encoding: .utf8)
        // Not actually image data.
        try Data([0x01, 0x02, 0x03, 0x04]).write(to: folder.appendingPathComponent("spritesheet.webp"))

        XCTAssertThrowsError(try PetPackageInstaller.install(from: folder, into: store)) { error in
            XCTAssertEqual(error as? PetPackageError, .invalidSpritesheet)
        }
    }

    func testOversizedGridThrowsInvalidGrid() throws {
        let store = makeStore()
        let folder = try makePackageFolder(
            json: #"{"id":"too-big","displayName":"Too Big","spritesheetPath":"spritesheet.webp","columns":64,"rows":64}"#,
            image: makeImage(width: 16, height: 18)
        )

        XCTAssertThrowsError(try PetPackageInstaller.install(from: folder, into: store)) { error in
            XCTAssertEqual(error as? PetPackageError, .invalidGrid)
        }
    }

    func testGridThatDoesNotDivideTheImageThrowsInvalidGrid() throws {
        let store = makeStore()
        // 16x18 image cannot be split into an exact 5x5 grid.
        let folder = try makePackageFolder(
            json: #"{"id":"uneven","displayName":"Uneven","spritesheetPath":"spritesheet.webp","columns":5,"rows":5}"#,
            image: makeImage(width: 16, height: 18)
        )

        XCTAssertThrowsError(try PetPackageInstaller.install(from: folder, into: store)) { error in
            XCTAssertEqual(error as? PetPackageError, .invalidGrid)
        }
    }

    func testEmptyIDThrows() throws {
        let store = makeStore()
        let folder = try makePackageFolder(
            json: #"{"id":"  ","displayName":"Nameless","spritesheetPath":"spritesheet.webp"}"#,
            image: makeImage(width: 16, height: 18)
        )

        XCTAssertThrowsError(try PetPackageInstaller.install(from: folder, into: store)) { error in
            XCTAssertEqual(error as? PetPackageError, .emptyID)
        }
    }

    func testInstallsFromAStoredZipArchive() throws {
        let store = makeStore()
        let imageData = makeImage(width: 16, height: 18).pngData()!
        let jsonData = Data(#"{"id":"zip-pet","displayName":"Zip Pet","spritesheetPath":"spritesheet.webp","columns":8,"rows":9}"#.utf8)
        let archive = StoredZipBuilder.build(entries: [
            ("pet.json", jsonData),
            ("spritesheet.webp", imageData)
        ])
        let archiveURL = temporaryDirectory().appendingPathExtension("zip")
        try FileManager.default.createDirectory(at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try archive.write(to: archiveURL)

        let pet = try PetPackageInstaller.install(from: archiveURL, into: store)

        XCTAssertEqual(pet.id, "zip-pet")
        XCTAssertTrue(store.installedPets.contains(where: { $0.id == "zip-pet" }))
    }

    func testZipMissingPetJSONThrowsMissingMetadata() throws {
        let store = makeStore()
        let imageData = makeImage(width: 16, height: 18).pngData()!
        let archive = StoredZipBuilder.build(entries: [("spritesheet.webp", imageData)])
        let archiveURL = temporaryDirectory().appendingPathExtension("zip")
        try FileManager.default.createDirectory(at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try archive.write(to: archiveURL)

        XCTAssertThrowsError(try PetPackageInstaller.install(from: archiveURL, into: store)) { error in
            XCTAssertEqual(error as? PetPackageError, .missingMetadata)
        }
    }

    func testDiscoverPackagesFindsZipRetopetAndFolderPackages() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try Data().write(to: directory.appendingPathComponent("a.zip"))
        try Data().write(to: directory.appendingPathComponent("b.retopet"))
        try Data().write(to: directory.appendingPathComponent("notes.txt"))

        let folderPackage = directory.appendingPathComponent("c-pet", isDirectory: true)
        try FileManager.default.createDirectory(at: folderPackage, withIntermediateDirectories: true)
        try Data(#"{"id":"c"}"#.utf8).write(to: folderPackage.appendingPathComponent("pet.json"))

        let emptyFolder = directory.appendingPathComponent("just-a-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyFolder, withIntermediateDirectories: true)

        let found = Set(PetPackageInstaller.discoverPackages(in: directory).map(\.lastPathComponent))
        XCTAssertEqual(found, ["a.zip", "b.retopet", "c-pet"])
    }

    // MARK: - Helpers

    private func makeStore() -> BrowserPetStore {
        let suiteName = "PetPackageInstallerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return BrowserPetStore(defaults: defaults, storageKey: "pet-test", petsDirectory: temporaryDirectory())
    }

    private func makePackageFolder(json: String, image: UIImage) throws -> URL {
        let folder = temporaryDirectory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try json.write(to: folder.appendingPathComponent("pet.json"), atomically: true, encoding: .utf8)
        try image.pngData()!.write(to: folder.appendingPathComponent("spritesheet.webp"))
        return folder
    }

    private func makeImage(width: Int, height: Int) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        return renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PetPackageInstallerTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

/// Builds a minimal, valid "stored" (uncompressed, method 0) ZIP archive in
/// memory — just enough of the format to exercise `MinimalZipReader` in
/// tests without needing a real zip tool or a DEFLATE encoder.
enum StoredZipBuilder {
    static func build(entries: [(name: String, data: Data)]) -> Data {
        var body = Data()
        var centralDirectory = Data()
        var offsets: [Int] = []

        for entry in entries {
            offsets.append(body.count)
            let nameData = Data(entry.name.utf8)

            var localHeader = Data()
            localHeader.append(uint32: 0x04034b50)
            localHeader.append(uint16: 20) // version needed
            localHeader.append(uint16: 0) // flags
            localHeader.append(uint16: 0) // method: stored
            localHeader.append(uint16: 0) // mod time
            localHeader.append(uint16: 0) // mod date
            localHeader.append(uint32: 0) // crc32 (unchecked by MinimalZipReader)
            localHeader.append(uint32: UInt32(entry.data.count)) // compressed size
            localHeader.append(uint32: UInt32(entry.data.count)) // uncompressed size
            localHeader.append(uint16: UInt16(nameData.count))
            localHeader.append(uint16: 0) // extra length
            localHeader.append(nameData)

            body.append(localHeader)
            body.append(entry.data)
        }

        for (index, entry) in entries.enumerated() {
            let nameData = Data(entry.name.utf8)
            var record = Data()
            record.append(uint32: 0x02014b50)
            record.append(uint16: 20) // version made by
            record.append(uint16: 20) // version needed
            record.append(uint16: 0) // flags
            record.append(uint16: 0) // method: stored
            record.append(uint16: 0) // mod time
            record.append(uint16: 0) // mod date
            record.append(uint32: 0) // crc32
            record.append(uint32: UInt32(entry.data.count))
            record.append(uint32: UInt32(entry.data.count))
            record.append(uint16: UInt16(nameData.count))
            record.append(uint16: 0) // extra length
            record.append(uint16: 0) // comment length
            record.append(uint16: 0) // disk number start
            record.append(uint16: 0) // internal attrs
            record.append(uint32: 0) // external attrs
            record.append(uint32: UInt32(offsets[index])) // local header offset
            record.append(nameData)
            centralDirectory.append(record)
        }

        var eocd = Data()
        eocd.append(uint32: 0x06054b50)
        eocd.append(uint16: 0) // disk number
        eocd.append(uint16: 0) // disk with central directory
        eocd.append(uint16: UInt16(entries.count))
        eocd.append(uint16: UInt16(entries.count))
        eocd.append(uint32: UInt32(centralDirectory.count))
        eocd.append(uint32: UInt32(body.count))
        eocd.append(uint16: 0) // comment length

        return body + centralDirectory + eocd
    }
}

private extension Data {
    mutating func append(uint16 value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func append(uint32 value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
