import AppKit

/// The correction popup of a review session: the glass card or the anchored bubble, picked from
/// `AppSettings.effectivePopupStyle` each time it opens (design_code.md §5.4, §5.5). Both have the same keys and
/// actions. The bubble needs a word to point at, so without one (the no-bounds fallback) the card is shown,
/// below the field, whatever the style.
@MainActor
final class PopupController {
    var onApplyAll: (() -> Void)? { didSet { forEachKeys { $0.onApplyAll = onApplyAll } } }
    var onApplyOne: (() -> Void)? { didSet { forEachKeys { $0.onApplyOne = onApplyOne } } }
    var onIgnore: (() -> Void)? { didSet { forEachKeys { $0.onIgnore = onIgnore } } }
    var onPrevious: (() -> Void)? { didSet { forEachKeys { $0.onPrevious = onPrevious } } }
    var onNext: (() -> Void)? { didSet { forEachKeys { $0.onNext = onNext } } }
    /// Esc.
    var onClose: (() -> Void)? { didSet { forEachKeys { $0.onClose = onClose } } }
    /// A click on the update badge.
    var onUpdate: (() -> Void)? { didSet { forEachKeys { $0.onUpdate = onUpdate } } }

    private let settings: AppSettings
    private let card = CardPanel()
    private let bubble = BubblePanel()

    init(settings: AppSettings) {
        self.settings = settings
    }

    private func forEachKeys(_ body: (PopupKeys) -> Void) {
        body(card.keys)
        body(bubble.keys)
    }

    var isVisible: Bool { card.isVisible || bubble.isVisible }

    /// Shows `state` under `word`, or below `field` without one. Switching between card and bubble (the style
    /// changed, or the fallback) hides the other first, so it pops in fresh.
    func show(_ state: CardState, field: CGRect?, word: CGRect?) {
        var state = state
        if !settings.explainFixes { state.reason = nil }
        if settings.effectivePopupStyle == .bubble, let word {
            if card.isVisible { card.hide() }
            bubble.show(state, word: word)
        } else {
            if bubble.isVisible { bubble.hide() }
            card.show(state, field: field, word: word)
        }
    }

    func hide() {
        card.hide()
        bubble.hide()
    }
}
