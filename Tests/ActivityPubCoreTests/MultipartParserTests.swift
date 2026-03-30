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
}
