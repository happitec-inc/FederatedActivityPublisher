import Testing
import Foundation
@testable import ActivityPubCore

@Suite("Multipart parser")
struct MultipartParserTests {

    @Test("Extract boundary from standard Content-Type")
    func extractBoundaryStandard() {
        let result = extractBoundary(from: "multipart/form-data; boundary=----WebKitFormBoundaryABC123")
        #expect(result == "----WebKitFormBoundaryABC123")
    }

    @Test("Extract boundary from quoted Content-Type")
    func extractBoundaryQuoted() {
        let result = extractBoundary(from: #"multipart/form-data; boundary="----WebKitFormBoundaryABC123""#)
        #expect(result == "----WebKitFormBoundaryABC123")
    }

    @Test("Extract boundary returns nil for missing boundary")
    func extractBoundaryMissing() {
        let result = extractBoundary(from: "application/json")
        #expect(result == nil)
    }

    @Test("Parse multipart with text fields")
    func parseTextFields() {
        let boundary = "----boundary"
        let body = "------boundary\r\nContent-Disposition: form-data; name=\"display_name\"\r\n\r\nTest Name\r\n------boundary\r\nContent-Disposition: form-data; name=\"note\"\r\n\r\nHello world\r\n------boundary--\r\n"

        let parts = parseMultipart(data: Data(body.utf8), boundary: boundary)
        #expect(parts.count == 2)
        #expect(parts[0].name == "display_name")
        #expect(parts[0].filename == nil)
        if let data = parts[0].data {
            #expect(String(data: data, encoding: .utf8) == "Test Name")
        }
        #expect(parts[1].name == "note")
        if let data = parts[1].data {
            #expect(String(data: data, encoding: .utf8) == "Hello world")
        }
    }

    @Test("Parse multipart with file field")
    func parseFileField() {
        let boundary = "----boundary"
        let body = "------boundary\r\nContent-Disposition: form-data; name=\"avatar\"; filename=\"photo.png\"\r\nContent-Type: image/png\r\n\r\nFAKEPNGDATA\r\n------boundary--\r\n"

        let parts = parseMultipart(data: Data(body.utf8), boundary: boundary)
        #expect(parts.count == 1)
        #expect(parts[0].name == "avatar")
        #expect(parts[0].filename == "photo.png")
        #expect(parts[0].contentType == "image/png")
        if let data = parts[0].data {
            #expect(String(data: data, encoding: .utf8) == "FAKEPNGDATA")
        }
    }

    @Test("Parse multipart with mixed text and file fields")
    func parseMixed() {
        let boundary = "----boundary"
        let body = "------boundary\r\nContent-Disposition: form-data; name=\"display_name\"\r\n\r\nMy Name\r\n------boundary\r\nContent-Disposition: form-data; name=\"avatar\"; filename=\"img.jpg\"\r\nContent-Type: image/jpeg\r\n\r\nJPEGDATA\r\n------boundary--\r\n"

        let parts = parseMultipart(data: Data(body.utf8), boundary: boundary)
        #expect(parts.count == 2)
        #expect(parts[0].name == "display_name")
        #expect(parts[0].filename == nil)
        #expect(parts[1].name == "avatar")
        #expect(parts[1].filename == "img.jpg")
        #expect(parts[1].contentType == "image/jpeg")
    }

    @Test("Parse body with only final boundary returns no parts")
    func parseOnlyFinalBoundary() {
        let body = "------boundary--\r\n"
        let parts = parseMultipart(data: Data(body.utf8), boundary: "----boundary")
        #expect(parts.isEmpty)
    }

    // MARK: - Standards-compliant client (swift-openapi) representative bodies

    /// A standards-compliant client (the swift-openapi multipart encoder) sends a `file`
    /// part with `Content-Type` plus a `description` text part. Assert the file is found
    /// by `name == "file"` with the correct filename and binary data, and the description
    /// is extracted.
    @Test("Parse file part with content-type plus text part (swift-openapi style)")
    func parseFileWithContentTypeAndText() {
        let boundary = "Boundary-1234567890"

        // Binary-ish bytes including a PNG signature and an embedded CRLF, to make sure
        // body bytes are preserved exactly and not confused with line endings.
        let fileBytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0xFF, 0x10, 0x42]

        var body = Data()
        func append(_ s: String) { body.append(Data(s.utf8)) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"upload.png\"\r\n")
        append("Content-Type: image/png\r\n")
        append("\r\n")
        body.append(Data(fileBytes))
        append("\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"description\"\r\n")
        append("\r\n")
        append("a sunset photo")
        append("\r\n")
        append("--\(boundary)--\r\n")

        let parts = parseMultipart(data: body, boundary: boundary)
        #expect(parts.count == 2)

        let filePart = parts.first(where: { $0.name == "file" })
        #expect(filePart != nil)
        #expect(filePart?.filename == "upload.png")
        #expect(filePart?.contentType == "image/png")
        #expect(filePart?.data == Data(fileBytes))

        let descPart = parts.first(where: { $0.name == "description" })
        #expect(descPart != nil)
        #expect(descPart.flatMap { $0.data.flatMap { String(data: $0, encoding: .utf8) } } == "a sunset photo")
    }

