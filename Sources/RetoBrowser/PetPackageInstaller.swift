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
    case unsafePath
    case archiveTooLarge

    var errorDescription: String? {
        switch self {
        case .missingMetadata: "This package has no pet.json."
        case .invalidMetadata: "pet.json couldn't be read — check that it's valid JSON."
        case .missingSpritesheet: "This package's spritesheet image is missing."
        case .invalidSpritesheet: "The spritesheet image couldn't be decoded."
        case .invalidGrid: "The pet's sprite grid isn't a supported size."
        case .invalidArchive: "That file isn't a readable zip archive."
        case .emptyID: "pet.json needs a non-empty \"id\"."
        case .unsafePath: "This package points at a file path outside the package — that isn't allowed."
        case .archiveTooLarge: "This package is too large, or claims an implausible amount of decompressed data."
        }
    }
}

/// Validates untrusted, package-supplied strings before they ever become a
/// filesystem path — the pet ID (used directly as an install directory
/// name), the folder package's `spritesheetPath`, and every ZIP entry name
/// all flow through here. Rejects zip-slip-style traversal
/// (`../../../etc/passwd`), absolute paths, and Windows-style drive/backslash
/// paths, none of which a legitimate pet package ever needs.
enum PathSafety {
    /// A path that may contain `/`-separated directory components (a ZIP
    /// entry name, or a folder package's `spritesheetPath`) but must stay
    /// relative and must never contain a `..` traversal segment.
    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.utf8.contains(0), !path.contains("\\") else { return false }
        guard !path.hasPrefix("/"), !path.hasPrefix("~") else { return false }
        // A Windows drive letter ("C:...") is absolute on the platform
        // that authored the archive even though it isn't a path separator
        // here — reject it rather than let it slip through as "relative".
        if path.count >= 2, path[path.index(path.startIndex, offsetBy: 1)] == ":" {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty else { return false }
        return !components.contains { $0 == ".." || $0 == "." }
    }

    /// A single path *component* — e.g. a pet ID that gets used directly as
    /// a directory name — must not itself be a separator or traversal
    /// segment.
    static func isSafePathComponent(_ component: String) -> Bool {
        guard !component.isEmpty, !component.utf8.contains(0) else { return false }
        guard component != ".", component != ".." else { return false }
        return !component.contains("/") && !component.contains("\\")
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
        // `id` becomes a directory name verbatim in `BrowserPetStore.installPet`
        // — reject anything that could escape that directory (e.g. "../../
        // Library/Preferences/x") before it ever reaches the filesystem.
        guard PathSafety.isSafePathComponent(trimmedID) else { throw PetPackageError.unsafePath }

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
        let relativeSpritesheetPath = metadata.spritesheetPath ?? "spritesheet.webp"
        guard PathSafety.isSafeRelativePath(relativeSpritesheetPath) else {
            throw PetPackageError.unsafePath
        }
        let spritesheetURL = url.appendingPathComponent(relativeSpritesheetPath)
        // Defense in depth beyond the string check above: `resolvingSymlinksInPath()`
        // (unlike `standardizedFileURL`) actually follows symlinks, so this
        // also catches a package that plants a symlink pointing outside the
        // folder and references it by an innocuous-looking relative name.
        let root = url.resolvingSymlinksInPath().path
        let rootPrefix = root.hasSuffix("/") ? root : root + "/"
        let resolvedTarget = spritesheetURL.resolvingSymlinksInPath().path
        guard resolvedTarget == root || resolvedTarget.hasPrefix(rootPrefix) else {
            throw PetPackageError.unsafePath
        }
        guard let spritesheetData = try? Data(contentsOf: spritesheetURL) else {
            throw PetPackageError.missingSpritesheet
        }
        return (metadataData, spritesheetData)
    }

