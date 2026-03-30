# Inbox Interactions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Handle all common inbound ActivityPub interactions (likes, boosts, replies, deletes, updates, undo variants) with proper count tracking and HTML sanitization.

**Architecture:** New case branches in InboxHandler's switch statement, backed by new DynamoDB store methods in ActivityPubCore and a new HTMLSanitizer utility. No new Lambda functions or SAM template changes.

**Tech Stack:** Swift 6.3, AWS Lambda (provided.al2023), DynamoDB, AWSLambdaRuntime, AWSLambdaEvents

---

## Spec

`docs/superpowers/specs/2026-03-30-inbox-interactions-design.md`

## File Structure

### New files

```
Sources/
  ActivityPubCore/
    HTMLSanitizer.swift              # Sanitize untrusted inbound HTML (regex-based, no deps)
Tests/
  ActivityPubCoreTests/
    HTMLSanitizerTests.swift         # Unit tests for HTML sanitizer
scripts/
  test-inbox.sh                     # Curl-based smoke test for all inbox handlers
```

### Modified files

```
Sources/ActivityPubCore/DynamoDBStore.swift    # Add interaction, reply, and count methods
Sources/InboxHandler/main.swift                # Add Like, Announce, Create, Delete, Update, Undo variants, stub handlers + actor/signature verification
```

## Build and Test Commands

Build (on linux-runner VM):
```bash
sshpass -p admin ssh -o StrictHostKeyChecking=no admin@$(tart ip linux-runner) "cd ~/actions-runner/_work/activity.happitec.com/activity.happitec.com && swift build 2>&1"
```

SCP files first (the VM cannot git fetch this worktree):
```bash
sshpass -p admin scp -o StrictHostKeyChecking=no -r /Users/spar/web-local/activity.happitec.com/.claude/worktrees/agent-a3c2f787/Sources admin@$(tart ip linux-runner):~/actions-runner/_work/activity.happitec.com/activity.happitec.com/Sources
sshpass -p admin scp -o StrictHostKeyChecking=no -r /Users/spar/web-local/activity.happitec.com/.claude/worktrees/agent-a3c2f787/Tests admin@$(tart ip linux-runner):~/actions-runner/_work/activity.happitec.com/activity.happitec.com/Tests
```

Test (on linux-runner VM):
```bash
sshpass -p admin ssh -o StrictHostKeyChecking=no admin@$(tart ip linux-runner) "cd ~/actions-runner/_work/activity.happitec.com/activity.happitec.com && swift test --filter ActivityPubCoreTests 2>&1"
```

---

## Task 1: HTML Sanitizer (TDD)

**Files:** `Sources/ActivityPubCore/HTMLSanitizer.swift`, `Tests/ActivityPubCoreTests/HTMLSanitizerTests.swift`

**Dependencies:** None. Can be done in parallel with Task 2 and Task 3.

### Steps

- [ ] **1a. Write failing tests** in `Tests/ActivityPubCoreTests/HTMLSanitizerTests.swift`

Create the test file using Swift Testing framework (same pattern as `TextToHTMLTests.swift`). The file imports `Testing` and `@testable import ActivityPubCore`. Use `@Suite("HTML Sanitizer")` and `@Test("...")` annotations.

Test cases (each is a separate `@Test` function):

1. `allowedTagsPassThrough` -- `<p>Hello</p>` returns unchanged. Test all allowed tags: `p`, `br`, `a`, `span`, `em`, `strong`, `b`, `i`, `u`, `del`, `pre`, `code`, `ul`, `ol`, `li`, `blockquote`.
2. `disallowedTagsStrippedContentPreserved` -- `<script>alert('xss')</script>` becomes `alert('xss')`. Also test `<div><p>text</p></div>` becomes `<p>text</p>`.
3. `attributesStrippedExceptAllowed` -- `<a href="https://example.com" onclick="evil()">link</a>` becomes `<a href="https://example.com" rel="nofollow noopener noreferrer">link</a>`.
4. `hrefPositiveAllowlist` -- `<a href="javascript:alert(1)">link</a>` becomes `<a rel="nofollow noopener noreferrer">link</a>`. Also test `data:`, `vbscript:`, `blob:` schemes are stripped. `http://` and `https://` are preserved.
5. `selfClosingTagsHandled` -- `<br>`, `<br/>`, `<br />` all produce `<br>`.
6. `nestedAllowedAndDisallowed` -- `<div><p><strong>bold</strong></p></div>` becomes `<p><strong>bold</strong></p>`.
7. `malformedHTML` -- unclosed `<p>text` becomes `<p>text</p>` (or reasonable best-effort). Extra closing tags `</p></p>` are handled gracefully.
8. `htmlEntitiesPreserved` -- `<p>&amp; &lt; &gt; &#39;</p>` passes through unchanged.
9. `emptyAndWhitespaceInput` -- `""` returns `""`. `"   "` returns `"   "`.
10. `realWorldMastodonHTML` -- A complete Mastodon mention+link note:
    ```html
    <p><span class="h-card"><a href="https://mastodon.social/@user" class="u-url mention">@<span>user</span></a></span> Check out <a href="https://example.com" target="_blank" rel="nofollow noopener noreferrer">example.com</a></p>
    ```
    becomes:
    ```html
    <p><span class="h-card"><a href="https://mastodon.social/@user" rel="nofollow noopener noreferrer">@<span>user</span></a></span> Check out <a href="https://example.com" rel="nofollow noopener noreferrer">example.com</a></p>
    ```
    (The `class="u-url mention"` is stripped from the `<a>` -- `class` is only allowed on `<span>`. The `target="_blank"` is stripped. The existing `rel` is replaced/normalized.)
11. `spanClassAllowlist` -- `<span class="h-card mention">@user</span>` passes through. `<span class="h-card evil-class">@user</span>` becomes `<span class="h-card">@user</span>`. `<span class="evil-only">text</span>` becomes `<span>text</span>`.
12. `relAttributeAlwaysAdded` -- `<a href="https://example.com">link</a>` (no rel) gets `rel="nofollow noopener noreferrer"` added. An existing `rel="nofollow"` is replaced with the full set.
13. `caseInsensitiveTagMatching` -- `<SCRIPT>xss</SCRIPT>` becomes `xss`. `<A HREF="https://example.com">link</A>` becomes `<a href="https://example.com" rel="nofollow noopener noreferrer">link</a>`.

All test functions call `HTMLSanitizer.sanitize(_:)` (a static method).

