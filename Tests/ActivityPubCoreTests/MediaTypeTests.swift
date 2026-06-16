import Testing
import Foundation
@testable import ActivityPubCore

@Suite("Media type detection")
struct MediaTypeTests {

    // Magic-byte fixtures.
    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46])
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00])
    private let gif = Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00])
    private let webp = Data([0x52, 0x49, 0x46, 0x46, 0x24, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50])
    private let heic = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63])
    private let mp4 = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D])

    @Test("Sniffs image magic bytes")
    func sniffsImages() {
        #expect(MediaType.contentType(forFileData: jpeg, filename: nil, declared: nil) == "image/jpeg")
        #expect(MediaType.contentType(forFileData: png, filename: nil, declared: nil) == "image/png")
        #expect(MediaType.contentType(forFileData: gif, filename: nil, declared: nil) == "image/gif")
        #expect(MediaType.contentType(forFileData: webp, filename: nil, declared: nil) == "image/webp")
        #expect(MediaType.contentType(forFileData: heic, filename: nil, declared: nil) == "image/heic")
        #expect(MediaType.contentType(forFileData: mp4, filename: nil, declared: nil) == "video/mp4")
    }

    @Test("Bytes win over a bogus text/plain part type (the real-world bug)")
    func bytesOverrideDeclaredTextPlain() {
        // swift-openapi clients send the file part as text/plain; the bytes must take precedence.
        #expect(MediaType.contentType(forFileData: jpeg, filename: "upload.jpeg", declared: "text/plain") == "image/jpeg")
        #expect(MediaType.contentType(forFileData: png, filename: "upload.png", declared: "text/plain") == "image/png")
    }

    @Test("Falls back to the filename extension when bytes are unrecognized")
    func extensionFallback() {
        let unknown = Data([0x00, 0x01, 0x02, 0x03, 0x04])
        #expect(MediaType.contentType(forFileData: unknown, filename: "photo.jpg", declared: "text/plain") == "image/jpeg")
        #expect(MediaType.contentType(forFileData: unknown, filename: "clip.MOV", declared: nil) == "video/quicktime")
    }

    @Test("Honors a concrete declared type only as a last resort")
    func declaredLastResort() {
        let unknown = Data([0x00, 0x01, 0x02, 0x03, 0x04])
        #expect(MediaType.contentType(forFileData: unknown, filename: "noext", declared: "image/avif") == "image/avif")
        // A generic/text declared type with no other evidence degrades to octet-stream.
        #expect(MediaType.contentType(forFileData: unknown, filename: "noext", declared: "text/plain") == "application/octet-stream")
        #expect(MediaType.contentType(forFileData: unknown, filename: nil, declared: nil) == "application/octet-stream")
    }

    @Test("Buffers too short to sniff degrade gracefully")
    func shortBuffers() {
        // Fewer than 4 bytes can't match any signature; fall through to extension, then octet-stream.
        let tiny = Data([0xFF, 0xD8])  // looks JPEG-ish but too short to confirm
        #expect(MediaType.contentType(forFileData: tiny, filename: nil, declared: nil) == "application/octet-stream")
        #expect(MediaType.contentType(forFileData: tiny, filename: "x.png", declared: nil) == "image/png")
        #expect(MediaType.contentType(forFileData: Data(), filename: nil, declared: "image/jpeg") == "image/jpeg")
    }

    @Test("preferredExtension maps content types to safe extensions")
    func preferredExtensions() {
        #expect(MediaType.preferredExtension(forContentType: "image/jpeg") == "jpg")
        #expect(MediaType.preferredExtension(forContentType: "image/png") == "png")
        #expect(MediaType.preferredExtension(forContentType: "image/webp") == "webp")
        #expect(MediaType.preferredExtension(forContentType: "video/mp4") == "mp4")
        #expect(MediaType.preferredExtension(forContentType: "application/octet-stream") == "bin")
        #expect(MediaType.preferredExtension(forContentType: "text/plain") == "bin")
    }

    @Test("isImageURL keys off the path extension")
    func imageURLDetection() {
        #expect(MediaType.isImageURL("https://happitec.com/media/ABC123/upload.jpeg"))
        #expect(MediaType.isImageURL("https://happitec.com/media/ABC123/latest-logo.png"))
        #expect(!MediaType.isImageURL("https://happitec.com/media/ABC123/notes.txt"))
        #expect(!MediaType.isImageURL("https://happitec.com/media/ABC123/noextension"))
    }

    @Test("MediaAttachmentRef.isImage covers both content type and URL extension")
    func attachmentIsImage() {
        // Correct content type → image.
        let typed = MediaAttachmentRef(id: "1", url: "https://x/y/a.bin", contentType: "image/png", description: nil, blurhash: nil)
        #expect(typed.isImage)
        // Wrong content type (the bug) but image URL → still recognized as image.
        let mislabeled = MediaAttachmentRef(id: "2", url: "https://happitec.com/media/Z/upload.jpeg", contentType: "text/plain", description: nil, blurhash: nil)
        #expect(mislabeled.isImage)
        // Neither → not an image.
        let doc = MediaAttachmentRef(id: "3", url: "https://x/y/file.pdf", contentType: "application/pdf", description: nil, blurhash: nil)
        #expect(!doc.isImage)
    }
}
