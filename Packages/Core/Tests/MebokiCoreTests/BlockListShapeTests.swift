import Testing
@testable import MebokiCore

/// Which text areas `NestedBlocksStrategy` joins into one document (Notion's blocks), and which trees it leaves alone.
@Suite struct BlockListShapeTests {
    typealias N = BlockListShape.Node<String>

    static func area(_ name: String, editable: Bool = true, kids: [N] = []) -> N {
        N(ref: name, role: "AXTextArea", classes: ["content-editable-leaf-rtl", "notranslate"], editable: editable) { kids }
    }

    static func group(_ name: String, _ classes: [String] = [], subrole: String = "", _ kids: [N] = []) -> N {
        N(ref: name, role: "AXGroup", subrole: subrole, classes: classes) { kids }
    }

    /// A block as probed: wrapper (class) > group > ... the text area is wrapper > text area, per block one more group.
    static func block(_ type: String, _ name: String, extra: [N] = []) -> N {
        group("g-\(name)", [], [group("w-\(name)", ["notion-selectable", "notion-\(type)-block"], extra + [area(name)])])
    }

    /// Notion page: root (contenteditable) > page content > list of blocks; title beside, in a header group.
    static func page(_ blocks: [N]) -> (root: N, list: N, title: N) {
        let list = group("list", [], blocks)
        let content = group("content", ["notion-page-content"], [list])
        let title = area("title")
        let header = group("header", ["notion-page-block"], [title])
        // Chromium's contenteditable host, as probed: a text area with the application-group subrole.
        let root = N(ref: "root", role: "AXTextArea", subrole: "AXApplicationGroup", classes: ["whenContentEditable"],
                     editable: true) { [header, content] }
        return (root, list, title)
    }

    /// Ancestors of `target` from its parent up to the root, found in the built tree.
    static func chain(of target: String, in root: N) -> (node: N, ancestors: [N])? {
        func go(_ n: N, _ path: [N]) -> (N, [N])? {
            if n.ref == target { return (n, path.reversed()) }
            for c in n.children { if let r = go(c, path + [n]) { return r } }
            return nil
        }
        return go(root, []).map { ($0.0, $0.1) }
    }

    static func locate(_ target: String, in root: N) -> BlockListShape.Located<String>? {
        guard let (node, up) = chain(of: target, in: root) else { return nil }
        return BlockListShape.locate(focus: node, ancestors: up, same: ==)
    }

    @Test func notionBlocksInOrderWithoutTitleAndCode() {
        let p = Self.page([
            Self.block("text", "p1"),
            Self.block("bulleted_list", "b1", extra: [Self.group("bullet", ["pseudoBefore"])]),
            Self.block("to_do", "t1", extra: [Self.group("checkbox")]),
            Self.block("header", "h1"),
            Self.block("code", "c1"),
            Self.block("text", "p2"),
        ])
        let found = Self.locate("t1", in: p.root)
        #expect(found?.members.map(\.ref) == ["p1", "b1", "t1", "h1", "p2"])
        #expect(found?.focusIndex == 2)
        #expect(found?.list.ref == "list")
        #expect(found?.root.ref == "root")
    }

    @Test func focusInCodeBlockOrTitleIsNotADocument() {
        let p = Self.page([Self.block("text", "p1"), Self.block("code", "c1"), Self.block("text", "p2")])
        #expect(Self.locate("c1", in: p.root) == nil)
        #expect(Self.locate("title", in: p.root) == nil)
    }

    @Test func nestedToggleKeepsDocumentOrder() {
        let toggle = Self.group("tg", [], [Self.group("tw", ["notion-toggle-block"], [
            Self.area("head"),
            Self.group("inside", [], [Self.block("text", "child1"), Self.block("text", "child2")]),
        ])])
        let p = Self.page([Self.block("text", "a"), toggle, Self.block("text", "z")])
        let found = Self.locate("child2", in: p.root)
        #expect(found?.members.map(\.ref) == ["a", "head", "child1", "child2", "z"])
        #expect(found?.focusIndex == 3)
    }

    @Test func singleBlockPageIsNotAList() {
        let p = Self.page([Self.block("text", "only")])
        #expect(Self.locate("only", in: p.root) == nil)
    }

    @Test func plainWebFormWithTextAreasIsNot() {
        // Two text areas in a form, no editable root around them.
        let form = Self.group("form", [], [Self.group("f1", [], [Self.area("a")]), Self.group("f2", [], [Self.area("b")])])
        let page = Self.group("page", [], [form])
        #expect(Self.locate("a", in: page) == nil)
    }

