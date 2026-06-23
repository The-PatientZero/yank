import Foundation
import Testing
@testable import YankCore

@Suite struct SyncBlobPolicyTests {
    // A canonical, generator-shaped basename for each kind.
    private let uuid = "9F3A1B2C-4D5E-6F70-8192-A3B4C5D6E7F8"
    private var textName: String { "\(uuid).txt" }
    private var imageName: String { "\(uuid).png" }
    private var richName: String { "\(uuid).plist" }

    // MARK: - SyncBlobKind contract

    @Test func kindExposesAllowedExtensions() {
        #expect(SyncBlobKind.image.allowedExtension == "png")
        #expect(SyncBlobKind.text.allowedExtension == "txt")
        #expect(SyncBlobKind.rich.allowedExtension == "plist")
    }

    @Test func kindExposesByteBudgets() {
        #expect(SyncBlobKind.image.maximumBytes == 32 * 1024 * 1024)
        #expect(SyncBlobKind.text.maximumBytes == 16 * 1024 * 1024)
        #expect(SyncBlobKind.rich.maximumBytes == 16 * 1024 * 1024)
    }

    @Test func policyExposesGlobalBlobBudget() {
        #expect(SyncBlobPolicy.maxSyncedBlobBytes == 32 * 1024 * 1024)
    }

    @Test func kindForImageFlagMapsToImageOrText() {
        #expect(SyncBlobPolicy.kind(isImage: true) == .image)
        #expect(SyncBlobPolicy.kind(isImage: false) == .text)
    }

    // MARK: - validatedFilename: accepted canonical forms

    @Test func acceptsCanonicalTextFilename() {
        #expect(SyncBlobPolicy.validatedFilename(textName, kind: .text) == textName)
    }

    @Test func acceptsCanonicalImageFilename() {
        #expect(SyncBlobPolicy.validatedFilename(imageName, kind: .image) == imageName)
    }

    @Test func acceptsCanonicalRichFilename() {
        #expect(SyncBlobPolicy.validatedFilename(richName, kind: .rich) == richName)
    }

    @Test func acceptsLowercaseUUIDStem() {
        let lower = "\(uuid.lowercased()).txt"
        #expect(SyncBlobPolicy.validatedFilename(lower, kind: .text) == lower)
    }

    @Test func acceptsUppercaseExtensionCaseInsensitively() {
        // `pathExtension.lowercased()` is compared, so a mixed-case extension is still valid,
        // and the original (untouched) filename is returned.
        let upper = "\(uuid).TXT"
        #expect(SyncBlobPolicy.validatedFilename(upper, kind: .text) == upper)
    }

    // MARK: - validatedFilename: path-traversal rejection

    @Test func rejectsParentDirectoryTraversal() {
        #expect(SyncBlobPolicy.validatedFilename("..", kind: .text) == nil)
        #expect(SyncBlobPolicy.validatedFilename("../\(textName)", kind: .text) == nil)
        #expect(SyncBlobPolicy.validatedFilename("../../etc/passwd", kind: .text) == nil)
    }

    @Test func rejectsCurrentDirectoryToken() {
        #expect(SyncBlobPolicy.validatedFilename(".", kind: .text) == nil)
    }

    @Test func rejectsAbsolutePaths() {
        #expect(SyncBlobPolicy.validatedFilename("/\(textName)", kind: .text) == nil)
        #expect(SyncBlobPolicy.validatedFilename("/tmp/\(textName)", kind: .text) == nil)
    }

    @Test func rejectsEmbeddedForwardSlashes() {
        #expect(SyncBlobPolicy.validatedFilename("sub/\(textName)", kind: .text) == nil)
        #expect(SyncBlobPolicy.validatedFilename("nested/dir/\(textName)", kind: .text) == nil)
    }

    @Test func rejectsEmbeddedBackslashes() {
        #expect(SyncBlobPolicy.validatedFilename("sub\\\(textName)", kind: .text) == nil)
        #expect(SyncBlobPolicy.validatedFilename("\\\(textName)", kind: .text) == nil)
    }

    @Test func rejectsColonSeparator() {
        // Colon is an HFS path separator on classic macOS volumes and is explicitly blocked.
        #expect(SyncBlobPolicy.validatedFilename("vol:\(textName)", kind: .text) == nil)
        #expect(SyncBlobPolicy.validatedFilename("\(uuid):txt", kind: .text) == nil)
    }

    @Test func rejectsEmbeddedNullByte() {
        // A null byte truncates path parsing; the stem can no longer parse as a UUID.
        let withNull = "\(uuid)\u{0000}.txt"
        #expect(SyncBlobPolicy.validatedFilename(withNull, kind: .text) == nil)
    }

    // MARK: - validatedFilename: whitespace / emptiness rejection

    @Test func rejectsEmptyFilename() {
        #expect(SyncBlobPolicy.validatedFilename("", kind: .text) == nil)
    }

    @Test func rejectsUntrimmedWhitespace() {
        #expect(SyncBlobPolicy.validatedFilename(" \(textName)", kind: .text) == nil)
        #expect(SyncBlobPolicy.validatedFilename("\(textName) ", kind: .text) == nil)
        #expect(SyncBlobPolicy.validatedFilename("\(textName)\n", kind: .text) == nil)
        #expect(SyncBlobPolicy.validatedFilename("\t\(textName)", kind: .text) == nil)
    }

    // MARK: - validatedFilename: extension / kind mismatch

    @Test func rejectsExtensionThatDoesNotMatchKind() {
        #expect(SyncBlobPolicy.validatedFilename(imageName, kind: .text) == nil)
        #expect(SyncBlobPolicy.validatedFilename(textName, kind: .image) == nil)
        #expect(SyncBlobPolicy.validatedFilename(textName, kind: .rich) == nil)
        #expect(SyncBlobPolicy.validatedFilename(richName, kind: .image) == nil)
    }

