import Compression
import Foundation
import UIKit

/// A pet package on disk — a folder or a zip/.retopet archive containing
/// `pet.json` plus a spritesheet image, the same shape bundled pets and
/// codex-pets.net downloads already use (see `BundledPet`/`InstalledCodexPet`).
/// This is the "easy registration" install path from C3.3: drop a package
/// into Downloads, or import it directly, and it lands in the same pet
/// catalog as everything else.
enum PetPackageError: Error, LocalizedError, Equatable {
    case missingMetadata
    case invalidMetadata
    case missingSpritesheet
    case invalidSpritesheet
    case invalidGrid
    case invalidArchive
    case emptyID

    var errorDescription: String? {
        switch self {
        case .missingMetadata: "This package has no pet.json."
        case .invalidMetadata: "pet.json couldn't be read — check that it's valid JSON."
        case .missingSpritesheet: "This package's spritesheet image is missing."
        case .invalidSpritesheet: "The spritesheet image couldn't be decoded."
        case .invalidGrid: "The pet's sprite grid isn't a supported size."
        case .invalidArchive: "That file isn't a readable zip archive."
        case .emptyID: "pet.json needs a non-empty \"id\"."
        }
    }
}

private struct PetPackageMetadata: Decodable {
    let id: String
    let displayName: String
    let spritesheetPath: String?
    let columns: Int?
    let rows: Int?
}

enum PetPackageInstaller {
    /// Sprite grids outside this range are rejected as implausible rather
    /// than trusted blindly — this is untrusted, user-supplied input.
    static let gridRange = 1...16

    /// Extensions treated as a pet package when scanning Downloads or
    /// filtering the file importer. `.retopet` is a zip alias.
    static let packageExtensions: Set<String> = ["zip", "retopet"]

    /// Installs a pet package from a folder or a zip/.retopet archive,
    /// validating pet.json, the spritesheet, and the grid before anything
    /// touches `store`'s catalog. Throws a `PetPackageError` describing
    /// exactly what failed.
    @MainActor
    static func install(from url: URL, into store: BrowserPetStore) throws -> InstalledCodexPet {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw PetPackageError.missingMetadata
        }

        let (metadataData, spritesheetData) = isDirectory.boolValue
            ? try readFolder(url)
            : try readArchive(url)

        guard let metadata = try? JSONDecoder().decode(PetPackageMetadata.self, from: metadataData) else {
            throw PetPackageError.invalidMetadata
        }
        let trimmedID = metadata.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { throw PetPackageError.emptyID }

        guard let image = UIImage(data: spritesheetData), let cgImage = image.cgImage else {
            throw PetPackageError.invalidSpritesheet
        }

        let columns = metadata.columns ?? 8
        let rows = metadata.rows ?? 9
        guard gridRange.contains(columns), gridRange.contains(rows) else {
            throw PetPackageError.invalidGrid
        }
        // Use the decoded pixel buffer's own dimensions rather than
        // `UIImage.size` (which is scale-adjusted and can be fractional) —
        // grid cells must divide the real pixel grid evenly.
        let pixelWidth = cgImage.width
        let pixelHeight = cgImage.height
        guard pixelWidth > 0, pixelHeight > 0,
              pixelWidth % columns == 0, pixelHeight % rows == 0 else {
            throw PetPackageError.invalidGrid
        }