```swift
import Testing
@testable import ActivityPubCore

@Suite("HTML Sanitizer")
struct HTMLSanitizerTests {

    @Test("Allowed tags pass through unchanged")
    func allowedTagsPassThrough() {
        #expect(HTMLSanitizer.sanitize("<p>Hello</p>") == "<p>Hello</p>")
        #expect(HTMLSanitizer.sanitize("<em>italic</em>") == "<em>italic</em>")
        #expect(HTMLSanitizer.sanitize("<strong>bold</strong>") == "<strong>bold</strong>")
        #expect(HTMLSanitizer.sanitize("<b>bold</b>") == "<b>bold</b>")
        #expect(HTMLSanitizer.sanitize("<i>italic</i>") == "<i>italic</i>")
        #expect(HTMLSanitizer.sanitize("<u>underline</u>") == "<u>underline</u>")
        #expect(HTMLSanitizer.sanitize("<del>deleted</del>") == "<del>deleted</del>")
        #expect(HTMLSanitizer.sanitize("<pre>preformatted</pre>") == "<pre>preformatted</pre>")
        #expect(HTMLSanitizer.sanitize("<code>code</code>") == "<code>code</code>")
        #expect(HTMLSanitizer.sanitize("<blockquote>quote</blockquote>") == "<blockquote>quote</blockquote>")
        #expect(HTMLSanitizer.sanitize("<ul><li>item</li></ul>") == "<ul><li>item</li></ul>")
        #expect(HTMLSanitizer.sanitize("<ol><li>item</li></ol>") == "<ol><li>item</li></ol>")
    }

    @Test("Disallowed tags stripped, content preserved")
    func disallowedTagsStrippedContentPreserved() {
        #expect(HTMLSanitizer.sanitize("<script>alert('xss')</script>") == "alert('xss')")
        #expect(HTMLSanitizer.sanitize("<div><p>text</p></div>") == "<p>text</p>")
        #expect(HTMLSanitizer.sanitize("<img src=\"evil.jpg\">visible text") == "visible text")
    }

    @Test("Attributes stripped except href on <a> and class on <span>")
    func attributesStrippedExceptAllowed() {
        #expect(HTMLSanitizer.sanitize(
            "<a href=\"https://example.com\" onclick=\"evil()\">link</a>"
        ) == "<a href=\"https://example.com\" rel=\"nofollow noopener noreferrer\">link</a>")
        #expect(HTMLSanitizer.sanitize(
            "<p style=\"color:red\">text</p>"
        ) == "<p>text</p>")
    }

    @Test("Non-http(s) URI schemes stripped from href (positive allowlist)")
    func hrefPositiveAllowlist() {
        #expect(HTMLSanitizer.sanitize(
            "<a href=\"javascript:alert(1)\">link</a>"
        ) == "<a rel=\"nofollow noopener noreferrer\">link</a>")
        #expect(HTMLSanitizer.sanitize(
            "<a href=\"data:text/html,<script>alert(1)</script>\">link</a>"
        ) == "<a rel=\"nofollow noopener noreferrer\">link</a>")
        #expect(HTMLSanitizer.sanitize(
            "<a href=\"vbscript:MsgBox\">link</a>"
        ) == "<a rel=\"nofollow noopener noreferrer\">link</a>")
        #expect(HTMLSanitizer.sanitize(
            "<a href=\"blob:https://evil.com/abc\">link</a>"
        ) == "<a rel=\"nofollow noopener noreferrer\">link</a>")
        #expect(HTMLSanitizer.sanitize(
            "<a href=\"https://example.com\">link</a>"
        ) == "<a href=\"https://example.com\" rel=\"nofollow noopener noreferrer\">link</a>")
        #expect(HTMLSanitizer.sanitize(
            "<a href=\"http://example.com\">link</a>"
        ) == "<a href=\"http://example.com\" rel=\"nofollow noopener noreferrer\">link</a>")
    }

    @Test("Self-closing tags handled")
    func selfClosingTagsHandled() {
        #expect(HTMLSanitizer.sanitize("<br>") == "<br>")
        #expect(HTMLSanitizer.sanitize("<br/>") == "<br>")
        #expect(HTMLSanitizer.sanitize("<br />") == "<br>")
    }

    @Test("Nested allowed and disallowed tags")
    func nestedAllowedAndDisallowed() {
        #expect(HTMLSanitizer.sanitize(
            "<div><p><strong>bold</strong></p></div>"
        ) == "<p><strong>bold</strong></p>")
    }

    @Test("Malformed HTML handled gracefully")
    func malformedHTML() {
        // Unclosed tags -- best effort
        let result = HTMLSanitizer.sanitize("<p>text")
        #expect(result.contains("text"))
        // Extra closing tags stripped
        let result2 = HTMLSanitizer.sanitize("</p>text</p>")
        #expect(result2.contains("text"))
    }

    @Test("HTML entities preserved")
    func htmlEntitiesPreserved() {
        #expect(HTMLSanitizer.sanitize("<p>&amp; &lt; &gt; &#39;</p>") == "<p>&amp; &lt; &gt; &#39;</p>")
    }

    @Test("Empty and whitespace input")
    func emptyAndWhitespaceInput() {
        #expect(HTMLSanitizer.sanitize("") == "")
        #expect(HTMLSanitizer.sanitize("   ") == "   ")
    }

    @Test("Real-world Mastodon Note HTML")
    func realWorldMastodonHTML() {
        let input = """
        <p><span class="h-card"><a href="https://mastodon.social/@user" class="u-url mention">@<span>user</span></a></span> Check out <a href="https://example.com" target="_blank" rel="nofollow noopener noreferrer">example.com</a></p>
        """
        let expected = """
        <p><span class="h-card"><a href="https://mastodon.social/@user" rel="nofollow noopener noreferrer">@<span>user</span></a></span> Check out <a href="https://example.com" rel="nofollow noopener noreferrer">example.com</a></p>
        """
        #expect(HTMLSanitizer.sanitize(input) == expected)
    }

    @Test("Span class allowlist filtering")
    func spanClassAllowlist() {
        #expect(HTMLSanitizer.sanitize(
            "<span class=\"h-card mention\">@user</span>"
        ) == "<span class=\"h-card mention\">@user</span>")
        #expect(HTMLSanitizer.sanitize(
            "<span class=\"h-card evil-class\">@user</span>"
        ) == "<span class=\"h-card\">@user</span>")
        #expect(HTMLSanitizer.sanitize(
            "<span class=\"evil-only\">text</span>"
        ) == "<span>text</span>")
        // All five allowed classes
        #expect(HTMLSanitizer.sanitize(
            "<span class=\"invisible\">hidden</span>"
        ) == "<span class=\"invisible\">hidden</span>")
        #expect(HTMLSanitizer.sanitize(
            "<span class=\"ellipsis\">...</span>"
        ) == "<span class=\"ellipsis\">...</span>")
        #expect(HTMLSanitizer.sanitize(
            "<span class=\"hashtag\">#tag</span>"
        ) == "<span class=\"hashtag\">#tag</span>")
    }

    @Test("rel attribute always added to <a> tags")
    func relAttributeAlwaysAdded() {
        #expect(HTMLSanitizer.sanitize(
            "<a href=\"https://example.com\">link</a>"
        ) == "<a href=\"https://example.com\" rel=\"nofollow noopener noreferrer\">link</a>")
        // Existing rel is replaced
        #expect(HTMLSanitizer.sanitize(
            "<a href=\"https://example.com\" rel=\"nofollow\">link</a>"
        ) == "<a href=\"https://example.com\" rel=\"nofollow noopener noreferrer\">link</a>")
    }

    @Test("Case-insensitive tag matching")
    func caseInsensitiveTagMatching() {
        #expect(HTMLSanitizer.sanitize("<SCRIPT>xss</SCRIPT>") == "xss")
        #expect(HTMLSanitizer.sanitize(
            "<A HREF=\"https://example.com\">link</A>"
        ) == "<a href=\"https://example.com\" rel=\"nofollow noopener noreferrer\">link</a>")
    }
}
```

- [ ] **1b. SCP Tests to VM, verify tests fail** (the `HTMLSanitizer` type does not exist yet)

```bash
# SCP Sources and Tests to VM
sshpass -p admin scp -o StrictHostKeyChecking=no -r Sources Tests admin@$(tart ip linux-runner):~/actions-runner/_work/activity.happitec.com/activity.happitec.com/
# Run tests -- expect compilation failure
sshpass -p admin ssh -o StrictHostKeyChecking=no admin@$(tart ip linux-runner) "cd ~/actions-runner/_work/activity.happitec.com/activity.happitec.com && swift test --filter HTMLSanitizer 2>&1"
```

- [ ] **1c. Implement `HTMLSanitizer`** in `Sources/ActivityPubCore/HTMLSanitizer.swift`

The sanitizer is a pure `enum` with a single `static func sanitize(_ html: String) -> String`. No external dependencies -- regex-based parsing using Swift's `Regex` or `NSRegularExpression`.

Implementation approach:
1. Define `allowedTags` set: `["p", "br", "a", "span", "em", "strong", "b", "i", "u", "del", "pre", "code", "ul", "ol", "li", "blockquote"]`
2. Define `selfClosingTags` set: `["br"]`
3. Define `allowedSpanClasses` set: `["h-card", "invisible", "ellipsis", "mention", "hashtag"]`
4. Walk the input with a regex that matches `<(/?)(\w+)([^>]*)(/?)>` (opening/closing tags with attributes)
5. For each tag match:
   - Lowercase the tag name
   - If closing tag and in allowedTags: emit `</tagname>`
   - If closing tag and not in allowedTags: skip (strip)
   - If opening tag and not in allowedTags: skip (strip)
   - If opening tag and in allowedTags:
     - If tag is `a`: extract `href` attribute value, validate scheme (must start with `http://` or `https://`), emit `<a` + valid href + ` rel="nofollow noopener noreferrer">`
     - If tag is `span`: extract `class` attribute, filter values against `allowedSpanClasses`, emit `<span` + filtered class (if non-empty) + `>`
     - If tag is `br`: emit `<br>` (normalize all variants)
     - Otherwise: emit `<tagname>` (no attributes)
6. Text between tags: pass through as-is (including HTML entities)

