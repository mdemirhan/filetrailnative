import Foundation
import Testing

@testable import FTAppKit

/// Where a link in Markdown's Preview leads, and the names its headings go by.
struct MarkdownLinkTests {
    private let file = URL(fileURLWithPath: "/Users/me/project/README.md")

    /// The link `destination` as the Preview's text has it: read with the file's address as its base.
    private func link(_ destination: String) throws -> URL {
        try #require(URL(string: destination, relativeTo: file))
    }

    private func target(_ destination: String) throws -> MarkdownLink? {
        MarkdownLink.target(of: try link(destination), shown: "/Users/me/project/README.md")
    }

    // A relative path is a file beside the Markdown, its ".." resolved, its spaces and accents read from the link's
    // escapes; a heading after it goes with it.
    @Test func aPathIsAFileOnTheDiskBesideTheMarkdown() throws {
        #expect(try target("docs/setup.md") == .disk(path: "/Users/me/project/docs/setup.md", heading: nil))
        #expect(try target("./docs/../LICENSE") == .disk(path: "/Users/me/project/LICENSE", heading: nil))
        let accented = MarkdownLink.disk(path: "/Users/me/other/Notes été.md", heading: "to-do")
        #expect(try target("../other/Notes%20%C3%A9t%C3%A9.md#to-do") == accented)
        #expect(try target("/etc/hosts") == .disk(path: "/etc/hosts", heading: nil))
        #expect(try target("docs/") == .disk(path: "/Users/me/project/docs", heading: nil))
    }

    // A heading of the file shown, by `#name` or by the file's own name with one; the file's own name alone is its top.
    @Test func aLinkIntoTheFileShownIsOneOfItsHeadings() throws {
        #expect(try target("#install") == .heading("install"))
        #expect(try target("README.md#install") == .heading("install"))
        #expect(try target("README.md") == .heading(nil))
    }

    // A web page and an email address are the system's to open; a link with no address leads nowhere.
    @Test func aWebPageOrAnEmailAddressIsTheSystems() throws {
        let page = try #require(URL(string: "https://example.com/a?b=1#c"))
        #expect(MarkdownLink.target(of: page, shown: nil) == .other(page))
        let mail = try #require(URL(string: "mailto:someone@example.com"))
        #expect(MarkdownLink.target(of: mail, shown: nil) == .other(mail))
        #expect(
            MarkdownLink.target(of: "https://example.com", shown: nil) == .other(URL(string: "https://example.com")!))
        #expect(MarkdownLink.target(of: "docs/setup.md", shown: nil) == nil)
        #expect(MarkdownLink.target(of: 42, shown: nil) == nil)
    }

    // A heading's name is its text in lowercase, spaces as hyphens, punctuation left out and code kept as its text;
    // the same text again is named with -1, then -2.
    @Test func headingsAreNamedAsGitHubNamesThem() {
        let markdown = """
            # File Trail

            ## Getting Started!

            Text.

            ### Use `fd` (fast) — or *not*

            ## FAQ

            ## FAQ

            Setext Heading
            --------------

            ## Été 2026 & co_op

            ## FAQ
            """
        let headings = MarkdownLink.headings(in: markdown)
        #expect(
            headings.map(\.name) == [
                "file-trail", "getting-started", "use-fd-fast--or-not", "faq", "faq-1", "setext-heading",
                "été-2026--co_op", "faq-2",
            ])
        #expect(headings.map(\.line) == [1, 3, 7, 9, 11, 13, 16, 18])
        #expect(MarkdownLink.headingLine("faq-1", in: markdown) == 11)
        #expect(MarkdownLink.headingLine("Getting-Started", in: markdown) == 3)
        #expect(MarkdownLink.headingLine("nowhere", in: markdown) == nil)
    }
}
