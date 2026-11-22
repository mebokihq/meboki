import Foundation

/// Which text fields are the blocks of one document in a block editor (Notion): every block is its own editable
/// text area, nested in wrappers, all inside one page-wide `contenteditable` root. Siblings-only documents
/// (LibreOffice, `ParagraphFieldShape`) don't have this shape: their paragraphs are childless siblings with no
/// root around them.
///
/// The decision is made on an abstract accessibility tree (`Node`), so the rule is tested without an app:
/// - the focused element is an editable text area (a block's text) that isn't inside a code block (or the root itself:
///   `locate(root:)`);
/// - walking up from it (at most `maxUp` levels) to the editable root, an ancestor with subrole `AXApplicationGroup`
///   (Chromium's `contenteditable` host), the highest ancestor below the root that has at least two children
///   each holding an editable text area is the block list (the highest, so a nested toggle's own list isn't taken
///   for the page's);
/// - the root must exist, above the list. An ordinary web page with several text areas has none, so it doesn't match;
/// - the members are the editable text areas under the list, depth first (document order), at most `maxDepth`
///   levels down and `maxMembers` in all. A text area is a block's text and isn't searched further. Text areas
///   in code blocks are left out (an ancestor with a class token ending in `code-block`: Notion's
///   `notion-code-block`; code is never checked as prose anyway, and its token children are slow to measure).
///   Text areas outside the list (the page title sits beside the page content) are not members.
/// Probed in Notion 2026-11-22.
public enum BlockListShape {
    public static let textAreaRole = "AXTextArea"
    public static let rootSubrole = "AXApplicationGroup"
    public static let codeBlockSuffix = "code-block"
    public static let maxUp = 8
    public static let maxDepth = 10
    public static let maxMembers = 400

    /// One element of the accessibility tree. `children` is read on first use (the app reads the tree lazily).
    public final class Node<Ref> {
        public let ref: Ref
        public let role: String
        public let subrole: String
        /// Read on first use: only the code-block rule needs them, and each read is a call to the app.
        public var classes: [String] {
            if let loadedClasses { return loadedClasses }
            let c = classLoader()
            loadedClasses = c
            return c
        }
        private let classLoader: () -> [String]
        private var loadedClasses: [String]?
        /// Its value can be set (a text area the user can type in).
        public let editable: Bool
        private let load: () -> [Node<Ref>]
        private var loaded: [Node<Ref>]?

        public init(ref: Ref, role: String, subrole: String = "", classes: [String] = [],
                    lazyClasses: (() -> [String])? = nil, editable: Bool = false,
                    children: @escaping () -> [Node<Ref>] = { [] }) {
            self.ref = ref
            self.role = role
            self.subrole = subrole
            self.classLoader = lazyClasses ?? { classes }
            self.editable = editable
            self.load = children
        }

        public var children: [Node<Ref>] {
            if let loaded { return loaded }
            let c = load()
            loaded = c
            return c
        }

        public var isEditableTextArea: Bool { role == BlockListShape.textAreaRole && editable }
        public var isCodeBlock: Bool { classes.contains { $0.hasSuffix(BlockListShape.codeBlockSuffix) } }
    }

    public struct Located<Ref> {
        public var list: Node<Ref>
        /// Index of the list in `ancestors` (0 = the focused element's parent).
        public var listLevel: Int
        public var root: Node<Ref>
        /// The block texts in document order.
        public var members: [Node<Ref>]
        /// Index of the focused element in `members` (nil when the root itself has focus).
        public var focusIndex: Int?
    }

    /// The block list around `focus`. `ancestors` run from its parent upwards (the app reads at most `maxUp`).
    /// `same` tells whether two nodes are the same element.
    public static func locate<Ref>(focus: Node<Ref>, ancestors: [Node<Ref>], same: (Ref, Ref) -> Bool,
                                   rootTextLength: Int? = nil,
                                   blockLength: (Node<Ref>) -> Int = { _ in 0 }) -> Located<Ref>? {
        guard focus.isEditableTextArea, focus.subrole != rootSubrole,
              !focus.isCodeBlock, !ancestors.prefix(maxUp).contains(where: { $0.isCodeBlock }) else { return nil }
        let up = Array(ancestors.prefix(maxUp))
        // The root is an editable text area with the application-group subrole (Chromium's `contenteditable` host): a
        // plain group, fieldset or form around two text areas is not an editor.
        guard let rootLevel = up.firstIndex(where: { $0.subrole == rootSubrole }), up[rootLevel].isEditableTextArea,
              let level = up[..<rootLevel].lastIndex(where: { isList($0) }) else { return nil }
        let list = up[level]
        let members = blocks(under: list)
        guard !members.isEmpty, let at = members.firstIndex(where: { same($0.ref, focus.ref) }),
              coversRoot(members, rootTextLength: rootTextLength, blockLength: blockLength) else { return nil }
        return Located(list: list, listLevel: level, root: up[rootLevel], members: members, focusIndex: at)
    }