```swift
import Foundation

/// Sanitizes untrusted HTML for safe storage and display.
/// Allowlisted tags are preserved; all others are stripped (content kept).
/// Only `href` on `<a>` and `class` on `<span>` attributes are preserved.
public enum HTMLSanitizer {

    private static let allowedTags: Set<String> = [
        "p", "br", "a", "span", "em", "strong", "b", "i", "u",
        "del", "pre", "code", "ul", "ol", "li", "blockquote"
    ]

    private static let selfClosingTags: Set<String> = ["br"]

    private static let allowedSpanClasses: Set<String> = [
        "h-card", "invisible", "ellipsis", "mention", "hashtag"
    ]

    /// Sanitize an untrusted HTML string.
    /// - Parameter html: The untrusted input HTML.
    /// - Returns: Sanitized HTML with only allowed tags and attributes.
    public static func sanitize(_ html: String) -> String {
        guard !html.isEmpty else { return "" }

        // Regex matches opening tags, closing tags, and self-closing tags
        // Group 1: optional "/" for closing tags
        // Group 2: tag name
        // Group 3: attributes string
        // Group 4: optional "/" for self-closing
        let tagPattern = "<(/?)([a-zA-Z][a-zA-Z0-9]*)([^>]*?)(/?)>"

        guard let regex = try? NSRegularExpression(pattern: tagPattern, options: []) else {
            return html
        }

        let nsHTML = html as NSString
        let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: nsHTML.length))

        var result = ""
        var lastEnd = 0

        for match in matches {
            // Append text before this tag
            let textBefore = nsHTML.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
            result += textBefore

            let isClosing = nsHTML.substring(with: match.range(at: 1)) == "/"
            let tagName = nsHTML.substring(with: match.range(at: 2)).lowercased()
            let attrsString = nsHTML.substring(with: match.range(at: 3))
            let isSelfClosing = nsHTML.substring(with: match.range(at: 4)) == "/"

            if selfClosingTags.contains(tagName) && allowedTags.contains(tagName) {
                // Normalize self-closing tags (e.g., <br/>, <br />) to <br>
                result += "<\(tagName)>"
            } else if isClosing {
                if allowedTags.contains(tagName) && !selfClosingTags.contains(tagName) {
                    result += "</\(tagName)>"
                }
                // Disallowed closing tags: strip
            } else if allowedTags.contains(tagName) {
                // Opening tag -- process attributes
                if tagName == "a" {
                    let href = extractAttribute("href", from: attrsString)
                    var tag = "<a"
                    if let href, isAllowedScheme(href) {
                        tag += " href=\"\(escapeAttributeValue(href))\""
                    }
                    tag += " rel=\"nofollow noopener noreferrer\""
                    tag += ">"
                    result += tag
                } else if tagName == "span" {
                    let classValue = extractAttribute("class", from: attrsString)
                    var tag = "<span"
                    if let classValue {
                        let filtered = classValue
                            .split(separator: " ")
                            .map(String.init)
                            .filter { allowedSpanClasses.contains($0) }
                        if !filtered.isEmpty {
                            tag += " class=\"\(filtered.joined(separator: " "))\""
                        }
                    }
                    tag += ">"
                    result += tag
                } else if isSelfClosing || selfClosingTags.contains(tagName) {
                    result += "<\(tagName)>"
                } else {
                    // Allowed tag with no preserved attributes
                    result += "<\(tagName)>"
                }
            }
            // Disallowed opening tags: strip (text content between them is kept by the next iteration)

            lastEnd = match.range.location + match.range.length
        }

        // Append any remaining text after the last tag
        if lastEnd < nsHTML.length {
            result += nsHTML.substring(from: lastEnd)
        }

        return result
    }

    /// Extract a named attribute value from an attributes string.
    /// Handles both single and double quotes.
    private static func extractAttribute(_ name: String, from attrs: String) -> String? {
        // Pattern: name="value" or name='value' (case-insensitive attribute name)
        let pattern = "\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let nsAttrs = attrs as NSString
        guard let match = regex.firstMatch(in: attrs, options: [], range: NSRange(location: 0, length: nsAttrs.length)) else {
            return nil
        }
        // Try double-quote group first, then single-quote
        if match.range(at: 1).location != NSNotFound {
            return nsAttrs.substring(with: match.range(at: 1))
        }
        if match.range(at: 2).location != NSNotFound {
            return nsAttrs.substring(with: match.range(at: 2))
        }
        return nil
    }

    /// Check if a URL scheme is in the positive allowlist (http:// or https:// only).
    private static func isAllowedScheme(_ url: String) -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
    }

    /// Escape special characters in an HTML attribute value.
    private static func escapeAttributeValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
```

- [ ] **1d. SCP to VM, verify all tests pass, commit**

```bash
sshpass -p admin scp -o StrictHostKeyChecking=no -r Sources Tests admin@$(tart ip linux-runner):~/actions-runner/_work/activity.happitec.com/activity.happitec.com/
sshpass -p admin ssh -o StrictHostKeyChecking=no admin@$(tart ip linux-runner) "cd ~/actions-runner/_work/activity.happitec.com/activity.happitec.com && swift test --filter HTMLSanitizer 2>&1"
```

If tests fail, fix the implementation until all pass. Then commit both files:
```bash
git add Sources/ActivityPubCore/HTMLSanitizer.swift Tests/ActivityPubCoreTests/HTMLSanitizerTests.swift
git commit -m "Add HTML sanitizer with TDD tests for inbox content sanitization"
```

---

## Task 2: Actor/Signature Verification Helper

**Files:** `Sources/InboxHandler/main.swift`

**Dependencies:** None. Can be done in parallel with Task 1 and Task 3.

### Context

Currently, the InboxHandler verifies the HTTP Signature is valid but does NOT check that the `actor` field in the activity body matches the actor who signed the request. This means a valid actor could sign a request claiming to be from a different actor. This is a security fix that applies to all activity types, including the existing Follow and Undo-Follow handlers.

The `KeyManager.extractActorUri(from:)` method already strips the `#main-key` fragment from a keyId to produce the actor URI. We compare this against the `actor` field in the JSON body.

### Steps

- [ ] **2a. Add actor/signature verification** immediately after the HTTP Signature verification block in `Sources/InboxHandler/main.swift`

Insert the following block right after `guard verified else { ... }` (around line 135) and before `guard let activityType = json["type"] as? String`:

```swift
// Verify actor field matches the signing key's actor
let signingActorUri = keyManager.extractActorUri(from: keyId)
if !actorUri.isEmpty && actorUri != signingActorUri {
    context.logger.warning(
        "Actor mismatch: body actor=\(actorUri) but signing key actor=\(signingActorUri)"
    )
    return APIGatewayResponse(
        statusCode: .forbidden,
        headers: ["content-type": "application/json"],
        body: #"{"error":"Actor does not match signing key"}"#
    )
}
```

Note: The `actorUri` variable is extracted later in the existing code (line 148: `let actorUri = json["actor"] as? String ?? ""`). This extraction must be moved BEFORE the verification check. Specifically, move the `actorUri` extraction to right after the JSON parsing, before the signature verification, or (simpler) extract it separately for the check:

```swift
// Verify actor field matches HTTP Signature's actor
let bodyActorUri = json["actor"] as? String ?? ""
let signingActorUri = keyManager.extractActorUri(from: keyId)
if !bodyActorUri.isEmpty && bodyActorUri != signingActorUri {
    context.logger.warning(
        "Actor mismatch: body actor=\(bodyActorUri) but signing key actor=\(signingActorUri)"
    )
    return APIGatewayResponse(
        statusCode: .forbidden,
        headers: ["content-type": "application/json"],
        body: #"{"error":"Actor does not match signing key"}"#
    )
}
```

Place this immediately after the `guard verified else { ... }` block. The existing `let actorUri = json["actor"] as? String ?? ""` on line 148 remains unchanged (it uses the same value).

- [ ] **2b. SCP to VM, build, verify no compilation errors, commit**

```bash
git add Sources/InboxHandler/main.swift
git commit -m "Add actor/signature verification to prevent spoofed inbox activities"
```

---

## Task 3: DynamoDB Store Methods

**Files:** `Sources/ActivityPubCore/DynamoDBStore.swift`

**Dependencies:** None. Can be done in parallel with Task 1 and Task 2.

### Steps

- [ ] **3a. Add interaction storage methods** to `DynamoDBStore.swift`

Add a new `// MARK: - Interaction Storage` section after the existing `// MARK: - Activity Idempotency` section.

**`storeInteraction`** -- Uses deterministic SK `INTERACTION#{type}#{actorUri}#{objectUri}` for direct GetItem/DeleteItem on Undo. Returns `true` if new, `false` if duplicate.

```swift
// MARK: - Interaction Storage

/// Store a Like or Announce interaction. Uses deterministic SK for direct lookup/delete.
/// Returns `true` if newly stored, `false` if duplicate.
public func storeInteraction(
    username: String,
    actorUri: String,
    type: String,
    objectUri: String
) async throws -> Bool {
    let formatter = ISO8601DateFormatter()
    let now = formatter.string(from: Date())

    let item: [String: DynamoDBClientTypes.AttributeValue] = [
        "PK": .s("ACTOR#\(username)"),
        "SK": .s("INTERACTION#\(type)#\(actorUri)#\(objectUri)"),
        "actorUri": .s(actorUri),
        "type": .s(type),
        "objectUri": .s(objectUri),
        "createdAt": .s(now),
    ]

    let input = PutItemInput(
        conditionExpression: "attribute_not_exists(SK)",
        item: item,
        tableName: tableName
    )

    do {
        _ = try await client.putItem(input: input)
        return true
    } catch is ConditionalCheckFailedException {
        return false
    }
}

/// Remove a Like or Announce interaction on Undo/Delete.
/// Returns `true` if the interaction existed, `false` if not found.
public func removeInteraction(
    username: String,
    actorUri: String,
    type: String,
    objectUri: String
) async throws -> Bool {
    let input = DeleteItemInput(
        conditionExpression: "attribute_exists(SK)",
        key: [
            "PK": .s("ACTOR#\(username)"),
            "SK": .s("INTERACTION#\(type)#\(actorUri)#\(objectUri)"),
        ],
        tableName: tableName
    )
    do {
        _ = try await client.deleteItem(input: input)
        return true
    } catch is ConditionalCheckFailedException {
        return false
    }
}
```

- [ ] **3b. Add reply storage methods**

