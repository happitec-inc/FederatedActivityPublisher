/// Converts posted text into the HTML that goes into an ActivityPub `Note`'s `content` field.
///
/// `PostHandler` calls ``convertTextToHTML(_:)`` on the user-supplied post body before
/// storing the note and fanning it out to followers. The result is then run through
/// ``HTMLSanitizer`` before storage, so this file does not need to worry about XSS.
///
/// The converter tries to detect markdown: if the parsed document contains any formatting
/// markup (bold, links, headings, etc.) it uses `ActivityPubHTMLVisitor` to render it;
/// otherwise it falls back to the plain-text path that handles paragraph splitting and
/// URL autolinking. This lets users write plain text naturally while still supporting
/// markdown for those who use it.
import Foundation
import Markdown

/// Convert text to ActivityPub-compatible HTML.
///
/// If the input contains markdown formatting (bold, italic, links, headers, lists,
/// code blocks, etc.), it is parsed as markdown and rendered to HTML. Plain text
/// without markdown formatting falls back to the original paragraph/autolink behavior.
///
/// The pipeline is: markdown parse -> HTML render -> sanitize (caller responsibility).
///
/// - Parameter text: Text input from the posting API, possibly containing markdown.
/// - Returns: HTML string suitable for ActivityPub Note content.
public func convertTextToHTML(_ text: String) -> String {
    if text.isEmpty {
        return "<p></p>"
    }

    let document = Document(parsing: text)

    // Check if the document contains any actual markdown formatting.
    // If it's all plain text (just paragraphs with text and soft/line breaks),
    // use the legacy plain-text path which handles URL autolinking.
    if isPlainText(document) {
        return convertPlainTextToHTML(text)
    }

    // Render markdown to HTML
    let visitor = ActivityPubHTMLVisitor()
    let html = visitor.render(document)

    return html
}

/// Check whether a parsed markdown document contains only plain text
/// (no formatting markup like bold, italic, links, headers, code, etc.).
func isPlainText(_ document: Document) -> Bool {
    var checker = PlainTextChecker()
    checker.visit(document)
    return !checker.hasFormatting
}

/// Legacy plain-text to HTML conversion.
///
/// Applies the following transformations in order:
/// 1. HTML-escape special characters (`<`, `>`, `&`, `"`)
/// 2. Split on double newlines into paragraphs, wrap each in `<p>...</p>`
/// 3. Convert single newlines within paragraphs to `<br>`
/// 4. Autolink URLs (`https?://...`) to `<a href="...">...</a>`
func convertPlainTextToHTML(_ text: String) -> String {
    let paragraphs = text.components(separatedBy: "\n\n")

    let htmlParagraphs = paragraphs.map { paragraph -> String in
        let escaped = htmlEscape(paragraph)
        let linked = autolinkURLs(escaped)
        let withBreaks = linked.replacingOccurrences(of: "\n", with: "<br>")
        return "<p>\(withBreaks)</p>"
    }

    return htmlParagraphs.joined()
}

/// Escape HTML special characters.
func htmlEscape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

/// Detect and wrap URLs in anchor tags.
func autolinkURLs(_ text: String) -> String {
    // Match http:// or https:// URLs up to whitespace or end of string.
    // Exclude trailing punctuation that is likely sentence-ending.
    let pattern = #"https?://[^\s<>&"]+[^\s<>&".,;:!?\)\]\}]"#

    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
        return text
    }

    let nsText = text as NSString
    let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))

    if matches.isEmpty {
        return text
    }

    var result = ""
    var lastEnd = 0

    for match in matches {
        let matchRange = match.range
        result += nsText.substring(with: NSRange(location: lastEnd, length: matchRange.location - lastEnd))

        let url = nsText.substring(with: matchRange)
        result += "<a href=\"\(url)\">\(url)</a>"

        lastEnd = matchRange.location + matchRange.length
    }

    result += nsText.substring(from: lastEnd)

    return result
}

// MARK: - Plain Text Checker

/// Walks a Markdown AST to determine if it contains any formatting markup.
private struct PlainTextChecker: MarkupWalker {
    var hasFormatting = false

    mutating func visitHeading(_ heading: Heading) {
        hasFormatting = true
    }

    mutating func visitStrong(_ strong: Strong) {
        hasFormatting = true
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        hasFormatting = true
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
        hasFormatting = true
    }

    mutating func visitLink(_ link: Markdown.Link) {
        hasFormatting = true
    }

    mutating func visitImage(_ image: Markdown.Image) {
        hasFormatting = true
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        hasFormatting = true
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        hasFormatting = true
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        hasFormatting = true
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) {
        hasFormatting = true
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) {
        hasFormatting = true
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        hasFormatting = true
    }

    // Note: HTMLBlock and InlineHTML are NOT considered formatting markers.
    // Users typing angle brackets (e.g., "<b>") in plain text should not
    // trigger the markdown path -- they should be HTML-escaped via the
    // plain text path. If actual markdown formatting is present (bold, links,
    // etc.), those will be detected by the other visitors above.
}