    /// The block list when the editable root itself has focus (a click moves focus through the root for a moment, and
    /// the root has it while blocks are selected): the first element below the root, breadth first, that is a list.
    /// Nil unless `root` has the root's subrole and holds such a list.
    public static func locate<Ref>(root: Node<Ref>, rootTextLength: Int? = nil,
                                   blockLength: (Node<Ref>) -> Int = { _ in 0 }) -> Located<Ref>? {
        guard root.isEditableTextArea, root.subrole == rootSubrole, !root.isCodeBlock else { return nil }
        var budget = Budget(maxVisited)
        var queue = root.children
        var depth = 1
        while !queue.isEmpty, depth <= maxDepth {
            guard budget.spend(queue.count) else { return nil }
            if let list = queue.first(where: { isList($0, budget: &budget) }) {
                let members = blocks(under: list)
                guard !members.isEmpty else { return nil }
                // The list must hold the editor's text: another rich editor's first group of two cells (a table row,
                // a caption) would make the document only those.
                guard coversRoot(members, rootTextLength: rootTextLength, blockLength: blockLength) else { return nil }
                return Located(list: list, listLevel: -1, root: root, members: members, focusIndex: nil)
            }
            queue = queue.filter { $0.role != textAreaRole }.flatMap(\.children)
            depth += 1
        }
        return nil
    }

    /// The members' text (joined by newlines) makes up enough of the editor root's text. True when the root's length
    /// isn't known.
    static func coversRoot<Ref>(_ members: [Node<Ref>], rootTextLength: Int?,
                                blockLength: (Node<Ref>) -> Int) -> Bool {
        guard let total = rootTextLength, total > 0 else { return true }
        let covered = members.reduce(0) { $0 + blockLength($1) } + max(0, members.count - 1)
        return Double(covered) >= Double(total) * minRootCoverage
    }

    /// The most nodes one search for a list may visit: a rich editor that isn't a block list answers "no" fast.
    public static let maxVisited = 250
    /// With the root focused, the blocks' text (joined by newlines) must make up at least this share of the root's.
    public static let minRootCoverage = 0.8

    struct Budget {
        var left: Int
        init(_ n: Int) { left = n }
        /// False once the budget is gone.
        mutating func spend(_ n: Int = 1) -> Bool {
            left -= n
            return left >= 0
        }
    }

    /// At least two children, each holding an editable text area.
    public static func isList<Ref>(_ node: Node<Ref>) -> Bool {
        var budget = Budget(Int.max)
        return isList(node, budget: &budget)
    }

    static func isList<Ref>(_ node: Node<Ref>, budget: inout Budget) -> Bool {
        var n = 0
        for child in node.children where holdsEditableTextArea(child, depth: 0, budget: &budget) {
            n += 1
            if n >= 2 { return true }
        }
        return false
    }

    private static func holdsEditableTextArea<Ref>(_ node: Node<Ref>, depth: Int, budget: inout Budget) -> Bool {
        guard budget.spend() else { return false }
        if node.isEditableTextArea { return true }
        guard depth < maxDepth else { return false }
        for child in node.children where holdsEditableTextArea(child, depth: depth + 1, budget: &budget) { return true }
        return false
    }

    /// The editable text areas under `list`, depth first, code blocks left out.
    public static func blocks<Ref>(under list: Node<Ref>) -> [Node<Ref>] {
        var out: [Node<Ref>] = []
        func walk(_ node: Node<Ref>, depth: Int, inCode: Bool) {
            for child in node.children {
                if out.count >= maxMembers { return }
                let code = inCode || child.isCodeBlock
                if child.role == textAreaRole {
                    if child.editable, !code { out.append(child) }
                    continue
                }
                if depth + 1 < maxDepth { walk(child, depth: depth + 1, inCode: code) }
            }
        }
        walk(list, depth: 0, inCode: false)
        return out
    }

    /// `node` (a text area) belongs to the list: it has no code block around it, and `chain` (its ancestors from the
    /// parent up) reaches the list within `maxDepth` levels.
    public static func belongs<Ref>(_ node: Node<Ref>, ancestors chain: [Node<Ref>], toList list: Ref,
                                    same: (Ref, Ref) -> Bool) -> Bool {
        guard node.isEditableTextArea, !node.isCodeBlock else { return false }
        for a in chain.prefix(maxDepth + 1) {
            if same(a.ref, list) { return true }
            if a.isCodeBlock { return false }
        }
        return false
    }
}