    @Test func rejectsMissingExtension() {
        #expect(SyncBlobPolicy.validatedFilename(uuid, kind: .text) == nil)
    }

    @Test func rejectsForeignExtension() {
        #expect(SyncBlobPolicy.validatedFilename("\(uuid).json", kind: .text) == nil)
        #expect(SyncBlobPolicy.validatedFilename("\(uuid).exe", kind: .image) == nil)
    }

    // MARK: - validatedFilename: stem must be a UUID

    @Test func rejectsNonUUIDStem() {
        #expect(SyncBlobPolicy.validatedFilename("not-a-uuid.txt", kind: .text) == nil)
        #expect(SyncBlobPolicy.validatedFilename("history.txt", kind: .text) == nil)
        #expect(SyncBlobPolicy.validatedFilename("12345.png", kind: .image) == nil)
    }

    @Test func rejectsUUIDStemWithTrailingSuffix() {
        // The stem is everything before the trailing `.<ext>`; an extra suffix breaks UUID parsing.
        #expect(SyncBlobPolicy.validatedFilename("\(uuid)-copy.txt", kind: .text) == nil)
        #expect(SyncBlobPolicy.validatedFilename("\(uuid).backup.txt", kind: .text) == nil)
    }

    // MARK: - canonical convenience accessors

    @Test func canonicalAccessorsForwardToValidatedFilename() {
        #expect(SyncBlobPolicy.canonicalTextFilename(textName) == textName)
        #expect(SyncBlobPolicy.canonicalImageFilename(imageName) == imageName)
        #expect(SyncBlobPolicy.canonicalRichFilename(richName) == richName)
    }

    @Test func canonicalAccessorsRejectMismatchedKinds() {
        #expect(SyncBlobPolicy.canonicalTextFilename(imageName) == nil)
        #expect(SyncBlobPolicy.canonicalImageFilename(textName) == nil)
        #expect(SyncBlobPolicy.canonicalRichFilename(textName) == nil)
    }

    @Test func canonicalAccessorsPassThroughNil() {
        #expect(SyncBlobPolicy.canonicalTextFilename(nil) == nil)
        #expect(SyncBlobPolicy.canonicalImageFilename(nil) == nil)
        #expect(SyncBlobPolicy.canonicalRichFilename(nil) == nil)
    }

    @Test func canonicalAccessorsRejectTraversal() {
        #expect(SyncBlobPolicy.canonicalTextFilename("../\(textName)") == nil)
        #expect(SyncBlobPolicy.canonicalImageFilename("/tmp/\(imageName)") == nil)
    }

    // MARK: - containedURL: containment enforcement

    private func freshDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("yank-blob-policy-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func containedURLResolvesValidFilenameInsideDirectory() throws {
        let base = freshDirectory()
        let url = try #require(SyncBlobPolicy.containedURL(directory: base, filename: textName, kind: .text))
        #expect(url.lastPathComponent == textName)
        #expect(url.deletingLastPathComponent().standardizedFileURL.path == base.standardizedFileURL.path)
    }

    @Test func containedURLRejectsTraversalFilename() {
        let base = freshDirectory()
        #expect(SyncBlobPolicy.containedURL(directory: base, filename: "../escape.txt", kind: .text) == nil)
        #expect(SyncBlobPolicy.containedURL(directory: base, filename: "../../\(textName)", kind: .text) == nil)
    }

    @Test func containedURLRejectsKindMismatch() {
        let base = freshDirectory()
        #expect(SyncBlobPolicy.containedURL(directory: base, filename: imageName, kind: .text) == nil)
    }

    @Test func containedURLRejectsNonUUIDFilename() {
        let base = freshDirectory()
        #expect(SyncBlobPolicy.containedURL(directory: base, filename: "not-a-uuid.txt", kind: .text) == nil)
    }

    // MARK: - SyncBlobReference

    @Test func referenceInitAcceptsCanonicalFilename() throws {
        let ref = try #require(SyncBlobReference(filename: imageName, kind: .image))
        #expect(ref.filename == imageName)
        #expect(ref.kind == .image)
    }

    @Test func referenceInitReturnsNilForNilFilename() {
        #expect(SyncBlobReference(filename: nil, kind: .text) == nil)
    }

    @Test func referenceInitRejectsTraversalAndMismatch() {
        #expect(SyncBlobReference(filename: "../\(textName)", kind: .text) == nil)
        #expect(SyncBlobReference(filename: imageName, kind: .text) == nil)
        #expect(SyncBlobReference(filename: "not-a-uuid.txt", kind: .text) == nil)
    }

    @Test func referenceExposesKindByteBudget() throws {
        let image = try #require(SyncBlobReference(filename: imageName, kind: .image))
        let text = try #require(SyncBlobReference(filename: textName, kind: .text))
        #expect(image.maximumBytes == 32 * 1024 * 1024)
        #expect(text.maximumBytes == 16 * 1024 * 1024)
    }

    @Test func referenceContainedURLDelegatesToPolicy() throws {
        let base = freshDirectory()
        let ref = try #require(SyncBlobReference(filename: textName, kind: .text))
        let url = try #require(ref.containedURL(in: base))
        #expect(url.lastPathComponent == textName)
        #expect(url.deletingLastPathComponent().standardizedFileURL.path == base.standardizedFileURL.path)
    }

    @Test func referenceEquatabilityReflectsFilenameAndKind() throws {
        let a = try #require(SyncBlobReference(filename: textName, kind: .text))
        let b = try #require(SyncBlobReference(filename: textName, kind: .text))
        #expect(a == b)
    }
}