```swift
// MARK: - Reply Storage

/// Store an inbound reply Note. Returns `true` if newly stored.
public func storeReply(
    username: String,
    actorUri: String,
    objectUri: String,
    content: String,
    inReplyTo: String,
    raw: String
) async throws -> Bool {
    let formatter = ISO8601DateFormatter()
    let now = formatter.string(from: Date())
    let ulid = generateULID()

    let item: [String: DynamoDBClientTypes.AttributeValue] = [
        "PK": .s("ACTOR#\(username)"),
        "SK": .s("REPLY#\(objectUri)"),
        "GSI1PK": .s("REPLIES#\(inReplyTo)"),
        "GSI1SK": .s(now),
        "actorUri": .s(actorUri),
        "objectUri": .s(objectUri),
        "content": .s(content),
        "inReplyTo": .s(inReplyTo),
        "raw": .s(raw),
        "createdAt": .s(now),
    ]

    let input = PutItemInput(
        conditionExpression: "attribute_not_exists(SK)",
        item: item,
        tableName: tableName
    )

    do {
        _ = try await client.putItem(input: input)
        return true
    } catch is ConditionalCheckFailedException {
        return false
    }
}

/// Remove a stored reply on Delete. Returns `true` if existed.
public func removeReply(username: String, objectUri: String) async throws -> Bool {
    let input = DeleteItemInput(
        conditionExpression: "attribute_exists(SK)",
        key: [
            "PK": .s("ACTOR#\(username)"),
            "SK": .s("REPLY#\(objectUri)"),
        ],
        tableName: tableName
    )
    do {
        _ = try await client.deleteItem(input: input)
        return true
    } catch is ConditionalCheckFailedException {
        return false
    }
}

/// Update a stored reply's content on Update.
public func updateReply(
    username: String,
    objectUri: String,
    content: String
) async throws {
    let formatter = ISO8601DateFormatter()
    let now = formatter.string(from: Date())

    let input = UpdateItemInput(
        expressionAttributeNames: ["#c": "content", "#u": "updatedAt"],
        expressionAttributeValues: [":c": .s(content), ":u": .s(now)],
        key: [
            "PK": .s("ACTOR#\(username)"),
            "SK": .s("REPLY#\(objectUri)"),
        ],
        tableName: tableName,
        updateExpression: "SET #c = :c, #u = :u"
    )
    _ = try await client.updateItem(input: input)
}
```

- [ ] **3c. Add remote actor update method**

```swift
/// Refresh a cached remote actor profile. Resets TTL to 24h.
public func updateRemoteActor(actorUri: String, data: RemoteActor) async throws {
    // Re-use the existing storeRemoteActor method which does a full PutItem with fresh TTL
    try await storeRemoteActor(data)
}
```

- [ ] **3d. Add count increment/decrement methods for likes, boosts, and replies**

Follow the existing `incrementFollowerCount` pattern for increments. For decrements, use `conditionExpression` to floor at zero (catching `ConditionalCheckFailedException`) as specified in the design doc:

```swift
// MARK: - Interaction Counts

/// Atomically increment the likes count for a status.
public func incrementLikesCount(username: String, statusId: String) async throws {
    let input = UpdateItemInput(
        expressionAttributeNames: ["#fc": "likesCount"],
        expressionAttributeValues: [":val": .n("1")],
        key: [
            "PK": .s("ACTOR#\(username)"),
            "SK": .s("STATUS#\(statusId)"),
        ],
        tableName: tableName,
        updateExpression: "ADD #fc :val"
    )
    _ = try await client.updateItem(input: input)
}

/// Atomically decrement the likes count for a status. Floors at zero.
public func decrementLikesCount(username: String, statusId: String) async throws {
    let input = UpdateItemInput(
        conditionExpression: "#fc > :zero",
        expressionAttributeNames: ["#fc": "likesCount"],
        expressionAttributeValues: [":val": .n("-1"), ":zero": .n("0")],
        key: [
            "PK": .s("ACTOR#\(username)"),
            "SK": .s("STATUS#\(statusId)"),
        ],
        tableName: tableName,
        updateExpression: "ADD #fc :val"
    )
    do {
        _ = try await client.updateItem(input: input)
    } catch is ConditionalCheckFailedException {
        // Already at zero -- no-op
    }
}

/// Atomically increment the boosts count for a status.
public func incrementBoostsCount(username: String, statusId: String) async throws {
    let input = UpdateItemInput(
        expressionAttributeNames: ["#fc": "boostsCount"],
        expressionAttributeValues: [":val": .n("1")],
        key: [
            "PK": .s("ACTOR#\(username)"),
            "SK": .s("STATUS#\(statusId)"),
        ],
        tableName: tableName,
        updateExpression: "ADD #fc :val"
    )
    _ = try await client.updateItem(input: input)
}

/// Atomically decrement the boosts count for a status. Floors at zero.
public func decrementBoostsCount(username: String, statusId: String) async throws {
    let input = UpdateItemInput(
        conditionExpression: "#fc > :zero",
        expressionAttributeNames: ["#fc": "boostsCount"],
        expressionAttributeValues: [":val": .n("-1"), ":zero": .n("0")],
        key: [
            "PK": .s("ACTOR#\(username)"),
            "SK": .s("STATUS#\(statusId)"),
        ],
        tableName: tableName,
        updateExpression: "ADD #fc :val"
    )
    do {
        _ = try await client.updateItem(input: input)
    } catch is ConditionalCheckFailedException {
        // Already at zero -- no-op
    }
}

/// Atomically increment the replies count for a status.
public func incrementRepliesCount(username: String, statusId: String) async throws {
    let input = UpdateItemInput(
        expressionAttributeNames: ["#fc": "repliesCount"],
        expressionAttributeValues: [":val": .n("1")],
        key: [
            "PK": .s("ACTOR#\(username)"),
            "SK": .s("STATUS#\(statusId)"),
        ],
        tableName: tableName,
        updateExpression: "ADD #fc :val"
    )
    _ = try await client.updateItem(input: input)
}

/// Atomically decrement the replies count for a status. Floors at zero.
public func decrementRepliesCount(username: String, statusId: String) async throws {
    let input = UpdateItemInput(
        conditionExpression: "#fc > :zero",
        expressionAttributeNames: ["#fc": "repliesCount"],
        expressionAttributeValues: [":val": .n("-1"), ":zero": .n("0")],
        key: [
            "PK": .s("ACTOR#\(username)"),
            "SK": .s("STATUS#\(statusId)"),
        ],
        tableName: tableName,
        updateExpression: "ADD #fc :val"
    )
    do {
        _ = try await client.updateItem(input: input)
    } catch is ConditionalCheckFailedException {
        // Already at zero -- no-op
    }
}
```

Note: These use `ADD` instead of `SET ... + :val` because `ADD` auto-initializes to 0 if the attribute doesn't exist, which is safer for new statuses. The existing `incrementFollowerCount` uses `SET`, but `ADD` is the better pattern for counters that may not exist yet. The decrement uses a `conditionExpression` instead of `if_not_exists` to correctly floor at zero (the spec explicitly calls out that `if_not_exists` can go negative on race conditions).

- [ ] **3e. SCP to VM, build, verify no compilation errors, commit**

```bash
git add Sources/ActivityPubCore/DynamoDBStore.swift
git commit -m "Add DynamoDB store methods for interactions, replies, and count tracking"
```

---

## Task 4: Like + Announce Handlers

**Files:** `Sources/InboxHandler/main.swift`

**Dependencies:** Task 2 (actor verification), Task 3 (store methods)

### Steps

- [ ] **4a. Add `parseStatusUri` helper** to `Sources/InboxHandler/main.swift`

Add this in the `// MARK: - Helpers` section:

```swift
/// Parse a status URI like `https://activity.happitec.com/users/{username}/statuses/{id}`
/// or `https://happitec.com/users/{username}/statuses/{id}` into (username, statusId).
/// Returns nil if the URI doesn't match our domain pattern.
func parseStatusUri(_ uri: String) -> (username: String, statusId: String)? {
    // Match both serverDomain and handleDomain
    let patterns = [
        "https://\(serverDomain)/users/",
        "https://\(handleDomain)/users/"
    ]
    for prefix in patterns {
        guard uri.hasPrefix(prefix) else { continue }
        let remainder = String(uri.dropFirst(prefix.count))
        let parts = remainder.split(separator: "/", maxSplits: 3)
        // Expected: ["username", "statuses", "id"]
        guard parts.count >= 3, parts[1] == "statuses" else { continue }
        return (username: String(parts[0]), statusId: String(parts[2]))
    }
    return nil
}
```

- [ ] **4b. Add `handleLike` function**

```swift
// MARK: - Like Handling

