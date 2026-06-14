import Foundation
import Testing
@testable import APIClient

/// No-network schema-conformance tests.
///
/// These tests decode a committed fixture — a real populated outbox page captured
/// from `GET https://activity.happitec.com/users/commits/outbox?page=true` — through
/// the GENERATED OpenAPI types in `APIClient` (`Components.Schemas.*`). If `openapi.yaml`
/// and the real server payload drift apart, decoding fails and the test fails, gating CI.
///
/// The generated types are `internal`, so this target uses `@testable import APIClient`.
/// swift-openapi-generator renders `@context` as `_commat_context` and `type` as `_type`.
@Suite("SchemaConformanceTests")
struct SchemaConformanceTests {

    /// Loads the committed outbox-page fixture bytes.
    private func fixtureData() throws -> Data {
        let url = Bundle.module.url(
            forResource: "outbox-page",
            withExtension: "json",
            subdirectory: "Fixtures"
        )
        let resolved = try #require(url, "outbox-page.json fixture must be bundled")
        return try Data(contentsOf: resolved)
    }

    /// A real outbox page decodes into the generated `OrderedCollection` type, and its
    /// first item is a `Create` wrapping a `Note` with the expected populated fields.
    @Test("Outbox page decodes through the generated OrderedCollection types")
    func outboxPageDecodesThroughGeneratedTypes() throws {
        let data = try fixtureData()

        let decoder = JSONDecoder()
        // `published` is `format: date-time` → generated as `Foundation.Date`. The real
        // server emits RFC3339 timestamps with fractional seconds (e.g. "...03.020Z"),
        // which `.iso8601` rejects, so parse both fractional and whole-second forms.
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let withoutFraction = ISO8601DateFormatter()
        withoutFraction.formatOptions = [.withInternetDateTime]
        decoder.dateDecodingStrategy = .custom { d in
            let container = try d.singleValueContainer()
            let s = try container.decode(String.self)
            if let date = withFraction.date(from: s) ?? withoutFraction.date(from: s) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unparseable RFC3339 date: \(s)"
            )
        }

        let page = try decoder.decode(Components.Schemas.OrderedCollection.self, from: data)

        // It is the populated outbox page, not a root collection.
        #expect(page._type == .OrderedCollectionPage)

        let items = try #require(page.orderedItems, "outbox page must carry orderedItems")
        #expect(items.count >= 1, "fixture must contain at least one item")

        // First item is a Create activity wrapping a Note.
        let create: Components.Schemas.CreateActivity = try #require(items.first)
        #expect(create._type == .Create)

        let note = create.object

        // The Note carries non-empty content, a published timestamp, and id/url.
        #expect(!note.content.isEmpty, "Note content must be non-empty")
        _ = note.published // non-optional Foundation.Date; decoding it already proves it parsed
        #expect(!note.id.isEmpty, "Note id must be non-empty")
        #expect(!note.url.isEmpty, "Note url must be non-empty")
    }
}
