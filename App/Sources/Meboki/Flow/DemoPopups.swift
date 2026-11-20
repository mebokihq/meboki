#if DEBUG
import AppKit
import MebokiCore

/// DEBUG-only: shows the real card and toast panels with sample content (`--demo-popups`), so their window
/// sizing, glass and shadow can be checked with `screencapture -l` without running a check. `--all` adds the
/// bubble and the island (review). Never takes the keyboard.
@MainActor
enum DemoPopups {
    private static let card = CardPanel()
    private static let toast = ToastPanel()
    private static let bubble = BubblePanel()
    private static let island = IslandPanel()

    static func show() {
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let field = CGRect(x: screen.midX - 300, y: screen.midY + 40, width: 600, height: 160)
        card.show(CardState(category: .spelling, swap: FixSwap(old: "tomorow", new: "tomorrow"),
                            reason: "“tomorrow” is the correct spelling.",
                            dots: [.applied, .skipped, .current, .pending, .pending, .pending],
                            position: 1, pending: 4, footer: "On this Mac · Gemma 4 E4B · 1.4 s",
                            update: UpdateController.shared.popupBadge()),
                  field: field, makeKey: false)
        let toastField = CGRect(x: field.minX, y: screen.minY + 160, width: 600, height: 40)
        toast.show(ToastContent(kind: .success, title: "5 fixes applied · 1 kept", detail: "⌘Z undoes in the app",
                                duration: 600), field: toastField)
        print("card window \(card.windowNumber) \(card.frame)")
        print("toast window \(toast.windowNumber) \(toast.frame)")
        if CommandLine.arguments.contains("--all") {
            let word = CGRect(x: field.maxX + 40, y: field.maxY - 20, width: 44, height: 18)
            bubble.show(CardState(category: .grammar, swap: FixSwap(old: "Their", new: "They're"),
                                  reason: "“Their” shows possession. Here you mean “they are”.",
                                  dots: [], position: 1, pending: 6, footer: "",
                                  update: UpdateController.shared.popupBadge()),
                        word: word, makeKey: false)
            let next = [IslandFix(category: .clarity, swap: FixSwap(old: "the the", new: "the")),
                        IslandFix(category: .spelling, swap: FixSwap(old: "tomorow", new: "tomorrow"))]
            island.showReview(IslandReview(fix: IslandFix(category: .grammar, swap: FixSwap(old: "Their", new: "They're")),
                                           reason: "Grammar · “Their” shows possession. Here you mean “they are”.",
                                           upcoming: next, position: 1, pending: 6,
                                           update: UpdateController.shared.popupBadge()),
                              field: field, makeKey: false)
            print("bubble window \(bubble.windowNumber) \(bubble.frame)")
            print("island window \(island.windowNumber) \(island.frame)")
        }
        fflush(stdout)
    }
}
#endif