func handleLike(
    json: [String: Any],
    username: String,
    actorUri: String,
    context: LambdaContext
) async throws -> APIGatewayResponse {
    context.logger.info("Processing Like from \(actorUri) for \(username)")

    // Extract the object URI (the status being liked)
    guard let objectUri = extractObjectUri(from: json) else {
        context.logger.warning("Like missing object URI from \(actorUri)")
        return APIGatewayResponse(
            statusCode: .badRequest,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Missing object in Like activity"}"#
        )
    }

    // Parse username and statusId from the object URI
    guard let parsed = parseStatusUri(objectUri) else {
        context.logger.info("Like for non-local object \(objectUri) from \(actorUri)")
        return APIGatewayResponse(
            statusCode: .accepted,
            headers: ["content-type": "application/json"],
            body: #"{"status":"accepted"}"#
        )
    }

    // Verify the status exists
    guard try await store.getStatus(username: parsed.username, id: parsed.statusId) != nil else {
        context.logger.warning("Like for non-existent status \(objectUri) from \(actorUri)")
        return APIGatewayResponse(
            statusCode: .accepted,
            headers: ["content-type": "application/json"],
            body: #"{"status":"accepted"}"#
        )
    }

    // Store the interaction
    let isNew = try await store.storeInteraction(
        username: parsed.username,
        actorUri: actorUri,
        type: "Like",
        objectUri: objectUri
    )

    if isNew {
        try await store.incrementLikesCount(username: parsed.username, statusId: parsed.statusId)
    }

    context.logger.info("Like \(isNew ? "stored" : "duplicate") from \(actorUri) on \(objectUri)")

    return APIGatewayResponse(
        statusCode: .accepted,
        headers: ["content-type": "application/json"],
        body: #"{"status":"accepted"}"#
    )
}
```

- [ ] **4c. Add `handleAnnounce` function**

```swift
// MARK: - Announce Handling

func handleAnnounce(
    json: [String: Any],
    username: String,
    actorUri: String,
    context: LambdaContext
) async throws -> APIGatewayResponse {
    context.logger.info("Processing Announce from \(actorUri) for \(username)")

    guard let objectUri = extractObjectUri(from: json) else {
        context.logger.warning("Announce missing object URI from \(actorUri)")
        return APIGatewayResponse(
            statusCode: .badRequest,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Missing object in Announce activity"}"#
        )
    }

    guard let parsed = parseStatusUri(objectUri) else {
        context.logger.info("Announce for non-local object \(objectUri) from \(actorUri)")
        return APIGatewayResponse(
            statusCode: .accepted,
            headers: ["content-type": "application/json"],
            body: #"{"status":"accepted"}"#
        )
    }

    guard try await store.getStatus(username: parsed.username, id: parsed.statusId) != nil else {
        context.logger.warning("Announce for non-existent status \(objectUri) from \(actorUri)")
        return APIGatewayResponse(
            statusCode: .accepted,
            headers: ["content-type": "application/json"],
            body: #"{"status":"accepted"}"#
        )
    }

    let isNew = try await store.storeInteraction(
        username: parsed.username,
        actorUri: actorUri,
        type: "Announce",
        objectUri: objectUri
    )

    if isNew {
        try await store.incrementBoostsCount(username: parsed.username, statusId: parsed.statusId)
    }

    context.logger.info("Announce \(isNew ? "stored" : "duplicate") from \(actorUri) on \(objectUri)")

    return APIGatewayResponse(
        statusCode: .accepted,
        headers: ["content-type": "application/json"],
        body: #"{"status":"accepted"}"#
    )
}
```

- [ ] **4d. Wire up Like and Announce in the switch statement**

In the `switch activityType` block, add before `default:`:

```swift
case "Like":
    return try await handleLike(
        json: json,
        username: username,
        actorUri: actorUri,
        context: context
    )

case "Announce":
    return try await handleAnnounce(
        json: json,
        username: username,
        actorUri: actorUri,
        context: context
    )