    private static func readArchive(_ url: URL) throws -> (metadata: Data, spritesheet: Data) {
        // Check the file size on disk before reading it fully into memory —
        // a multi-gigabyte download shouldn't get that far just to be
        // rejected after the fact.
        if let onDiskSize = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
           onDiskSize > MinimalZipReader.maxArchiveFileSize {
            throw PetPackageError.archiveTooLarge
        }
        let archiveData: Data
        do {
            archiveData = try Data(contentsOf: url)
        } catch {
            throw PetPackageError.invalidArchive
        }
        guard archiveData.count <= MinimalZipReader.maxArchiveFileSize else {
            throw PetPackageError.archiveTooLarge
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

        /// ZIP has no dedicated directory-entry flag — by convention a
        /// trailing "/" marks one. Directory entries carry no content and
        /// must never be handed out as if they were pet.json or a
        /// spritesheet.
        var isDirectory: Bool { name.hasSuffix("/") }
    }

    /// Hard caps against zip bombs and pathological archives. A pet
    /// package is pet.json plus a small handful of images, so these are
    /// generous relative to that while still bounding how much memory and
    /// CPU a malicious download can force us to spend before we've
    /// validated anything.
    static let maxArchiveFileSize = 64 * 1024 * 1024        // 64 MB on disk
    private static let maxEntryCount = 256
    private static let maxUncompressedEntrySize = 64 * 1024 * 1024   // 64 MB per entry
    private static let maxTotalUncompressedSize = 128 * 1024 * 1024  // 128 MB across all entries
    // Below this, an entry's compression ratio isn't checked at all — a
    // handful of KB of highly-compressible solid color is normal, not a
    // bomb. Above it, DEFLATE ratios climb rapidly for adversarial input
    // (repeating zero bytes), so a generous but finite cap catches bombs
    // without flagging ordinary images.
    private static let ratioCheckFloor = 1 * 1024 * 1024
    private static let maxCompressionRatio = 200

    private let bytes: [UInt8]
    private let entries: [Entry]

    init(data: Data) throws {
        bytes = [UInt8](data)
        entries = try Self.parseCentralDirectory(bytes)
    }

    /// The bytes of the first non-directory entry whose path ends with
    /// `suffix` (case-sensitive — matches both "pet.json" and
    /// "my-pet/pet.json").
    func data(namedSuffix suffix: String) -> Data? {
        guard let entry = entries.first(where: { !$0.isDirectory && $0.name.hasSuffix(suffix) }) else { return nil }
        return extract(entry)
    }

    /// The first non-directory entry that looks like an image by
    /// extension — a last-resort fallback when pet.json omits
    /// `spritesheetPath` and no file is named the conventional
    /// "spritesheet.webp".
    func firstImageData() -> Data? {
        let imageExtensions: Set<String> = ["webp", "png", "jpg", "jpeg"]
        guard let entry = entries.first(where: {
            !$0.isDirectory && imageExtensions.contains(($0.name as NSString).pathExtension.lowercased())
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
        guard entryCount > 0 else { throw PetPackageError.invalidArchive }
        guard entryCount <= maxEntryCount else { throw PetPackageError.archiveTooLarge }
        let centralDirectoryOffset = Int(readUInt32(bytes, eocd + 16))
        guard centralDirectoryOffset >= 0 else { throw PetPackageError.invalidArchive }

        var entries: [Entry] = []
        var seenNames = Set<String>()
        var totalUncompressedSize = 0
        var cursor = centralDirectoryOffset
        for _ in 0..<entryCount {
            // Every field below is read from the archive itself — never
            // trust it against the actual byte count until it's been
            // checked. A truncated or malformed central directory throws
            // rather than silently returning a partial entry list.
            guard cursor >= 0, cursor + 46 <= bytes.count else { throw PetPackageError.invalidArchive }
            guard bytes[cursor] == 0x50, bytes[cursor + 1] == 0x4B,
                  bytes[cursor + 2] == 0x01, bytes[cursor + 3] == 0x02 else {
                throw PetPackageError.invalidArchive
            }
            let method = readUInt16(bytes, cursor + 10)
            let compressedSize = Int(readUInt32(bytes, cursor + 20))
            let uncompressedSize = Int(readUInt32(bytes, cursor + 24))
            let nameLength = Int(readUInt16(bytes, cursor + 28))
            let extraLength = Int(readUInt16(bytes, cursor + 30))
            let commentLength = Int(readUInt16(bytes, cursor + 32))
            let externalAttributes = readUInt32(bytes, cursor + 38)
            let localHeaderOffset = Int(readUInt32(bytes, cursor + 42))
            let nameStart = cursor + 46
            let nameEnd = nameStart + nameLength
            guard nameLength > 0, nameEnd <= bytes.count else { throw PetPackageError.invalidArchive }
            let name = String(decoding: bytes[nameStart..<nameEnd], as: UTF8.self)

            // Zip-slip: an entry name that escapes the extraction
            // directory (e.g. "../../../../Library/Preferences/x.plist")
            // or is otherwise absolute.
            guard PathSafety.isSafeRelativePath(name) else { throw PetPackageError.unsafePath }

            // Symlink entries carry the Unix S_IFLNK bit in the top 16
            // bits of the external file attributes. We never resolve or
            // follow archive-declared symlinks — reject the archive.
            let unixFileType = UInt32((externalAttributes >> 16) & 0xF000)
            guard unixFileType != 0xA000 else { throw PetPackageError.unsafePath }

            // Zip-bomb: bound both the single largest entry and the sum of
            // every entry's *declared* uncompressed size, before ever
            // allocating a buffer to inflate into.
            guard uncompressedSize <= maxUncompressedEntrySize else { throw PetPackageError.archiveTooLarge }
            if compressedSize == 0 {
                // Zero compressed bytes can only ever decode to zero
                // uncompressed bytes — anything else is a fabricated,
                // impossible size field.
                guard uncompressedSize == 0 else { throw PetPackageError.archiveTooLarge }
            } else if uncompressedSize > ratioCheckFloor {
                guard uncompressedSize / compressedSize <= maxCompressionRatio else {
                    throw PetPackageError.archiveTooLarge
                }
            }
            totalUncompressedSize += uncompressedSize
            guard totalUncompressedSize <= maxTotalUncompressedSize else { throw PetPackageError.archiveTooLarge }

            // Duplicate names are ambiguous at best (which one is "the"
            // pet.json?) and a classic tool-confusion trick at worst.
            guard seenNames.insert(name).inserted else { throw PetPackageError.invalidArchive }

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
