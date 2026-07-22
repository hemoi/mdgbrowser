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

    // MARK: - Zip-slip / path traversal

    func testFolderPackageWithTraversalIDThrowsUnsafePath() throws {
        let store = makeStore()
        let folder = try makePackageFolder(
            json: #"{"id":"../../../../Library/Preferences/evil","displayName":"Evil","spritesheetPath":"spritesheet.webp"}"#,
            image: makeImage(width: 16, height: 18)
        )

        XCTAssertThrowsError(try PetPackageInstaller.install(from: folder, into: store)) { error in
            XCTAssertEqual(error as? PetPackageError, .unsafePath)
        }
    }

    func testZipPackageWithTraversalIDThrowsUnsafePath() throws {
        let store = makeStore()
        let imageData = makeImage(width: 16, height: 18).pngData()!
        let jsonData = Data(#"{"id":"../../../../Library/Preferences/evil","displayName":"Evil","spritesheetPath":"spritesheet.webp"}"#.utf8)
        let archive = StoredZipBuilder.build(entries: [
            ("pet.json", jsonData),
            ("spritesheet.webp", imageData)
        ])
        let archiveURL = try writeArchive(archive)

        XCTAssertThrowsError(try PetPackageInstaller.install(from: archiveURL, into: store)) { error in
            XCTAssertEqual(error as? PetPackageError, .unsafePath)
        }
        XCTAssertFalse(store.installedPets.contains(where: { $0.id.contains("Preferences") }))
    }

    func testAbsolutePetIDThrowsUnsafePath() throws {
        let store = makeStore()
        let folder = try makePackageFolder(
            json: #"{"id":"/etc/passwd","displayName":"Evil","spritesheetPath":"spritesheet.webp"}"#,
            image: makeImage(width: 16, height: 18)
        )

        XCTAssertThrowsError(try PetPackageInstaller.install(from: folder, into: store)) { error in
            XCTAssertEqual(error as? PetPackageError, .unsafePath)
        }
    }

    /// The folder-package path, not just the zip path: `spritesheetPath` is
    /// used to build a real filesystem URL via `appendingPathComponent`, so
    /// it needs the same defense as zip entry names. This plants a real,
    /// readable image *outside* the package folder and confirms the
    /// installer still refuses to reach for it.
    func testFolderPackageSpritesheetPathEscapingFolderThrowsUnsafePath() throws {
        let store = makeStore()
        let folder = temporaryDirectory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A real, decodable image sitting one level above the package
        // folder — the attack only "succeeds" if the installer would
        // otherwise happily read it.
        let secretURL = folder.deletingLastPathComponent().appendingPathComponent("secret-\(UUID().uuidString).webp")
        try makeImage(width: 16, height: 18).pngData()!.write(to: secretURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: secretURL) }

        try #"{"id":"escape","displayName":"Escape","spritesheetPath":"../\#(secretURL.lastPathComponent)"}"#
            .write(to: folder.appendingPathComponent("pet.json"), atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try PetPackageInstaller.install(from: folder, into: store)) { error in
            XCTAssertEqual(error as? PetPackageError, .unsafePath)
        }
    }

    /// Same escape as above, but via a symlink planted *inside* the folder
    /// rather than a `..` in the declared path string — exercises the
    /// `resolvingSymlinksInPath()` containment check specifically, since a
    /// plain string check on "spritesheet.webp" (no ".." in sight) would
    /// not catch this on its own.
    func testFolderPackageSpritesheetSymlinkEscapingFolderThrowsUnsafePath() throws {
        let store = makeStore()
        let folder = temporaryDirectory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let secretURL = folder.deletingLastPathComponent().appendingPathComponent("secret-\(UUID().uuidString).webp")
        try makeImage(width: 16, height: 18).pngData()!.write(to: secretURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: secretURL) }

        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("spritesheet.webp"),
            withDestinationURL: secretURL
        )
        try #"{"id":"symlink-escape","displayName":"Escape"}"#
            .write(to: folder.appendingPathComponent("pet.json"), atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try PetPackageInstaller.install(from: folder, into: store)) { error in
            XCTAssertEqual(error as? PetPackageError, .unsafePath)
        }
    }

    func testZipEntryWithTraversalNameThrowsUnsafePath() throws {
        let store = makeStore()
        let imageData = makeImage(width: 16, height: 18).pngData()!
        let jsonData = Data(#"{"id":"traversal-entry","displayName":"T","spritesheetPath":"spritesheet.webp"}"#.utf8)
        let archive = StoredZipBuilder.build(entries: [
            ("pet.json", jsonData),
            ("spritesheet.webp", imageData),
            ("../../../../Library/Preferences/evil.plist", Data("pwned".utf8))
        ])
        let archiveURL = try writeArchive(archive)

        XCTAssertThrowsError(try PetPackageInstaller.install(from: archiveURL, into: store)) { error in
            XCTAssertEqual(error as? PetPackageError, .unsafePath)
        }
    }

    func testZipEntryWithAbsoluteNameThrowsUnsafePath() throws {
        let archive = StoredZipBuilder.build(entries: [
            (name: "/etc/passwd", data: Data("pwned".utf8))
        ])

        XCTAssertThrowsError(try MinimalZipReader(data: archive)) { error in
            XCTAssertEqual(error as? PetPackageError, .unsafePath)
        }
    }

    func testZipEntryWithBackslashTraversalNameThrowsUnsafePath() throws {
        let archive = StoredZipBuilder.build(entries: [
            (name: "..\\..\\evil.txt", data: Data("pwned".utf8))
        ])

        XCTAssertThrowsError(try MinimalZipReader(data: archive)) { error in
            XCTAssertEqual(error as? PetPackageError, .unsafePath)
        }
    }

    /// Info-ZIP-style symlink entry (Unix `S_IFLNK` packed into the
    /// external file attributes). We never resolve archive-declared
    /// symlinks, so the whole archive is refused rather than silently
    /// skipping or following the link.
    func testZipEntryMarkedAsSymlinkThrowsUnsafePath() throws {
        let store = makeStore()
        let imageData = makeImage(width: 16, height: 18).pngData()!
        let jsonData = Data(#"{"id":"symlink-pet","displayName":"S","spritesheetPath":"spritesheet.webp"}"#.utf8)
        let archive = StoredZipBuilder.build(entries: [
            RawZipEntry(name: "pet.json", data: jsonData),
            RawZipEntry(
                name: "spritesheet.webp",
                data: Data("/etc/passwd".utf8),
                externalAttributes: unixSymlinkExternalAttributes
            )
        ])
        let archiveURL = try writeArchive(archive)

        XCTAssertThrowsError(try PetPackageInstaller.install(from: archiveURL, into: store)) { error in
            XCTAssertEqual(error as? PetPackageError, .unsafePath)
        }
    }

    // MARK: - Zip bomb / decompression ratio

    func testZipEntryDeclaringOversizedUncompressedSizeThrowsArchiveTooLarge() throws {
        let archive = StoredZipBuilder.build(entries: [
            RawZipEntry(
                name: "spritesheet.webp",
                data: Data(repeating: 0x41, count: 64),
                compressedSize: 64,
                uncompressedSize: 500 * 1024 * 1024 // 500 MB from a 64-byte entry
            )
        ])

        XCTAssertThrowsError(try MinimalZipReader(data: archive)) { error in
            XCTAssertEqual(error as? PetPackageError, .archiveTooLarge)
        }
    }

    func testZipEntryWithImplausibleCompressionRatioThrowsArchiveTooLarge() throws {
        // 10 MB claimed from 100 declared compressed bytes — a 100,000:1
        // ratio, far past anything real DEFLATE output produces, but still
        // under the flat per-entry size cap on its own.
        let archive = StoredZipBuilder.build(entries: [
            RawZipEntry(
                name: "spritesheet.webp",
                data: Data(repeating: 0, count: 16),
                method: 8,
                compressedSize: 100,
                uncompressedSize: 10 * 1024 * 1024
            )
        ])

        XCTAssertThrowsError(try MinimalZipReader(data: archive)) { error in
            XCTAssertEqual(error as? PetPackageError, .archiveTooLarge)
        }
    }

    func testZipEntryWithZeroCompressedSizeButNonzeroUncompressedSizeThrowsArchiveTooLarge() throws {
        let archive = StoredZipBuilder.build(entries: [
            RawZipEntry(
                name: "spritesheet.webp",
                data: Data(),
                method: 8,
                compressedSize: 0,
                uncompressedSize: 1_000_000
            )
        ])

        XCTAssertThrowsError(try MinimalZipReader(data: archive)) { error in
            XCTAssertEqual(error as? PetPackageError, .archiveTooLarge)
        }
    }

    func testTotalUncompressedSizeAcrossEntriesThrowsArchiveTooLarge() throws {
        // Three entries, each individually under the per-entry cap (64 MB)
        // and with a plausible ratio, but summing well past the 128 MB
        // total-archive cap.
        let entry = RawZipEntry(
            name: "a",
            data: Data(repeating: 0, count: 1024),
            method: 8,
            compressedSize: 300_000,
            uncompressedSize: 50 * 1024 * 1024
        )
        var entryB = entry
        entryB.name = "b"
        var entryC = entry
        entryC.name = "c"
        let archive = StoredZipBuilder.build(entries: [entry, entryB, entryC])

        XCTAssertThrowsError(try MinimalZipReader(data: archive)) { error in
            XCTAssertEqual(error as? PetPackageError, .archiveTooLarge)
        }
    }

    func testOversizedArchiveFileThrowsArchiveTooLargeBeforeParsing() throws {
        let store = makeStore()
        let archiveURL = temporaryDirectory().appendingPathExtension("zip")
        try FileManager.default.createDirectory(at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Not even a valid zip — the raw on-disk size check in
        // `readArchive` must reject this before any parsing is attempted.
        try Data(count: MinimalZipReader.maxArchiveFileSize + 1024).write(to: archiveURL)

        XCTAssertThrowsError(try PetPackageInstaller.install(from: archiveURL, into: store)) { error in
            XCTAssertEqual(error as? PetPackageError, .archiveTooLarge)
        }
    }

    func testForgedEntryCountAboveCapThrowsArchiveTooLarge() throws {
        let imageData = makeImage(width: 16, height: 18).pngData()!
        let jsonData = Data(#"{"id":"forged","displayName":"F","spritesheetPath":"spritesheet.webp"}"#.utf8)
        let archive = StoredZipBuilder.build(entries: [
            ("pet.json", jsonData),
            ("spritesheet.webp", imageData)
        ])
        let forged = StoredZipBuilder.corruptEntryCount(archive, to: 60_000)

        XCTAssertThrowsError(try MinimalZipReader(data: forged)) { error in
            XCTAssertEqual(error as? PetPackageError, .archiveTooLarge)
        }
    }

    // MARK: - Bounds, truncation, and malformed archives

    func testEmptyDataIsNotAReadableArchive() throws {
        XCTAssertThrowsError(try MinimalZipReader(data: Data())) { error in
            XCTAssertEqual(error as? PetPackageError, .invalidArchive)
        }
    }

    func testRandomGarbageIsNotAReadableArchive() throws {
        let garbage = Data((0..<256).map { UInt8(($0 * 37 + 11) % 256) })
        XCTAssertThrowsError(try MinimalZipReader(data: garbage)) { error in
            XCTAssertEqual(error as? PetPackageError, .invalidArchive)
        }
    }

    /// A declared entry count that doesn't match what's actually present
    /// in the central directory — the previous implementation silently
    /// `break`'d out of the loop and returned whatever partial entry list
    /// it had parsed so far, accepting the corrupt archive. It must now
    /// throw instead.
    func testEntryCountMismatchWithActualEntriesThrowsInvalidArchive() throws {
        let imageData = makeImage(width: 16, height: 18).pngData()!
        let jsonData = Data(#"{"id":"mismatch","displayName":"M","spritesheetPath":"spritesheet.webp"}"#.utf8)
        let archive = StoredZipBuilder.build(entries: [
            ("pet.json", jsonData),
            ("spritesheet.webp", imageData)
        ])
        // Declares 3 entries but only 2 are actually present.
        let corrupted = StoredZipBuilder.corruptEntryCount(archive, to: 3)

        XCTAssertThrowsError(try MinimalZipReader(data: corrupted)) { error in
            XCTAssertEqual(error as? PetPackageError, .invalidArchive)
        }
    }

    func testTruncatedArchiveMissingEOCDThrowsInvalidArchiveAndDoesNotCrash() throws {
        let imageData = makeImage(width: 16, height: 18).pngData()!
        let jsonData = Data(#"{"id":"truncated","displayName":"T","spritesheetPath":"spritesheet.webp"}"#.utf8)
        let archive = StoredZipBuilder.build(entries: [
            ("pet.json", jsonData),
            ("spritesheet.webp", imageData)
        ])
        let truncated = archive.prefix(archive.count - 10)

        XCTAssertThrowsError(try MinimalZipReader(data: Data(truncated))) { error in
            XCTAssertEqual(error as? PetPackageError, .invalidArchive)
        }
    }

    func testDuplicateEntryNamesThrowInvalidArchive() throws {
        let jsonData = Data(#"{"id":"dup","displayName":"D","spritesheetPath":"spritesheet.webp"}"#.utf8)
        let otherJSONData = Data(#"{"id":"other","displayName":"O"}"#.utf8)
        let archive = StoredZipBuilder.build(entries: [
            ("pet.json", jsonData),
            ("pet.json", otherJSONData)
        ])

        XCTAssertThrowsError(try MinimalZipReader(data: archive)) { error in
            XCTAssertEqual(error as? PetPackageError, .invalidArchive)
        }
    }

    /// A directory entry (trailing "/") named so it *would* extension-match
    /// as an image must never shadow a real image file that sorts after
    /// it — before this was fixed, `firstImageData()` picked the first
    /// name matching an image extension without checking whether it was
    /// actually a directory, so a same-shaped bogus entry could make a
    /// perfectly good package fail to install.
    func testDirectoryEntryDoesNotShadowRealSpritesheetInFallbackLookup() throws {
        let store = makeStore()
        let imageData = makeImage(width: 16, height: 18).pngData()!
        // No spritesheetPath, so install() falls back to firstImageData().
        let jsonData = Data(#"{"id":"dir-confusion","displayName":"D"}"#.utf8)
        let archive = StoredZipBuilder.build(entries: [
            RawZipEntry(name: "pet.json", data: jsonData),
            RawZipEntry(name: "decoy.webp/", data: Data()), // directory, not a file
            RawZipEntry(name: "real.webp", data: imageData)
        ])
        let archiveURL = try writeArchive(archive)

        let pet = try PetPackageInstaller.install(from: archiveURL, into: store)

        XCTAssertEqual(pet.id, "dir-confusion")
    }

    func testEntryCountAboveCapThrowsArchiveTooLarge() throws {
        var entries: [RawZipEntry] = []
        for index in 0..<300 {
            entries.append(RawZipEntry(name: "file-\(index).txt", data: Data([UInt8(index % 256)])))
        }
        let archive = StoredZipBuilder.build(entries: entries)

        XCTAssertThrowsError(try MinimalZipReader(data: archive)) { error in
            XCTAssertEqual(error as? PetPackageError, .archiveTooLarge)
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

    private func writeArchive(_ data: Data) throws -> URL {
        let archiveURL = temporaryDirectory().appendingPathExtension("zip")
        try FileManager.default.createDirectory(at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: archiveURL)
        return archiveURL
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

/// One ZIP central-directory entry with every field a malicious archive
/// might forge exposed directly — `compressedSize`/`uncompressedSize`
/// default to the real byte count of `data` (a normal, honest entry) but
/// can be overridden independently of it to build zip-bomb-style headers
/// that lie about their size, and `externalAttributes` can encode a Unix
/// symlink mode to build zip-slip-via-symlink archives.
struct RawZipEntry {
    var name: String
    var data: Data = Data()
    var method: UInt16 = 0
    var compressedSize: UInt32?
    var uncompressedSize: UInt32?
    var externalAttributes: UInt32 = 0
}

/// Builds a ZIP archive (stored/method-0 payloads by default) byte-for-byte
/// from a list of `RawZipEntry` — just enough of the format to exercise
/// `MinimalZipReader` in tests, including forged/adversarial headers, all
/// without needing a real zip tool.
enum StoredZipBuilder {
    static func build(entries: [(name: String, data: Data)]) -> Data {
        build(entries: entries.map { RawZipEntry(name: $0.name, data: $0.data) })
    }

    static func build(entries: [RawZipEntry]) -> Data {
        var body = Data()
        var centralDirectory = Data()
        var offsets: [Int] = []

        for entry in entries {
            offsets.append(body.count)
            let nameData = Data(entry.name.utf8)
            let compressedSize = entry.compressedSize ?? UInt32(entry.data.count)
            let uncompressedSize = entry.uncompressedSize ?? UInt32(entry.data.count)

            var localHeader = Data()
            localHeader.append(uint32: 0x04034b50)
            localHeader.append(uint16: 20) // version needed
            localHeader.append(uint16: 0) // flags
            localHeader.append(uint16: entry.method)
            localHeader.append(uint16: 0) // mod time
            localHeader.append(uint16: 0) // mod date
            localHeader.append(uint32: 0) // crc32 (unchecked by MinimalZipReader)
            localHeader.append(uint32: compressedSize)
            localHeader.append(uint32: uncompressedSize)
            localHeader.append(uint16: UInt16(nameData.count))
            localHeader.append(uint16: 0) // extra length
            localHeader.append(nameData)

            body.append(localHeader)
            body.append(entry.data)
        }

        for (index, entry) in entries.enumerated() {
            let nameData = Data(entry.name.utf8)
            let compressedSize = entry.compressedSize ?? UInt32(entry.data.count)
            let uncompressedSize = entry.uncompressedSize ?? UInt32(entry.data.count)
            var record = Data()
            record.append(uint32: 0x02014b50)
            record.append(uint16: 20) // version made by
            record.append(uint16: 20) // version needed
            record.append(uint16: 0) // flags
            record.append(uint16: entry.method)
            record.append(uint16: 0) // mod time
            record.append(uint16: 0) // mod date
            record.append(uint32: 0) // crc32
            record.append(uint32: compressedSize)
            record.append(uint32: uncompressedSize)
            record.append(uint16: UInt16(nameData.count))
            record.append(uint16: 0) // extra length
            record.append(uint16: 0) // comment length
            record.append(uint16: 0) // disk number start
            record.append(uint16: 0) // internal attrs
            record.append(uint32: entry.externalAttributes)
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

    /// Rewrites the "total entries" (and "entries on this disk") fields of
    /// an already-built archive's End Of Central Directory record, without
    /// touching the actual entries — simulates a forged/corrupt entry
    /// count independent of what's really present.
    static func corruptEntryCount(_ archive: Data, to count: UInt16) -> Data {
        var patched = archive
        let eocdOffset = patched.count - 22
        patched[eocdOffset + 8] = UInt8(count & 0xFF)
        patched[eocdOffset + 9] = UInt8((count >> 8) & 0xFF)
        patched[eocdOffset + 10] = UInt8(count & 0xFF)
        patched[eocdOffset + 11] = UInt8((count >> 8) & 0xFF)
        return patched
    }
}

/// The Unix `S_IFLNK` bit, packed into the high 16 bits of a ZIP central
/// directory entry's external file attributes, is how `zip -y`/Info-ZIP
/// mark a symlink entry.
private let unixSymlinkExternalAttributes: UInt32 = 0xA1FF << 16

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
