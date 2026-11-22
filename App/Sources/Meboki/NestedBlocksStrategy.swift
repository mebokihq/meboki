import AppKit
import ApplicationServices
import MebokiCore

/// Block editors (Notion): every block's text is its own editable text area, nested in wrappers, all inside one
/// page-wide `contenteditable` root (`BlockListShape`, Core, holds the rule and its tests). The focused block's
/// siblings are not the other blocks, and a block has children (its static text), so `SiblingParagraphsStrategy`
/// doesn't match: this one reads the tree's shape instead.
///
/// The blocks are joined into one document (`CompositeSurface`): the check sees every block in the tree, which is
/// the page near the viewport (the editor keeps ~10 blocks above and ~8 below the screen), not only the block
/// with the caret. Text areas are measured through their text leaves (`AX.bounds`), as the focused block always was;
/// the ones scrolled out of view have frames squeezed to the scroller's edge and get no underline.
/// Probed 2026-11-22.
struct NestedBlocksStrategy: SurfaceStrategy {
    var name: String { "nested blocks" }

    typealias BNode = BlockListShape.Node<AXUIElement>

    func surface(for focused: AXUIElement, pid: pid_t) -> TextSurface? {
        // Cheap exits first: this runs for every text area that gets focus, in every app.
        guard AX.string(focused, kAXRoleAttribute) == BlockListShape.textAreaRole, AX.isEditableTextArea(focused)
        else { return nil }
        let found: BlockListShape.Located<AXUIElement>
        if AX.string(focused, kAXSubroleAttribute) == BlockListShape.rootSubrole {
            // The editor's root has focus (focus passes through it on a click, and it keeps it while blocks are
            // selected): the same document, with no caret block.
            // Asked for every contenteditable root in every app, so a "no" is remembered for a few seconds.
            if Self.knownNotBlocks(focused) { return nil }
            let rootLength = (AX.text(focused) as NSString?)?.length
            guard let f = BlockListShape.locate(root: Self.node(focused), rootTextLength: rootLength,
                                                blockLength: Self.textLength) else {
                Self.rememberNotBlocks(focused)
                return nil
            }
            found = f
        } else {
            var ancestors: [BNode] = []
            var cur = focused
            while ancestors.count < BlockListShape.maxUp, let parent = AX.element(cur, kAXParentAttribute) {
                ancestors.append(Self.node(parent))
                cur = parent
            }
            // The root is the last ancestor with the root subrole; its text must be (nearly) the blocks' text.
            let root = ancestors.first { $0.subrole == BlockListShape.rootSubrole }
            let rootLength = root.flatMap { (AX.text($0.ref) as NSString?)?.length }
            guard let f = BlockListShape.locate(focus: Self.node(focused), ancestors: ancestors, same: CFEqual,
                                                rootTextLength: rootLength, blockLength: Self.textLength) else {
                return nil
            }
            found = f
        }
        let list = found.list.ref
        var traits = CompositeSurface.Traits()
        traits.clip = found.root.ref
        traits.extraValueElements = [found.root.ref]
        traits.focusHolders = [found.root.ref]
        traits.oneEditingHost = true
        traits.clampsOffscreen = true
        traits.settlesLate = true
        // A click into another block reports a system-dialog window as focused for a moment, then the block (0.65 s measured, longer while Meboki's card is open).
        traits.focusGrace = 3
        traits.recreatesOffscreenParagraphs = true
        return CompositeSurface(container: list, anchor: focused, pid: pid,
                                members: { Self.members(of: list) },
                                isMember: { el in Self.belongs(el, to: list) },
                                traits: traits)
    }

    private static func textLength(_ n: BNode) -> Int { (AX.text(n.ref) as NSString?)?.length ?? 0 }

    /// Roots that were searched for a block list and held none, and when.
    private static var misses: [(root: AXUIElement, at: Date)] = []

    private static func knownNotBlocks(_ root: AXUIElement) -> Bool {
        misses.removeAll { Date().timeIntervalSince($0.at) > 5 }
        return misses.contains { CFEqual($0.root, root) }
    }

    private static func rememberNotBlocks(_ root: AXUIElement) {
        misses.append((root, Date()))
        if misses.count > 8 { misses.removeFirst() }
    }

    /// An element as the shape rule sees it. Attributes are read now, children when asked.
    static func node(_ el: AXUIElement) -> BNode {
        let role = AX.string(el, kAXRoleAttribute) ?? ""
        return BNode(ref: el, role: role, subrole: AX.string(el, kAXSubroleAttribute) ?? "",
                     lazyClasses: { AX.domClasses(el) },
                     editable: role == BlockListShape.textAreaRole && AX.isEditableTextArea(el)) {
            (AX.copy(el, kAXChildrenAttribute) as? [AXUIElement] ?? []).map(Self.node)
        }
    }

    /// The block texts under the list now, in document order; nil when the list holds none any more.
    static func members(of list: AXUIElement) -> [AXUIElement]? {
        let blocks = BlockListShape.blocks(under: node(list))
        return blocks.isEmpty ? nil : blocks.map(\.ref)
    }

    /// `el` is a block text of the list (also a block just made, not listed yet): an editable text area outside
    /// any code block, with the list within a few levels above it.
    static func belongs(_ el: AXUIElement, to list: AXUIElement) -> Bool {
        guard AX.string(el, kAXRoleAttribute) == BlockListShape.textAreaRole else { return false }
        var chain: [BNode] = []
        var cur = el
        while chain.count <= BlockListShape.maxDepth, let parent = AX.element(cur, kAXParentAttribute) {
            chain.append(node(parent))
            if CFEqual(parent, list) { break }
            cur = parent
        }
        return BlockListShape.belongs(node(el), ancestors: chain, toList: list, same: CFEqual)
    }
}
