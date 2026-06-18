/// Determines the true content type of uploaded media files.
///
/// The swift-openapi-generator client labels every multipart part `text/plain` when the
/// OpenAPI spec omits an `encoding` block. Because of that, `MediaUploadHandler` cannot
/// trust the declared content type from the client and calls
/// ``MediaType/contentType(forFileData:filename:declared:)`` instead. The function inspects
/// the file's magic bytes first, falls back to the filename extension, and only accepts a
/// declared type when it looks like a real media type rather than the `text/plain` placeholder.
///
/// ``MediaType/preferredExtension(forContentType:)`` is used by `MediaUploadHandler` when
/// constructing the S3 storage key, so the key extension is always derived from the
/// server-resolved type and never from client-supplied input.
import Foundation

/// Determines the true content type of uploaded media from its bytes.
///
/// swift-openapi clients label every multipart part `text/plain` — the generator hardcodes that
/// when the spec declares no `encoding` block — so a client-declared part content type is not
/// trustworthy. The server owns the type: sniff the file's magic bytes first, fall back to the
/// filename extension, and only honor a declared type when it's already a concrete media type.
public enum MediaType {

    /// Best content type for an uploaded file, preferring evidence from the bytes themselves.
    public static func contentType(forFileData data: Data, filename: String?, declared: String?) -> String {
        if let sniffed = sniff(data) {
            return sniffed
        }
        if let ext = filename.flatMap(fileExtension), let byExt = byExtension[ext] {
            return byExt
        }
        if let declared, isConcreteMediaType(declared) {
            return declared
        }
        return "application/octet-stream"
    }

    /// Identify a media type from leading magic bytes. Returns nil when the signature is unknown.
    static func sniff(_ data: Data) -> String? {
        let b = [UInt8](data.prefix(16))
        guard b.count >= 4 else { return nil }

        // JPEG: FF D8 FF
        if b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return "image/jpeg" }
        // PNG: 89 50 4E 47 0D 0A 1A 0A
        if b.count >= 8, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47,
           b[4] == 0x0D, b[5] == 0x0A, b[6] == 0x1A, b[7] == 0x0A { return "image/png" }
        // GIF: "GIF8"
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46, b[3] == 0x38 { return "image/gif" }
        // WebP: "RIFF" .... "WEBP"
        if b.count >= 12, b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return "image/webp" }
        // ISO base media (HEIC / MP4): bytes 4..8 == "ftyp", brand at 8..12.
        if b.count >= 12, b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 {
            let brand = String(bytes: b[8..<12], encoding: .ascii) ?? ""
            if heicBrands.contains(brand) { return "image/heic" }
            if mp4Brands.contains(brand) { return "video/mp4" }
        }
        return nil
    }

    /// Whether an attachment URL points at an image, judged by its path extension.
    /// Lets the web renderer show images that were stored before content-type sniffing existed.
    public static func isImageURL(_ urlString: String) -> Bool {
        let path = URL(string: urlString)?.path ?? urlString
        guard let ext = fileExtension(path) else { return false }
        return byExtension[ext]?.hasPrefix("image/") ?? false
    }

    /// Extract the lowercased file extension from a filename or path, or `nil` if none is present.
    static func fileExtension(_ name: String) -> String? {
        guard let dot = name.lastIndex(of: "."), dot < name.endIndex else { return nil }
        let ext = name[name.index(after: dot)...]
        guard !ext.isEmpty, !ext.contains("/") else { return nil }
        return ext.lowercased()
    }

    /// A safe filename extension for a resolved content type, for server-generated storage keys.
    /// Never derived from client input, so it can't carry a path/key-injection payload.
    public static func preferredExtension(forContentType contentType: String) -> String {
        byContentType[contentType.lowercased()] ?? "bin"
    }

    /// Returns `true` when the string looks like a real image, video, or audio media type,
    /// as opposed to `text/plain` or `application/octet-stream` placeholders.
    static func isConcreteMediaType(_ s: String) -> Bool {
        let lower = s.lowercased()
        return lower.hasPrefix("image/") || lower.hasPrefix("video/") || lower.hasPrefix("audio/")
    }

    /// Maps file extensions (lowercase, no dot) to IANA media type strings.
    static let byExtension: [String: String] = [
        "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "gif": "image/gif",
        "webp": "image/webp", "heic": "image/heic", "heif": "image/heic",
        "mp4": "video/mp4", "mov": "video/quicktime",
    ]

    /// Maps IANA media type strings (lowercase) to the preferred file extension for S3 key generation.
    static let byContentType: [String: String] = [
        "image/jpeg": "jpg", "image/png": "png", "image/gif": "gif", "image/webp": "webp",
        "image/heic": "heic", "image/heif": "heic", "video/mp4": "mp4", "video/quicktime": "mov",
    ]

    /// ISO base media file brands that identify HEIC/HEIF still images.
    static let heicBrands: Set<String> = ["heic", "heix", "heif", "hevc", "mif1", "msf1"]
    /// ISO base media file brands that identify MP4 video containers.
    static let mp4Brands: Set<String> = ["mp42", "mp41", "isom", "iso2", "avc1", "M4V ", "dash"]
}

extension MediaAttachmentRef {
    /// Whether this attachment should render as an inline image on the web profile.
    public var isImage: Bool {
        contentType.hasPrefix("image/") || MediaType.isImageURL(url)
    }
}