    @Test func libreOfficeSiblingsAreNot() {
        // Childless sibling paragraphs in a plain parent: `ParagraphFieldShape`'s, not this shape's.
        let parent = Self.group("doc", [], (1...5).map { Self.area("p\($0)") })
        #expect(Self.locate("p3", in: Self.group("root", [], [parent])) == nil)
    }

    @Test func obsidianTitleAndBodyAreNot() {
        let body = Self.area("body", kids: [Self.group("line1"), Self.group("line2")])
        let parent = Self.group("view", [], [Self.area("title"), body])
        #expect(Self.locate("body", in: Self.group("root", [], [parent])) == nil)
    }

    @Test func notEditableTextAreasAreNotBlocks() {
        let p = Self.page([Self.block("text", "a"), Self.group("ro", [], [Self.area("ro", editable: false)]), Self.block("text", "b")])
        #expect(Self.locate("a", in: p.root)?.members.map(\.ref) == ["a", "b"])
    }

    @Test func membershipNeedsTheListAbove() {
        let p = Self.page([Self.block("text", "a"), Self.block("text", "b")])
        guard let (b, up) = Self.chain(of: "b", in: p.root), let (t, tup) = Self.chain(of: "title", in: p.root) else {
            Issue.record("tree"); return
        }
        #expect(BlockListShape.belongs(b, ancestors: up, toList: "list", same: ==))
        #expect(!BlockListShape.belongs(t, ancestors: tup, toList: "list", same: ==))
    }
}

extension BlockListShapeTests {
    /// The root has focus (a click passes through it): the same list, found from the root, with no caret block.
    @Test func rootFocusFindsTheListBelowTheTitle() {
        let p = Self.page([Self.block("text", "p1"), Self.block("code", "c1"), Self.block("text", "p2")])
        let found = BlockListShape.locate(root: p.root)
        #expect(found?.members.map(\.ref) == ["p1", "p2"])
        #expect(found?.list.ref == "list")
        #expect(found?.focusIndex == nil)
    }

    @Test func rootFocusNeedsTheRootShape() {
        let plain = Self.group("page", [], [Self.block("text", "a"), Self.block("text", "b")])
        #expect(BlockListShape.locate(root: plain) == nil)
        // A single editable text area with no blocks around it (an ordinary rich editor's root).
        let editor = BlockListShapeTests.N(ref: "ed", role: "AXTextArea", subrole: "AXApplicationGroup", editable: true) { [] }
        #expect(BlockListShape.locate(root: editor) == nil)
    }
}

extension BlockListShapeTests {
    /// A group (fieldset, form) with the application-group subrole that isn't an editable text area is no editor root.
    @Test func aFieldsetAroundTwoTextAreasIsNotAnEditorRoot() {
        let list = Self.group("list", [], [Self.area("a"), Self.area("b")])
        let fieldset = BlockListShapeTests.N(ref: "fs", role: "AXGroup", subrole: "AXApplicationGroup") { [list] }
        guard let (a, up) = Self.chain(of: "a", in: fieldset) else { Issue.record("tree"); return }
        #expect(BlockListShape.locate(focus: a, ancestors: up, same: ==) == nil)
    }

    /// With the root focused, the list must hold the editor's text, or the document would be only a table's cells.
    @Test func rootFocusNeedsTheListToHoldTheText() {
        let p = Self.page([Self.block("text", "p1"), Self.block("text", "p2")])
        let len: (BlockListShapeTests.N) -> Int = { $0.ref == "p1" ? 100 : 100 }
        // Notion: the root's text is the blocks plus a title: close to the blocks'.
        #expect(BlockListShape.locate(root: p.root, rootTextLength: 230, blockLength: len) != nil)
        // A rich editor whose body text is far longer than the two cells in the list.
        #expect(BlockListShape.locate(root: p.root, rootTextLength: 5000, blockLength: len) == nil)
        // No length known: the shape alone decides.
        #expect(BlockListShape.locate(root: p.root) != nil)
    }