```

- [ ] **4e. SCP to VM, build, verify no compilation errors, commit**

```bash
git add Sources/InboxHandler/main.swift
git commit -m "Add Like and Announce inbox handlers with count tracking"
```

---

## Task 5: Undo Like + Undo Announce

**Files:** `Sources/InboxHandler/main.swift`

**Dependencies:** Task 4 (Like/Announce handlers establish the pattern)

### Steps

- [ ] **5a. Extend the existing `handleUndo` function**

Add two new branches to the existing `handleUndo` function. Currently it handles `objectType == "Follow"`. Add handling for `"Like"` and `"Announce"`:

```swift
} else if objectType == "Like" {
    context.logger.info("Processing Undo Like from \(actorUri) for \(username)")
    // Extract the object of the Like (the status URI)
    let likeObjectUri: String?
    if let objectDict = json["object"] as? [String: Any] {
        likeObjectUri = extractObjectUri(from: objectDict)
    } else {
        likeObjectUri = nil
    }

    if let likeObjectUri, let parsed = parseStatusUri(likeObjectUri) {
        let wasRemoved = try await store.removeInteraction(
            username: parsed.username,
            actorUri: actorUri,
            type: "Like",
            objectUri: likeObjectUri
        )
        if wasRemoved {
            try await store.decrementLikesCount(username: parsed.username, statusId: parsed.statusId)
        }
    } else {
        context.logger.info("Undo Like with unparseable object from \(actorUri)")
    }

} else if objectType == "Announce" {
    context.logger.info("Processing Undo Announce from \(actorUri) for \(username)")
    let announceObjectUri: String?
    if let objectDict = json["object"] as? [String: Any] {
        announceObjectUri = extractObjectUri(from: objectDict)
    } else {
        announceObjectUri = nil
    }

    if let announceObjectUri, let parsed = parseStatusUri(announceObjectUri) {
        let wasRemoved = try await store.removeInteraction(
            username: parsed.username,
            actorUri: actorUri,
            type: "Announce",
            objectUri: announceObjectUri
        )
        if wasRemoved {
            try await store.decrementBoostsCount(username: parsed.username, statusId: parsed.statusId)
        }
    } else {
        context.logger.info("Undo Announce with unparseable object from \(actorUri)")
    }
```

Insert these before the existing `} else {` that handles unrecognized Undo types.

- [ ] **5b. SCP to VM, build, verify no compilation errors, commit**

```bash
git add Sources/InboxHandler/main.swift
git commit -m "Add Undo Like and Undo Announce handlers with count decrement"
```

---

## Task 6: Create (Reply) Handler

**Files:** `Sources/InboxHandler/main.swift`

**Dependencies:** Task 1 (HTML sanitizer), Task 3 (store methods)

### Steps

- [ ] **6a. Add `handleCreate` function**

```swift
// MARK: - Create Handling

func handleCreate(
    json: [String: Any],
    username: String,
    actorUri: String,
    bodyString: String,
    context: LambdaContext
) async throws -> APIGatewayResponse {
    context.logger.info("Processing Create from \(actorUri) for \(username)")

    // Extract the object (must be an inline Note)
    guard let objectDict = json["object"] as? [String: Any],
          let objectType = objectDict["type"] as? String else {
        context.logger.warning("Create missing inline object from \(actorUri)")
        return APIGatewayResponse(
            statusCode: .accepted,
            headers: ["content-type": "application/json"],
            body: #"{"status":"accepted"}"#
        )
    }

    guard objectType == "Note" else {
        context.logger.info("Create with non-Note object type \(objectType) from \(actorUri)")
        return APIGatewayResponse(
            statusCode: .accepted,
            headers: ["content-type": "application/json"],
            body: #"{"status":"accepted"}"#
        )
    }

    // Must have inReplyTo pointing to one of our statuses
    guard let inReplyTo = objectDict["inReplyTo"] as? String else {
        context.logger.info("Create Note without inReplyTo from \(actorUri), not a reply")
        return APIGatewayResponse(
            statusCode: .accepted,
            headers: ["content-type": "application/json"],
            body: #"{"status":"accepted"}"#
        )
    }

    guard let parsed = parseStatusUri(inReplyTo) else {
        context.logger.info("Create Note replying to non-local status \(inReplyTo) from \(actorUri)")
        return APIGatewayResponse(
            statusCode: .accepted,
            headers: ["content-type": "application/json"],
            body: #"{"status":"accepted"}"#
        )
    }

    // Verify the parent status exists
    guard try await store.getStatus(username: parsed.username, id: parsed.statusId) != nil else {
        context.logger.warning("Create Note replying to non-existent status \(inReplyTo) from \(actorUri)")
        return APIGatewayResponse(
            statusCode: .accepted,
            headers: ["content-type": "application/json"],
            body: #"{"status":"accepted"}"#
        )
    }

    guard let objectUri = objectDict["id"] as? String else {
        context.logger.warning("Create Note missing id from \(actorUri)")
        return APIGatewayResponse(
            statusCode: .badRequest,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Note missing id"}"#
        )
    }

    // Sanitize the content
    let rawContent = objectDict["content"] as? String ?? ""
    let sanitizedContent = HTMLSanitizer.sanitize(rawContent)

    // Store the reply
    let isNew = try await store.storeReply(
        username: parsed.username,
        actorUri: actorUri,
        objectUri: objectUri,
        content: sanitizedContent,
        inReplyTo: inReplyTo,
        raw: bodyString
    )

    if isNew {
        try await store.incrementRepliesCount(username: parsed.username, statusId: parsed.statusId)
    }

    context.logger.info("Reply \(isNew ? "stored" : "duplicate") from \(actorUri) to \(inReplyTo)")

    return APIGatewayResponse(
        statusCode: .accepted,
        headers: ["content-type": "application/json"],
        body: #"{"status":"accepted"}"#
    )
}
```

- [ ] **6b. Wire up Create in the switch statement**

Add before the `default:` case:

```swift
case "Create":
    return try await handleCreate(
        json: json,
        username: username,
        actorUri: actorUri,
        bodyString: bodyString,
        context: context
    )
```

Note: `bodyString` is already available in scope from line 38.

- [ ] **6c. Add `import ActivityPubCore`** at the top of `main.swift` if not already present (it already is -- verify).

- [ ] **6d. SCP to VM, build, verify no compilation errors, commit**

```bash
git add Sources/InboxHandler/main.swift
git commit -m "Add Create (reply) inbox handler with HTML sanitization"
```

---

## Task 7: Delete Handler

**Files:** `Sources/InboxHandler/main.swift`

**Dependencies:** Task 3 (store methods for removeInteraction, removeReply, removeFollower)

### Steps

- [ ] **7a. Add `handleDelete` function**

```swift
// MARK: - Delete Handling

func handleDelete(
    json: [String: Any],
    username: String,
    actorUri: String,
    context: LambdaContext
) async throws -> APIGatewayResponse {
    context.logger.info("Processing Delete from \(actorUri) for \(username)")

    // Extract the object being deleted
    let objectUri: String
    let objectType: String?

    if let objectDict = json["object"] as? [String: Any] {
        objectUri = objectDict["id"] as? String ?? ""
        objectType = objectDict["type"] as? String
    } else if let objectStr = json["object"] as? String {
        objectUri = objectStr
        objectType = nil
    } else {
        context.logger.warning("Delete with unrecognized object format from \(actorUri)")
        return APIGatewayResponse(
            statusCode: .accepted,
            headers: ["content-type": "application/json"],
            body: #"{"status":"accepted"}"#
        )
    }

    guard !objectUri.isEmpty else {
        context.logger.warning("Delete with empty object URI from \(actorUri)")
        return APIGatewayResponse(
            statusCode: .accepted,
            headers: ["content-type": "application/json"],
            body: #"{"status":"accepted"}"#
        )
    }

    // Case 1: Object URI matches our status pattern -- deleting an interaction or reply
    if let parsed = parseStatusUri(objectUri) {
        // Try removing a Like interaction
        let removedLike = try await store.removeInteraction(
            username: parsed.username,
            actorUri: actorUri,
            type: "Like",
            objectUri: objectUri
        )
        if removedLike {
            try await store.decrementLikesCount(username: parsed.username, statusId: parsed.statusId)
            context.logger.info("Deleted Like from \(actorUri) on \(objectUri)")
        }

        // Try removing an Announce interaction
        let removedAnnounce = try await store.removeInteraction(
            username: parsed.username,
            actorUri: actorUri,
            type: "Announce",
            objectUri: objectUri
        )
        if removedAnnounce {
            try await store.decrementBoostsCount(username: parsed.username, statusId: parsed.statusId)
            context.logger.info("Deleted Announce from \(actorUri) on \(objectUri)")
        }

        return APIGatewayResponse(
            statusCode: .accepted,
            headers: ["content-type": "application/json"],
            body: #"{"status":"accepted"}"#
        )
    }

    // Check if it's a reply being deleted (objectUri is the remote Note's id, not our status URI)
    // Try removing as a reply -- the objectUri is the reply Note's own id
    let removedReply = try await store.removeReply(username: username, objectUri: objectUri)
    if removedReply {
        context.logger.info("Deleted reply \(objectUri) from \(actorUri)")
        // We don't know which parent status to decrement without querying, so we skip count update
        // (The reply record would need to be fetched first to get inReplyTo -- a future improvement)
    }

    // Case 2: Actor self-deletion (objectUri matches an actor URI, and actorUri == objectUri)
    if actorUri == objectUri && !objectUri.contains("/statuses/") {
        context.logger.info("Processing actor self-deletion for \(actorUri)")
        let wasRemoved = try await store.removeFollower(username: username, actorUri: actorUri)
        if wasRemoved {
            try await store.decrementFollowerCount(username: username)
            await invalidateFollowersCache(username: username, context: context)
            context.logger.info("Removed follower \(actorUri) via self-deletion")
        }
    } else {
        context.logger.info("Delete for unrecognized object \(objectUri) from \(actorUri)")
    }

    return APIGatewayResponse(
        statusCode: .accepted,
        headers: ["content-type": "application/json"],
        body: #"{"status":"accepted"}"#
    )
}
```

- [ ] **7b. Wire up Delete in the switch statement**

Add before the `default:` case:

```swift
case "Delete":
    return try await handleDelete(
        json: json,
        username: username,
        actorUri: actorUri,
        context: context
    )
```

- [ ] **7c. SCP to VM, build, verify no compilation errors, commit**

```bash
git add Sources/InboxHandler/main.swift
git commit -m "Add Delete inbox handler for interactions, replies, and actor self-deletion"
```

---

## Task 8: Update Handler (Note + Actor)

**Files:** `Sources/InboxHandler/main.swift`

**Dependencies:** Task 1 (HTML sanitizer), Task 3 (store methods for updateReply, updateRemoteActor)

### Steps

- [ ] **8a. Add `handleUpdate` function**

```swift
// MARK: - Update Handling

func handleUpdate(
    json: [String: Any],
    username: String,
    actorUri: String,
    context: LambdaContext
) async throws -> APIGatewayResponse {
    context.logger.info("Processing Update from \(actorUri) for \(username)")

    // Extract the inline object
    guard let objectDict = json["object"] as? [String: Any],
          let objectType = objectDict["type"] as? String else {
        context.logger.warning("Update missing inline object from \(actorUri)")
        return APIGatewayResponse(
            statusCode: .accepted,
            headers: ["content-type": "application/json"],
            body: #"{"status":"accepted"}"#
        )
    }

    if objectType == "Note" {
        // Update a reply Note
        guard let inReplyTo = objectDict["inReplyTo"] as? String,
              let _ = parseStatusUri(inReplyTo) else {
            context.logger.info("Update Note not replying to our status from \(actorUri)")
            return APIGatewayResponse(
                statusCode: .accepted,
                headers: ["content-type": "application/json"],
                body: #"{"status":"accepted"}"#
            )
        }

        guard let objectUri = objectDict["id"] as? String else {
            context.logger.warning("Update Note missing id from \(actorUri)")
            return APIGatewayResponse(
                statusCode: .accepted,
                headers: ["content-type": "application/json"],
                body: #"{"status":"accepted"}"#
            )
        }

        let rawContent = objectDict["content"] as? String ?? ""
        let sanitizedContent = HTMLSanitizer.sanitize(rawContent)

        try await store.updateReply(
            username: username,
            objectUri: objectUri,
            content: sanitizedContent
        )

        context.logger.info("Updated reply \(objectUri) from \(actorUri)")

    } else if ["Person", "Service", "Application", "Organization"].contains(objectType) {
        // Update a remote actor profile
        guard let remoteActorUri = objectDict["id"] as? String else {
            context.logger.warning("Update actor missing id from \(actorUri)")
            return APIGatewayResponse(
                statusCode: .accepted,
                headers: ["content-type": "application/json"],
                body: #"{"status":"accepted"}"#
            )
        }

        // Verify the actor updating is the same as the actor being updated
        guard remoteActorUri == actorUri else {
            context.logger.warning("Update actor mismatch: activity actor=\(actorUri), object id=\(remoteActorUri)")
            return APIGatewayResponse(
                statusCode: .forbidden,
                headers: ["content-type": "application/json"],
                body: #"{"error":"Cannot update another actor's profile"}"#
            )
        }

        // Extract actor fields
        guard let publicKeyObj = objectDict["publicKey"] as? [String: Any],
              let publicKeyPem = publicKeyObj["publicKeyPem"] as? String,
              let inbox = objectDict["inbox"] as? String else {
            context.logger.warning("Update actor missing required fields from \(actorUri)")
            return APIGatewayResponse(
                statusCode: .accepted,
                headers: ["content-type": "application/json"],
                body: #"{"status":"accepted"}"#
            )
        }

        let preferredUsername = objectDict["preferredUsername"] as? String
        var sharedInbox: String?
        if let endpoints = objectDict["endpoints"] as? [String: Any] {
            sharedInbox = endpoints["sharedInbox"] as? String
        }

        let formatter = ISO8601DateFormatter()
        let now = formatter.string(from: Date())

        let updatedActor = RemoteActor(
            actorUri: remoteActorUri,
            publicKeyPem: publicKeyPem,
            preferredUsername: preferredUsername,
            inbox: inbox,
            sharedInbox: sharedInbox,
            fetchedAt: now
        )

        try await store.updateRemoteActor(actorUri: remoteActorUri, data: updatedActor)
        context.logger.info("Updated remote actor profile for \(remoteActorUri)")

    } else {
        context.logger.info("Update with unhandled object type \(objectType) from \(actorUri)")
    }

    return APIGatewayResponse(
        statusCode: .accepted,
        headers: ["content-type": "application/json"],
        body: #"{"status":"accepted"}"#
    )
}
```

- [ ] **8b. Wire up Update in the switch statement**

Add before the `default:` case:

```swift
case "Update":
    return try await handleUpdate(
        json: json,
        username: username,
        actorUri: actorUri,
        context: context
    )
```

- [ ] **8c. SCP to VM, build, verify no compilation errors, commit**

```bash
git add Sources/InboxHandler/main.swift
git commit -m "Add Update inbox handler for Note edits and actor profile refresh"
```

---

## Task 9: Stub Handlers

**Files:** `Sources/InboxHandler/main.swift`

**Dependencies:** None (but do after Tasks 4-8 so the switch statement is clean)

### Steps

- [ ] **9a. Add stub cases to the switch statement**

Replace the existing `default:` case with explicit stub handlers followed by a new default:

```swift
case "Accept", "Reject", "Block", "Move", "Add", "Remove", "Flag":
    let objectUri = extractObjectUri(from: json) ?? "unknown"
    context.logger.info("Stub handler: \(activityType) from \(actorUri), object=\(objectUri)")
    return APIGatewayResponse(
        statusCode: .accepted,
        headers: ["content-type": "application/json"],
        body: #"{"status":"accepted"}"#
    )

case "EmojiReact":
    context.logger.info("Ignored EmojiReact from \(actorUri)")
    return APIGatewayResponse(
        statusCode: .accepted,
        headers: ["content-type": "application/json"],
        body: #"{"status":"accepted"}"#
    )

default:
    context.logger.info("Unhandled activity type: \(activityType) from \(actorUri)")
    return APIGatewayResponse(
        statusCode: .accepted,
        headers: ["content-type": "application/json"],
        body: #"{"status":"accepted"}"#
    )
```

- [ ] **9b. SCP to VM, build, verify no compilation errors, commit**

```bash
git add Sources/InboxHandler/main.swift
git commit -m "Add stub handlers for Accept, Reject, Block, Move, Add, Remove, Flag, EmojiReact"
```

---

## Task 10: Smoke Test Script

**Files:** `scripts/test-inbox.sh`

**Dependencies:** All previous tasks

### Steps

- [ ] **10a. Create `scripts/test-inbox.sh`**

This script tests all inbox handlers against the deployed stage stack. It requires `openssl`, `curl`, and `jq`. It reads `test1`'s private key from SSM to sign requests and POSTs to `test2`'s inbox.

```bash
#!/usr/bin/env bash
set -euo pipefail

# Configuration
STAGE="${STAGE:-stage}"
DOMAIN="${DOMAIN:-activity.happitec.com}"
TARGET_USER="${TARGET_USER:-test2}"
SOURCE_USER="${SOURCE_USER:-test1}"
REGION="${REGION:-ap-southeast-2}"
STACK_NAME="${STACK_NAME:-activity-happitec-${STAGE}}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

pass=0
fail=0
skip=0

log_pass() { echo -e "${GREEN}PASS${NC}: $1"; ((pass++)); }
log_fail() { echo -e "${RED}FAIL${NC}: $1"; ((fail++)); }
log_skip() { echo -e "${YELLOW}SKIP${NC}: $1"; ((skip++)); }

# Fetch the private key from SSM
echo "Fetching ${SOURCE_USER}'s private key from SSM..."
PRIVATE_KEY_PEM=$(aws ssm get-parameter \
    --name "/${STACK_NAME}/${SOURCE_USER}/private-key" \
    --with-decryption \
    --query "Parameter.Value" \
    --output text \
    --region "${REGION}")

if [ -z "$PRIVATE_KEY_PEM" ]; then
    echo "ERROR: Could not fetch private key from SSM"
    exit 1
fi

# Write private key to temp file
KEY_FILE=$(mktemp)
echo "$PRIVATE_KEY_PEM" > "$KEY_FILE"
trap "rm -f $KEY_FILE" EXIT

INBOX_URL="https://${DOMAIN}/users/${TARGET_USER}/inbox"
SOURCE_ACTOR="https://${DOMAIN}/users/${SOURCE_USER}"
KEY_ID="${SOURCE_ACTOR}#main-key"

# HTTP Signature helper (Cavage draft)
sign_and_post() {
    local body="$1"
    local description="$2"

    local date
    date=$(date -u +"%a, %d %b %Y %H:%M:%S GMT")

    local digest
    digest="sha-256=$(echo -n "$body" | openssl dgst -sha256 -binary | openssl base64)"

    local path="/users/${TARGET_USER}/inbox"
    local signing_string="(request-target): post ${path}
host: ${DOMAIN}
date: ${date}
digest: ${digest}"

    local signature
    signature=$(echo -n "$signing_string" | openssl dgst -sha256 -sign "$KEY_FILE" | openssl base64 -A)

    local sig_header="keyId=\"${KEY_ID}\",algorithm=\"rsa-sha256\",headers=\"(request-target) host date digest\",signature=\"${signature}\""

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "$INBOX_URL" \
        -H "Content-Type: application/activity+json" \
        -H "Host: ${DOMAIN}" \
        -H "Date: ${date}" \
        -H "Digest: ${digest}" \
        -H "Signature: ${sig_header}" \
        -d "$body")

    echo "$http_code"
}