        let trimmedDisplayName = metadata.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let pet = InstalledCodexPet(
            id: trimmedID,
            displayName: trimmedDisplayName.isEmpty ? trimmedID : trimmedDisplayName,
            columns: columns,
            rows: rows
        )
        try store.installPet(pet, spritesheetData: spritesheetData)
        return pet
    }

    /// Packages found sitting in `directory` — zip/.retopet files, or
    /// folders that directly contain a `pet.json`.
    static func discoverPackages(in directory: URL) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }
        return entries.filter { url in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
            if isDirectory.boolValue {
                return FileManager.default.fileExists(
                    atPath: url.appendingPathComponent("pet.json").path
                )
            }
            return packageExtensions.contains(url.pathExtension.lowercased())
        }
        .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    private static func readFolder(_ url: URL) throws -> (metadata: Data, spritesheet: Data) {
        guard let metadataData = try? Data(contentsOf: url.appendingPathComponent("pet.json")) else {
            throw PetPackageError.missingMetadata
        }
        guard let metadata = try? JSONDecoder().decode(PetPackageMetadata.self, from: metadataData) else {
            throw PetPackageError.invalidMetadata
        }
        let spritesheetURL = url.appendingPathComponent(metadata.spritesheetPath ?? "spritesheet.webp")
        guard let spritesheetData = try? Data(contentsOf: spritesheetURL) else {
            throw PetPackageError.missingSpritesheet
        }
        return (metadataData, spritesheetData)
    }

    private static func readArchive(_ url: URL) throws -> (metadata: Data, spritesheet: Data) {
        let archiveData: Data
        do {
            archiveData = try Data(contentsOf: url)
        } catch {
            throw PetPackageError.invalidArchive
        }
        let reader = try MinimalZipReader(data: archiveData)
        guard let metadataData = reader.data(namedSuffix: "pet.json") else {
            throw PetPackageError.missingMetadata
        }
        // Parse just far enough to learn the spritesheet's file name before
        // fully validating in `install(from:into:)`.
        let spritesheetHint = (try? JSONDecoder().decode(PetPackageMetadata.self, from: metadataData))?
            .spritesheetPath ?? "spritesheet.webp"
        guard let spritesheetData = reader.data(namedSuffix: spritesheetHint)
            ?? reader.data(namedSuffix: "spritesheet.webp")
            ?? reader.firstImageData() else {
            throw PetPackageError.missingSpritesheet
        }
        return (metadataData, spritesheetData)
    }
}

// MARK: - Minimal ZIP reader

/// A minimal, read-only ZIP reader for small, single-disk, unencrypted
/// archives — exactly what a pet package (pet.json + one spritesheet image)
/// is. Not a general-purpose zip library: no multi-disk archives, no
/// encryption, no Zip64. Written in pure Swift + the system Compression
/// framework so installing a pet package needs no new dependency.
///
/// Compression's `COMPRESSION_ZLIB` algorithm implements raw DEFLATE
/// (RFC 1951) with no zlib header/trailer, which is exactly what ZIP's
/// "deflated" storage method embeds — so entries decode directly with no
/// extra framing to strip.
struct MinimalZipReader {
    private struct Entry {
        let name: String
        let compressionMethod: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private let bytes: [UInt8]
    private let entries: [Entry]

    init(data: Data) throws {
        bytes = [UInt8](data)
        entries = try Self.parseCentralDirectory(bytes)
    }

    /// The bytes of the first entry whose path ends with `suffix`
    /// (case-sensitive — matches both "pet.json" and "my-pet/pet.json").
    func data(namedSuffix suffix: String) -> Data? {
        guard let entry = entries.first(where: { $0.name.hasSuffix(suffix) }) else { return nil }
        return extract(entry)
    }

    /// The first entry that looks like an image by extension — a
    /// last-resort fallback when pet.json omits `spritesheetPath` and no
    /// file is named the conventional "spritesheet.webp".
    func firstImageData() -> Data? {
        let imageExtensions: Set<String> = ["webp", "png", "jpg", "jpeg"]
        guard let entry = entries.first(where: {
            imageExtensions.contains(($0.name as NSString).pathExtension.lowercased())
        }) else {
            return nil
        }
        return extract(entry)
    }

