import Foundation

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
/// Splits the body on boundary markers and extracts headers and body data for each part.
///
/// - Parameters:
///   - data: The raw request body bytes.
///   - boundary: The boundary string extracted from the Content-Type header.
/// - Returns: An array of parsed parts.
public func parseMultipart(data: Data, boundary: String) -> [MultipartPart] {
    let boundaryData = Data("--\(boundary)".utf8)
    let crlfData = Data("\r\n".utf8)
    let doubleCRLF = Data("\r\n\r\n".utf8)

    var parts: [MultipartPart] = []

    var ranges: [Range<Data.Index>] = []
    var searchStart = data.startIndex

    while let range = data.range(of: boundaryData, in: searchStart..<data.endIndex) {
        ranges.append(range)
        searchStart = range.upperBound
    }

    for i in 0..<(ranges.count - 1) {
        let partStart = ranges[i].upperBound
        let partEnd = ranges[i + 1].lowerBound

        var contentStart = partStart
        if contentStart + crlfData.count <= partEnd,
           data[contentStart..<contentStart + crlfData.count] == crlfData {
            contentStart += crlfData.count
        }

        var contentEnd = partEnd
        if contentEnd >= crlfData.count,
           data[contentEnd - crlfData.count..<contentEnd] == crlfData {
            contentEnd -= crlfData.count
        }

        guard contentStart < contentEnd else { continue }

        let partData = data[contentStart..<contentEnd]

        guard let headerEnd = partData.range(of: doubleCRLF) else { continue }

        let headerData = partData[partData.startIndex..<headerEnd.lowerBound]
        let bodyData = partData[headerEnd.upperBound..<partData.endIndex]

        guard let headerString = String(data: headerData, encoding: .utf8) else { continue }

        var name: String?
        var filename: String?
        var contentType: String?

        for line in headerString.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-disposition:") {
                if let nameRange = line.range(of: "name=\"") {
                    let afterName = line[nameRange.upperBound...]
                    if let endQuote = afterName.firstIndex(of: "\"") {
                        name = String(afterName[..<endQuote])
                    }
                }
                if let fnRange = line.range(of: "filename=\"") {
                    let afterFn = line[fnRange.upperBound...]
                    if let endQuote = afterFn.firstIndex(of: "\"") {
                        filename = String(afterFn[..<endQuote])
                    }
                }
            } else if lower.hasPrefix("content-type:") {
                contentType = line.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
            }
        }

        parts.append(MultipartPart(
            name: name,
            filename: filename,
            contentType: contentType,
            data: Data(bodyData)
        ))
    }

    return parts
}