# Generate a unique ID for each test
unique_id() {
    echo "https://${DOMAIN}/test/$(uuidgen | tr '[:upper:]' '[:lower:]')"
}

# --- Test: Like ---
echo ""
echo "=== Test: Like ==="
# First, we need a real status URI. Fetch one from the target user's outbox.
STATUS_URI=$(curl -s "https://${DOMAIN}/users/${TARGET_USER}/outbox?page=true" \
    -H "Accept: application/activity+json" | jq -r '.orderedItems[0].object.id // .orderedItems[0].object // empty' 2>/dev/null || echo "")

if [ -z "$STATUS_URI" ]; then
    log_skip "Like -- no statuses found for ${TARGET_USER}"
else
    LIKE_ID=$(unique_id)
    LIKE_BODY=$(cat <<EOF
{
    "@context": "https://www.w3.org/ns/activitystreams",
    "id": "${LIKE_ID}",
    "type": "Like",
    "actor": "${SOURCE_ACTOR}",
    "object": "${STATUS_URI}"
}
EOF
)
    HTTP_CODE=$(sign_and_post "$LIKE_BODY" "Like")
    if [ "$HTTP_CODE" = "202" ]; then
        log_pass "Like returned 202"
    else
        log_fail "Like returned $HTTP_CODE (expected 202)"
    fi
fi

# --- Test: Undo Like ---
echo ""
echo "=== Test: Undo Like ==="
if [ -z "$STATUS_URI" ]; then
    log_skip "Undo Like -- no statuses found"
else
    UNDO_LIKE_ID=$(unique_id)
    UNDO_LIKE_BODY=$(cat <<EOF
{
    "@context": "https://www.w3.org/ns/activitystreams",
    "id": "${UNDO_LIKE_ID}",
    "type": "Undo",
    "actor": "${SOURCE_ACTOR}",
    "object": {
        "id": "${LIKE_ID}",
        "type": "Like",
        "actor": "${SOURCE_ACTOR}",
        "object": "${STATUS_URI}"
    }
}
EOF
)
    HTTP_CODE=$(sign_and_post "$UNDO_LIKE_BODY" "Undo Like")
    if [ "$HTTP_CODE" = "202" ]; then
        log_pass "Undo Like returned 202"
    else
        log_fail "Undo Like returned $HTTP_CODE (expected 202)"
    fi
fi

# --- Test: Announce ---
echo ""
echo "=== Test: Announce ==="
if [ -z "$STATUS_URI" ]; then
    log_skip "Announce -- no statuses found"
else
    ANNOUNCE_ID=$(unique_id)
    ANNOUNCE_BODY=$(cat <<EOF
{
    "@context": "https://www.w3.org/ns/activitystreams",
    "id": "${ANNOUNCE_ID}",
    "type": "Announce",
    "actor": "${SOURCE_ACTOR}",
    "object": "${STATUS_URI}"
}
EOF
)
    HTTP_CODE=$(sign_and_post "$ANNOUNCE_BODY" "Announce")
    if [ "$HTTP_CODE" = "202" ]; then
        log_pass "Announce returned 202"
    else
        log_fail "Announce returned $HTTP_CODE (expected 202)"
    fi
fi

# --- Test: Undo Announce ---
echo ""
echo "=== Test: Undo Announce ==="
if [ -z "$STATUS_URI" ]; then
    log_skip "Undo Announce -- no statuses found"