    /// swift-openapi may omit the per-part `Content-Type` header. The file part must
    /// STILL be found by name with its data intact. This is the failure mode of the old
    /// hand-rolled parser.
    @Test("Parse file part WITHOUT explicit Content-Type is still found by name")
    func parseFileWithoutContentType() {
        let boundary = "Boundary-abcDEF123"

        let fileBytes: [UInt8] = [0x00, 0x01, 0x02, 0xFE, 0xFF, 0x0A, 0x0D]

        var body = Data()
        func append(_ s: String) { body.append(Data(s.utf8)) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"blob.bin\"\r\n")
        // No Content-Type header for this part.
        append("\r\n")
        body.append(Data(fileBytes))
        append("\r\n")
        append("--\(boundary)--\r\n")

        let parts = parseMultipart(data: body, boundary: boundary)
        #expect(parts.count == 1)

        let filePart = parts.first(where: { $0.name == "file" })
        #expect(filePart != nil)
        #expect(filePart?.filename == "blob.bin")
        #expect(filePart?.contentType == nil)
        #expect(filePart?.data == Data(fileBytes))
        #expect(filePart?.data?.isEmpty == false)
    }

    /// Multiple parts with CRLF line endings and correct boundary handling.
    @Test("Parse multiple parts with CRLF line endings and correct boundaries")
    func parseMultiplePartsCRLF() {
        let boundary = "----WebKitFormBoundaryXyZ"
        let body = [
            "--\(boundary)",
            "Content-Disposition: form-data; name=\"file\"; filename=\"a.txt\"",
            "Content-Type: text/plain",
            "",
            "alpha",
            "--\(boundary)",
            "Content-Disposition: form-data; name=\"field1\"",
            "",
            "value one",
            "--\(boundary)",
            "Content-Disposition: form-data; name=\"field2\"",
            "",
            "value two",
            "--\(boundary)--",
            "",
        ].joined(separator: "\r\n")

        let parts = parseMultipart(data: Data(body.utf8), boundary: boundary)
        #expect(parts.count == 3)
        #expect(parts[0].name == "file")
        #expect(parts[0].filename == "a.txt")
        #expect(parts[0].contentType == "text/plain")
        #expect(parts[0].data.flatMap { String(data: $0, encoding: .utf8) } == "alpha")
        #expect(parts[1].name == "field1")
        #expect(parts[1].data.flatMap { String(data: $0, encoding: .utf8) } == "value one")
        #expect(parts[2].name == "field2")
        #expect(parts[2].data.flatMap { String(data: $0, encoding: .utf8) } == "value two")
    }

    /// Unquoted `Content-Disposition` parameter values must also be handled.
    @Test("Parse unquoted Content-Disposition parameter values")
    func parseUnquotedDispositionParams() {
        let boundary = "----b"
        let body = [
            "--\(boundary)",
            "Content-Disposition: form-data; name=file; filename=raw.dat",
            "",
            "payload",
            "--\(boundary)--",
            "",
        ].joined(separator: "\r\n")

        let parts = parseMultipart(data: Data(body.utf8), boundary: boundary)
        #expect(parts.count == 1)
        #expect(parts[0].name == "file")
        #expect(parts[0].filename == "raw.dat")
        #expect(parts[0].data.flatMap { String(data: $0, encoding: .utf8) } == "payload")
    }
}