    /// A root with a huge tree and no list gives up after a bounded search.
    @Test func theSearchForAListIsBounded() {
        var visited = 0
        func deep(_ level: Int) -> BlockListShapeTests.N {
            visited += 1
            return BlockListShapeTests.N(ref: "n\(visited)", role: "AXGroup") {
                level == 0 ? [] : (0..<4).map { _ in deep(level - 1) }
            }
        }
        let root = BlockListShapeTests.N(ref: "r", role: "AXTextArea", subrole: "AXApplicationGroup", editable: true) {
            [deep(6)]
        }
        var touched = 0
        let counted = BlockListShapeTests.N(ref: "r2", role: "AXTextArea", subrole: "AXApplicationGroup", editable: true) {
            touched += 1
            return root.children
        }
        #expect(BlockListShape.locate(root: counted) == nil)
        #expect(visited < 400)
    }

    @Test func memberCountIsCappedInsideOneBigList() {
        let kids = (0..<(BlockListShape.maxMembers + 50)).map { Self.area("a\($0)") }
        let list = Self.group("list", [], kids)
        #expect(BlockListShape.blocks(under: list).count == BlockListShape.maxMembers)
    }
}

/// Shapes that must never be taken for a block editor: they keep the plain single-field path.
extension BlockListShapeTests {
    typealias Nd = BlockListShapeTests.N

    static func editorRoot(_ kids: [Nd]) -> Nd {
        Nd(ref: "root", role: "AXTextArea", subrole: "AXApplicationGroup", classes: ["ProseMirror"], editable: true) { kids }
    }

    static func text(_ name: String) -> Nd { Nd(ref: name, role: "AXStaticText") }

    /// A plain contenteditable (Gmail, x.com, the benchmark page): paragraphs are text, not nested editable areas.
    @Test func plainContenteditableIsNotBlocks() {
        let root = Self.editorRoot([Self.group("p1", [], [Self.text("t1")]), Self.group("p2", [], [Self.text("t2")]),
                                    Self.group("p3", [], [Self.text("t3")])])
        #expect(BlockListShape.locate(root: root) == nil)
        #expect(BlockListShape.locate(root: root, rootTextLength: 500, blockLength: { _ in 10 }) == nil)
    }

    /// LibreOffice: sibling paragraph fields in a plain group, no editor root above them.
    @Test func siblingParagraphFieldsAreNotBlocks() {
        let parent = Self.group("doc", [], [Self.area("a"), Self.area("b"), Self.area("c")])
        let window = Self.group("win", [], [parent])
        guard let (a, up) = Self.chain(of: "a", in: window) else { Issue.record("tree"); return }
        #expect(BlockListShape.locate(focus: a, ancestors: up, same: ==) == nil)
    }

    /// Obsidian: an inline title and a note body that is one rich editor with leaves, in a plain scroller.
    @Test func titleAndBodyEditorAreNotBlocks() {
        let body = Nd(ref: "body", role: "AXTextArea", subrole: "AXApplicationGroup", editable: true) {
            [Self.text("l1"), Self.text("l2")]
        }
        let scroller = Self.group("scroller", [], [Self.area("title"), body])
        guard let (title, tup) = Self.chain(of: "title", in: scroller),
              let (b, bup) = Self.chain(of: "body", in: scroller) else { Issue.record("tree"); return }
        #expect(BlockListShape.locate(focus: title, ancestors: tup, same: ==) == nil)
        #expect(BlockListShape.locate(focus: b, ancestors: bup, same: ==) == nil)
        #expect(BlockListShape.locate(root: body) == nil)
    }

    /// A rich editor with a table whose cells are nested editable areas, among body text that is not: the cells
    /// alone are not the document (they hold a small share of the root's text).
    @Test func tableCellsInABodyAreNotTheDocument() {
        let cells = (1...2).map { r in Self.group("row\(r)", [], [Self.area("c\(r)a"), Self.area("c\(r)b")]) }
        let table = Self.group("table", [], cells)
        let root = Self.editorRoot([Self.group("p1", [], [Self.text("long body")]), table,
                                    Self.group("p2", [], [Self.text("more body")])])
        let cellLength: (Nd) -> Int = { _ in 6 }
        // Body text of 3000 characters around four 6-character cells.
        #expect(BlockListShape.locate(root: root, rootTextLength: 3000, blockLength: cellLength) == nil)
        guard let (cell, up) = Self.chain(of: "c1a", in: root) else { Issue.record("tree"); return }
        #expect(BlockListShape.locate(focus: cell, ancestors: up, same: ==, rootTextLength: 3000,
                                      blockLength: cellLength) == nil)
    }
}