// MARK: - HTML Visitor

/// Renders a Markdown AST to ActivityPub-compatible HTML.
///
/// Produces HTML using only tags that are common in ActivityPub:
/// `<p>`, `<br>`, `<a>`, `<strong>`, `<em>`, `<del>`, `<code>`, `<pre>`,
/// `<blockquote>`, `<ul>`, `<ol>`, `<li>`.
///
/// Headers are rendered as `<p><strong>...</strong></p>` since most
/// ActivityPub implementations strip header tags.
struct ActivityPubHTMLVisitor {

    func render(_ document: Document) -> String {
        var parts: [String] = []
        for child in document.children {
            parts.append(renderBlock(child))
        }
        return parts.joined()
    }

    // MARK: - Block-level rendering

    private func renderBlock(_ markup: any Markup) -> String {
        switch markup {
        case let paragraph as Paragraph:
            let inline = renderInlineChildren(paragraph)
            return "<p>\(inline)</p>"

        case let heading as Heading:
            // Render headings as bold paragraphs for ActivityPub compatibility
            let inline = renderInlineChildren(heading)
            return "<p><strong>\(inline)</strong></p>"

        case let codeBlock as CodeBlock:
            let escaped = htmlEscape(codeBlock.code.hasSuffix("\n")
                ? String(codeBlock.code.dropLast())
                : codeBlock.code)
            return "<pre><code>\(escaped)</code></pre>"

        case let blockQuote as BlockQuote:
            var inner: [String] = []
            for child in blockQuote.children {
                inner.append(renderBlock(child))
            }
            return "<blockquote>\(inner.joined())</blockquote>"

        case let unorderedList as UnorderedList:
            var items: [String] = []
            for item in unorderedList.listItems {
                items.append(renderListItem(item))
            }
            return "<ul>\(items.joined())</ul>"

        case let orderedList as OrderedList:
            var items: [String] = []
            for item in orderedList.listItems {
                items.append(renderListItem(item))
            }
            return "<ol>\(items.joined())</ol>"

        case _ as ThematicBreak:
            // Thematic breaks aren't well supported in AP; render as empty paragraph
            return "<p>---</p>"

        case let htmlBlock as HTMLBlock:
            // User-authored text should not contain raw HTML -- escape it
            return "<p>\(htmlEscape(htmlBlock.rawHTML))</p>"

        default:
            // Fallback: render children
            var parts: [String] = []
            for child in markup.children {
                parts.append(renderBlock(child))
            }
            return parts.joined()
        }
    }

    private func renderListItem(_ item: ListItem) -> String {
        // If a list item contains a single paragraph, render inline content directly.
        // If it contains multiple blocks, render them all.
        let children = Array(item.children)
        if children.count == 1, let paragraph = children.first as? Paragraph {
            return "<li>\(renderInlineChildren(paragraph))</li>"
        }

        var parts: [String] = []
        for child in children {
            if let paragraph = child as? Paragraph {
                parts.append(renderInlineChildren(paragraph))
            } else {
                parts.append(renderBlock(child))
            }
        }
        return "<li>\(parts.joined())</li>"
    }

    // MARK: - Inline rendering

    private func renderInlineChildren(_ markup: any Markup) -> String {
        var parts: [String] = []
        for child in markup.children {
            parts.append(renderInline(child))
        }
        return parts.joined()
    }

    private func renderInline(_ markup: any Markup) -> String {
        switch markup {
        case let text as Markdown.Text:
            return htmlEscape(text.string)

        case let strong as Strong:
            return "<strong>\(renderInlineChildren(strong))</strong>"

        case let emphasis as Emphasis:
            return "<em>\(renderInlineChildren(emphasis))</em>"

        case let strikethrough as Strikethrough:
            return "<del>\(renderInlineChildren(strikethrough))</del>"

        case let code as InlineCode:
            return "<code>\(htmlEscape(code.code))</code>"

        case let link as Markdown.Link:
            let content = renderInlineChildren(link)
            if let dest = link.destination {
                return "<a href=\"\(htmlEscape(dest))\">\(content)</a>"
            }
            return content

        case let image as Markdown.Image:
            // Images aren't well supported in AP Note content;
            // render as a link to the image
            let alt = renderInlineChildren(image)
            if let src = image.source {
                return "<a href=\"\(htmlEscape(src))\">\(alt.isEmpty ? htmlEscape(src) : alt)</a>"
            }
            return alt

        case _ as SoftBreak:
            return "<br>"

        case _ as LineBreak:
            return "<br>"

        case let html as InlineHTML:
            // User-authored text should not contain raw HTML -- escape it
            return htmlEscape(html.rawHTML)

        default:
            return renderInlineChildren(markup)
        }
    }
}
