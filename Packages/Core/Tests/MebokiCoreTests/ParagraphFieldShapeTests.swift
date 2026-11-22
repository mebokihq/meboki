import CoreGraphics
import Foundation
import Testing
@testable import MebokiCore

/// Which sibling fields `SiblingParagraphsStrategy` may join into one document.
@Suite struct ParagraphFieldShapeTests {
    typealias F = ParagraphFieldShape.Field

    static func para(_ y: CGFloat, _ h: CGFloat = 20) -> F {
        F(role: "AXTextArea", frame: CGRect(x: 157, y: y, width: 793, height: h))
    }

    @Test func libreOfficeParagraphsAreADocument() {
        // Unlabelled, childless text areas stacked top to bottom (an empty paragraph has a frame too).
        let fields = [Self.para(330), Self.para(356), Self.para(382, 18), Self.para(400), Self.para(426, 60)]
        #expect(ParagraphFieldShape.isDocument(fields))
        #expect(ParagraphFieldShape.isParagraphList(fields))
    }

    /// Obsidian, probed 2026-11-22: the inline title (13 characters) and the note body are sibling text areas; the
    /// body holds the editor's lines as children. Joined, the note became a "document" and lost the single-field
    /// handling (the scroll fixes didn't apply).
    @Test func obsidianTitleAndBodyAreNot() {
        let title = F(role: "AXTextArea", childCount: 1, frame: CGRect(x: 300, y: 120, width: 700, height: 40))
        let body = F(role: "AXTextArea", childCount: 48, frame: CGRect(x: 300, y: 170, width: 700, height: 900))
        #expect(!ParagraphFieldShape.isDocument([title, body]))
        #expect(!ParagraphFieldShape.isParagraphList([title, body]))
        // Even a title without children doesn't make it one: the body is a rich editor.
        var bare = title
        bare.childCount = 0
        #expect(!ParagraphFieldShape.isDocument([bare, body]))
    }

    /// Pages: the body, header and footer are separate labelled text areas.
    @Test func pagesBodyHeaderFooterAreNot() {
        let header = F(role: "AXTextArea", label: "Header", frame: CGRect(x: 100, y: 80, width: 600, height: 30))
        let body = F(role: "AXTextArea", label: "Body", frame: CGRect(x: 100, y: 120, width: 600, height: 700))
        let footer = F(role: "AXTextArea", label: "Footer", frame: CGRect(x: 100, y: 830, width: 600, height: 30))
        #expect(!ParagraphFieldShape.isDocument([header, body, footer]))
    }

    @Test func sideBySideOrOverlappingFieldsAreNot() {
        let left = F(role: "AXTextArea", frame: CGRect(x: 0, y: 100, width: 300, height: 200))
        let right = F(role: "AXTextArea", frame: CGRect(x: 320, y: 100, width: 300, height: 200))
        #expect(!ParagraphFieldShape.isDocument([left, right]))
        // Out of order (the second above the first).
        #expect(!ParagraphFieldShape.isDocument([Self.para(400), Self.para(300)]))
        // One pixel of overlap is fine (rounding), more isn't.
        #expect(ParagraphFieldShape.isDocument([Self.para(300, 21), Self.para(320)]))
        #expect(!ParagraphFieldShape.isDocument([Self.para(300, 30), Self.para(320)]))
    }

    @Test func otherRolesUnknownFramesAndCounts() {
        #expect(!ParagraphFieldShape.isDocument([Self.para(300)]))
        #expect(!ParagraphFieldShape.isDocument([Self.para(300), F(role: "AXTextField", frame: CGRect(x: 157, y: 330, width: 793, height: 20))]))
        #expect(!ParagraphFieldShape.isDocument([Self.para(300), F(role: "AXTextArea", frame: nil)]))
        let many = (0...ParagraphFieldShape.maxParagraphs).map { Self.para(CGFloat($0) * 20) }
        #expect(!ParagraphFieldShape.isDocument(many))
    }
}
