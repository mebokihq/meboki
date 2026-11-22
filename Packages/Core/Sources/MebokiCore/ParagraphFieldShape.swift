import CoreGraphics
import Foundation

/// Whether sibling text fields are the paragraphs of one document (LibreOffice Writer: one `AXTextArea` per
/// paragraph on screen), as opposed to separate fields that happen to sit together.
///
/// Only plain paragraph fields qualify:
/// - every sibling is a text area (`role`), and there are at least two;
/// - none has a label (`AXDescription` / `AXTitle`): labelled fields are separate fields (Pages: "Body", "Header",
///   "Footer");
/// - none has children: a field with children is a rich editor measured through its text leaves (Obsidian: the
///   inline note title and the note body are two sibling text areas, but the body holds the editor's lines);
/// - they're stacked top to bottom without overlapping (side-by-side fields of a form don't qualify).
/// LibreOffice's paragraph fields have no label and no children (probed 2026-11-22). Obsidian matched before the
/// children rule (2026-11-22) and was handled as a two-paragraph document.
public enum ParagraphFieldShape {
    public struct Field: Sendable, Equatable {
        public var role: String
        /// `AXDescription` or `AXTitle`, empty when unlabelled.
        public var label: String
        public var childCount: Int
        /// AX frame (top-left origin, y down); nil when unknown.
        public var frame: CGRect?

        public init(role: String, label: String = "", childCount: Int = 0, frame: CGRect?) {
            self.role = role
            self.label = label
            self.childCount = childCount
            self.frame = frame
        }
    }

    public static let textAreaRole = "AXTextArea"
    public static let maxParagraphs = 400

    /// The siblings are the paragraphs of one document.
    public static func isDocument(_ fields: [Field]) -> Bool {
        guard fields.count >= 2, fields.count <= maxParagraphs else { return false }
        var bottom = -CGFloat.greatestFiniteMagnitude
        for f in fields {
            guard f.role == textAreaRole, f.label.isEmpty, f.childCount == 0,
                  let frame = f.frame, frame.minY >= bottom - 1 else { return false }
            bottom = frame.maxY
        }
        return true
    }

    /// The cheap part, checked on every read of the paragraph list: all text areas, unlabelled, no children, 2–400.
    /// (The stacking is checked once, when the surface is made.)
    public static func isParagraphList(_ fields: [Field]) -> Bool {
        fields.count >= 2 && fields.count <= maxParagraphs
            && fields.allSatisfy { $0.role == textAreaRole && $0.label.isEmpty && $0.childCount == 0 }
    }
}
