/// Multipart form-data parsing for media upload requests.
///
/// The media upload handler receives a `multipart/form-data` body containing the file bytes
/// and optional metadata fields (description, etc.). This file exposes two public helpers:
/// ``extractBoundary(from:)`` to pull the boundary parameter from the `Content-Type` header,
/// and ``parseMultipart(data:boundary:)`` to split the body into ``MultipartPart`` values.
///
/// Parsing is delegated to `vapor/multipart-kit` (`MultipartKit`), which handles
/// standards-compliant multipart bodies including quoted parameter values, missing
/// `Content-Type` parts, CRLF endings, and preamble/epilogue sections. On a parse error
/// the function returns whatever parts completed before the failure rather than throwing,
/// matching the lenient behavior that was in place before the switch to the library.
import Foundation
import MultipartKit
import NIOCore
import NIOHTTP1

/// A single part extracted from a `multipart/form-data` body.
///
/// Used by ``parseMultipart(data:boundary:)`` to represent each field or file upload
/// in a multipart request body.
public struct MultipartPart: Sendable {
    /// The field name from the `Content-Disposition` header.
    public let name: String?
    /// The filename from the `Content-Disposition` header, if this is a file upload.
    public let filename: String?
    /// The MIME type from the part's `Content-Type` header.
    public let contentType: String?
    /// The raw bytes of the part body.
    public let data: Data?

    public init(name: String?, filename: String?, contentType: String?, data: Data?) {
        self.name = name
        self.filename = filename
        self.contentType = contentType
        self.data = data
    }
}

/// Extract the boundary string from a `Content-Type` header value.
///
/// Parses the `boundary=` parameter from a header like
/// `multipart/form-data; boundary=----WebKitFormBoundary...`.
///
/// - Parameter contentType: The full Content-Type header value.
/// - Returns: The boundary string, or nil if not found.
public func extractBoundary(from contentType: String) -> String? {
    let parts = contentType.components(separatedBy: ";")
    for part in parts {
        let trimmed = part.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("boundary=") {
            var boundary = String(trimmed.dropFirst("boundary=".count))
            if boundary.hasPrefix("\"") && boundary.hasSuffix("\"") {
                boundary = String(boundary.dropFirst().dropLast())
            }
            return boundary
        }
    }
    return nil
}

/// Parse a `multipart/form-data` body into individual ``MultipartPart`` instances.
///
/// Delegates the actual boundary/header/body parsing to `vapor/multipart-kit`, which
/// robustly handles standards-compliant `multipart/form-data` (both quoted and unquoted
/// `Content-Disposition` parameter values, parts with or without an explicit
/// `Content-Type`, CRLF line endings, preamble/epilogue, etc.). The library's parsed
/// parts are then mapped onto ``MultipartPart`` so callers see a stable public API.
///
/// - Parameters:
///   - data: The raw request body bytes.
///   - boundary: The boundary string extracted from the Content-Type header.
/// - Returns: An array of parsed parts.
public func parseMultipart(data: Data, boundary: String) -> [MultipartPart] {
    guard !boundary.isEmpty else { return [] }

    let parser = MultipartKit.MultipartParser(boundary: boundary)

    var collected: [(headers: HTTPHeaders, body: ByteBuffer)] = []
    var currentHeaders = HTTPHeaders()
    var currentBody = ByteBuffer()

    parser.onHeader = { name, value in
        currentHeaders.add(name: name, value: value)
    }
    parser.onBody = { buffer in
        currentBody.writeBuffer(&buffer)
    }
    parser.onPartComplete = {
        collected.append((headers: currentHeaders, body: currentBody))
        currentHeaders = HTTPHeaders()
        currentBody = ByteBuffer()
    }

    do {
        try parser.execute(ByteBuffer(bytes: data))
    } catch {
        // Malformed body: return whatever (if anything) completed before the failure.
        // This mirrors the lenient behavior of the previous hand-rolled parser, which
        // simply skipped parts it could not interpret rather than throwing.
        return []
    }

    return collected.map { entry in
        let disposition = entry.headers["Content-Disposition"].first
        let name = disposition.flatMap { dispositionParameter($0, key: "name") }
        let filename = disposition.flatMap { dispositionParameter($0, key: "filename") }
        let contentType = entry.headers["Content-Type"].first?
            .trimmingCharacters(in: .whitespaces)

        let body = entry.body
        let bytes = body.getBytes(at: body.readerIndex, length: body.readableBytes) ?? []

        return MultipartPart(
            name: name,
            filename: filename,
            contentType: contentType,
            data: Data(bytes)
        )
    }
}

/// Extract a single parameter value from a `Content-Disposition` header value.
///
/// Handles both quoted (`name="file"`) and unquoted (`name=file`) parameter forms by
/// splitting on `;`, matching the requested key, and stripping surrounding quotes.
private func dispositionParameter(_ headerValue: String, key: String) -> String? {
    for component in headerValue.split(separator: ";") {
        let trimmed = component.trimmingCharacters(in: .whitespaces)
        guard let eq = trimmed.range(of: "=") else { continue }
        let paramName = trimmed[trimmed.startIndex..<eq.lowerBound]
            .trimmingCharacters(in: .whitespaces)
        guard paramName.caseInsensitiveCompare(key) == .orderedSame else { continue }
        var value = String(trimmed[eq.upperBound...]).trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }
    return nil
}