else
    UNDO_ANNOUNCE_ID=$(unique_id)
    UNDO_ANNOUNCE_BODY=$(cat <<EOF
{
    "@context": "https://www.w3.org/ns/activitystreams",
    "id": "${UNDO_ANNOUNCE_ID}",
    "type": "Undo",
    "actor": "${SOURCE_ACTOR}",
    "object": {
        "id": "${ANNOUNCE_ID}",
        "type": "Announce",
        "actor": "${SOURCE_ACTOR}",
        "object": "${STATUS_URI}"
    }
}
EOF
)
    HTTP_CODE=$(sign_and_post "$UNDO_ANNOUNCE_BODY" "Undo Announce")
    if [ "$HTTP_CODE" = "202" ]; then
        log_pass "Undo Announce returned 202"
    else
        log_fail "Undo Announce returned $HTTP_CODE (expected 202)"
    fi
fi

# --- Test: Create (reply) ---
echo ""
echo "=== Test: Create (reply) ==="
if [ -z "$STATUS_URI" ]; then
    log_skip "Create reply -- no statuses found"
else
    REPLY_ID=$(unique_id)
    CREATE_BODY=$(cat <<EOF
{
    "@context": "https://www.w3.org/ns/activitystreams",
    "id": "$(unique_id)",
    "type": "Create",
    "actor": "${SOURCE_ACTOR}",
    "object": {
        "id": "${REPLY_ID}",
        "type": "Note",
        "attributedTo": "${SOURCE_ACTOR}",
        "inReplyTo": "${STATUS_URI}",
        "content": "<p>This is a <strong>test</strong> reply from the smoke test script.</p>",
        "published": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    }
}
EOF
)
    HTTP_CODE=$(sign_and_post "$CREATE_BODY" "Create reply")
    if [ "$HTTP_CODE" = "202" ]; then
        log_pass "Create (reply) returned 202"
    else
        log_fail "Create (reply) returned $HTTP_CODE (expected 202)"
    fi
fi

# --- Test: Update (Note) ---
echo ""
echo "=== Test: Update (Note) ==="
if [ -z "$STATUS_URI" ] || [ -z "$REPLY_ID" ]; then
    log_skip "Update Note -- no reply to update"
else
    UPDATE_BODY=$(cat <<EOF
{
    "@context": "https://www.w3.org/ns/activitystreams",
    "id": "$(unique_id)",
    "type": "Update",
    "actor": "${SOURCE_ACTOR}",
    "object": {
        "id": "${REPLY_ID}",
        "type": "Note",
        "attributedTo": "${SOURCE_ACTOR}",
        "inReplyTo": "${STATUS_URI}",
        "content": "<p>This is an <em>updated</em> reply.</p>",
        "published": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    }
}
EOF
)
    HTTP_CODE=$(sign_and_post "$UPDATE_BODY" "Update Note")
    if [ "$HTTP_CODE" = "202" ]; then
        log_pass "Update (Note) returned 202"
    else
        log_fail "Update (Note) returned $HTTP_CODE (expected 202)"
    fi
fi

# --- Test: Delete (reply) ---
echo ""
echo "=== Test: Delete (reply) ==="
if [ -z "$REPLY_ID" ]; then
    log_skip "Delete reply -- no reply to delete"
else
    DELETE_BODY=$(cat <<EOF
{
    "@context": "https://www.w3.org/ns/activitystreams",
    "id": "$(unique_id)",
    "type": "Delete",
    "actor": "${SOURCE_ACTOR}",
    "object": {
        "id": "${REPLY_ID}",
        "type": "Tombstone"
    }
}
EOF
)
    HTTP_CODE=$(sign_and_post "$DELETE_BODY" "Delete reply")
    if [ "$HTTP_CODE" = "202" ]; then
        log_pass "Delete (reply) returned 202"
    else
        log_fail "Delete (reply) returned $HTTP_CODE (expected 202)"
    fi
fi

# --- Test: Actor mismatch (security) ---
echo ""
echo "=== Test: Actor mismatch (should be rejected) ==="
SPOOFED_BODY=$(cat <<EOF
{
    "@context": "https://www.w3.org/ns/activitystreams",
    "id": "$(unique_id)",
    "type": "Like",
    "actor": "https://evil.example.com/users/attacker",
    "object": "${STATUS_URI:-https://example.com/fake}"
}
EOF
)
HTTP_CODE=$(sign_and_post "$SPOOFED_BODY" "Spoofed actor")
if [ "$HTTP_CODE" = "403" ]; then
    log_pass "Spoofed actor rejected with 403"
elif [ "$HTTP_CODE" = "401" ]; then
    log_pass "Spoofed actor rejected with 401"
else
    log_fail "Spoofed actor returned $HTTP_CODE (expected 403)"
fi

# --- Test: Like -> Undo -> re-Like sequence ---
echo ""
echo "=== Test: Like -> Undo -> re-Like sequence ==="
if [ -z "$STATUS_URI" ]; then
    log_skip "Like sequence -- no statuses found"
else
    SEQ_LIKE_ID=$(unique_id)
    SEQ_LIKE_BODY=$(cat <<EOF
{
    "@context": "https://www.w3.org/ns/activitystreams",
    "id": "${SEQ_LIKE_ID}",
    "type": "Like",
    "actor": "${SOURCE_ACTOR}",
    "object": "${STATUS_URI}"
}
EOF
)
    HTTP_CODE=$(sign_and_post "$SEQ_LIKE_BODY" "Sequence Like 1")
    if [ "$HTTP_CODE" = "202" ]; then
        # Undo it
        SEQ_UNDO_ID=$(unique_id)
        SEQ_UNDO_BODY=$(cat <<EOF
{
    "@context": "https://www.w3.org/ns/activitystreams",
    "id": "${SEQ_UNDO_ID}",
    "type": "Undo",
    "actor": "${SOURCE_ACTOR}",
    "object": {
        "id": "${SEQ_LIKE_ID}",
        "type": "Like",
        "actor": "${SOURCE_ACTOR}",
        "object": "${STATUS_URI}"
    }
}
EOF
)
        HTTP_CODE2=$(sign_and_post "$SEQ_UNDO_BODY" "Sequence Undo Like")
        # Re-Like
        SEQ_RELIKE_ID=$(unique_id)
        SEQ_RELIKE_BODY=$(cat <<EOF
{
    "@context": "https://www.w3.org/ns/activitystreams",
    "id": "${SEQ_RELIKE_ID}",
    "type": "Like",
    "actor": "${SOURCE_ACTOR}",
    "object": "${STATUS_URI}"
}
EOF
)
        HTTP_CODE3=$(sign_and_post "$SEQ_RELIKE_BODY" "Sequence Like 2")
        if [ "$HTTP_CODE2" = "202" ] && [ "$HTTP_CODE3" = "202" ]; then
            log_pass "Like -> Undo -> re-Like sequence all returned 202"
        else
            log_fail "Like -> Undo -> re-Like: Undo=$HTTP_CODE2 re-Like=$HTTP_CODE3"
        fi
    else
        log_fail "Like -> Undo -> re-Like: initial Like returned $HTTP_CODE"
    fi
fi

# --- Summary ---
echo ""
echo "================================"
echo -e "Results: ${GREEN}${pass} passed${NC}, ${RED}${fail} failed${NC}, ${YELLOW}${skip} skipped${NC}"
echo "================================"

if [ "$fail" -gt 0 ]; then
    exit 1
fi
```

- [ ] **10b. Make the script executable and commit**

```bash
chmod +x scripts/test-inbox.sh
git add scripts/test-inbox.sh
git commit -m "Add smoke test script for inbox interaction handlers"
```

---

## Summary of Commits

| # | Commit message | Files |
|---|---------------|-------|
| 1 | Add HTML sanitizer with TDD tests for inbox content sanitization | `Sources/ActivityPubCore/HTMLSanitizer.swift`, `Tests/ActivityPubCoreTests/HTMLSanitizerTests.swift` |
| 2 | Add actor/signature verification to prevent spoofed inbox activities | `Sources/InboxHandler/main.swift` |
| 3 | Add DynamoDB store methods for interactions, replies, and count tracking | `Sources/ActivityPubCore/DynamoDBStore.swift` |
| 4 | Add Like and Announce inbox handlers with count tracking | `Sources/InboxHandler/main.swift` |
| 5 | Add Undo Like and Undo Announce handlers with count decrement | `Sources/InboxHandler/main.swift` |
| 6 | Add Create (reply) inbox handler with HTML sanitization | `Sources/InboxHandler/main.swift` |
| 7 | Add Delete inbox handler for interactions, replies, and actor self-deletion | `Sources/InboxHandler/main.swift` |
| 8 | Add Update inbox handler for Note edits and actor profile refresh | `Sources/InboxHandler/main.swift` |
| 9 | Add stub handlers for Accept, Reject, Block, Move, Add, Remove, Flag, EmojiReact | `Sources/InboxHandler/main.swift` |
| 10 | Add smoke test script for inbox interaction handlers | `scripts/test-inbox.sh` |

## Parallelization Notes

- Tasks 1, 2, and 3 have no dependencies and can run in parallel.
- Tasks 4-8 depend on Tasks 2+3 being complete. They can run sequentially or in parallel (they modify different sections of `main.swift`).
- Task 9 should be last among the InboxHandler changes (for a clean switch statement).
- Task 10 should be last (needs all handlers in place for meaningful smoke testing).