    private func extract(_ entry: Entry) -> Data? {
        guard entry.localHeaderOffset >= 0, entry.localHeaderOffset + 30 <= bytes.count else { return nil }
        let header = bytes[entry.localHeaderOffset..<entry.localHeaderOffset + 30]
        guard header[header.startIndex] == 0x50, header[header.startIndex + 1] == 0x4B,
              header[header.startIndex + 2] == 0x03, header[header.startIndex + 3] == 0x04 else {
            return nil
        }
        let nameLength = Int(Self.readUInt16(bytes, entry.localHeaderOffset + 26))
        let extraLength = Int(Self.readUInt16(bytes, entry.localHeaderOffset + 28))
        let dataStart = entry.localHeaderOffset + 30 + nameLength + extraLength
        let dataEnd = dataStart + entry.compressedSize
        guard dataStart >= 0, dataEnd <= bytes.count, dataStart <= dataEnd else { return nil }
        let compressed = Data(bytes[dataStart..<dataEnd])

        switch entry.compressionMethod {
        case 0:
            return compressed
        case 8:
            return Self.inflate(compressed, expectedSize: entry.uncompressedSize)
        default:
            return nil
        }
    }

    private static func parseCentralDirectory(_ bytes: [UInt8]) throws -> [Entry] {
        guard bytes.count >= 22 else { throw PetPackageError.invalidArchive }

        // The End Of Central Directory record isn't necessarily the last 22
        // bytes — a trailing comment (up to 65535 bytes) can follow it — so
        // scan backward for its signature.
        let searchFloor = max(0, bytes.count - 22 - 65536)
        var eocdOffset: Int?
        var index = bytes.count - 22
        while index >= searchFloor {
            if bytes[index] == 0x50, bytes[index + 1] == 0x4B, bytes[index + 2] == 0x05, bytes[index + 3] == 0x06 {
                eocdOffset = index
                break
            }
            index -= 1
        }
        guard let eocd = eocdOffset else { throw PetPackageError.invalidArchive }

        let entryCount = Int(readUInt16(bytes, eocd + 10))
        let centralDirectoryOffset = Int(readUInt32(bytes, eocd + 16))

        var entries: [Entry] = []
        var cursor = centralDirectoryOffset
        for _ in 0..<entryCount {
            guard cursor >= 0, cursor + 46 <= bytes.count else { break }
            guard bytes[cursor] == 0x50, bytes[cursor + 1] == 0x4B,
                  bytes[cursor + 2] == 0x01, bytes[cursor + 3] == 0x02 else {
                break
            }
            let method = readUInt16(bytes, cursor + 10)
            let compressedSize = Int(readUInt32(bytes, cursor + 20))
            let uncompressedSize = Int(readUInt32(bytes, cursor + 24))
            let nameLength = Int(readUInt16(bytes, cursor + 28))
            let extraLength = Int(readUInt16(bytes, cursor + 30))
            let commentLength = Int(readUInt16(bytes, cursor + 32))
            let localHeaderOffset = Int(readUInt32(bytes, cursor + 42))
            let nameStart = cursor + 46
            let nameEnd = nameStart + nameLength
            guard nameEnd <= bytes.count else { break }
            let name = String(decoding: bytes[nameStart..<nameEnd], as: UTF8.self)
            entries.append(Entry(
                name: name,
                compressionMethod: method,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset
            ))
            cursor = nameEnd + extraLength + commentLength
        }
        guard !entries.isEmpty else { throw PetPackageError.invalidArchive }
        return entries
    }

    private static func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func inflate(_ compressed: Data, expectedSize: Int) -> Data? {
        guard expectedSize > 0 else { return Data() }
        guard !compressed.isEmpty else { return nil }
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: expectedSize)
        defer { destination.deallocate() }
        let decodedCount = compressed.withUnsafeBytes { sourceBuffer -> Int in
            guard let sourcePointer = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(
                destination, expectedSize,
                sourcePointer, compressed.count,
                nil, COMPRESSION_ZLIB
            )
        }
        guard decodedCount == expectedSize else { return nil }
        return Data(bytes: destination, count: decodedCount)
    }
}
