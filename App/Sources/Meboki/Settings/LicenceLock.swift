import MebokiCore
import SwiftUI

// Free-mode lock marks (PLAN.md §6 "App-side licensing" › "Free mode afterwards", design_code.md §8).
// The stored values stay visible, dimmed; a click on a locked control changes nothing and shows a small
// popover with a button to the Licence pane. In the trial and with a licence nothing is drawn.

/// Whether gated settings are locked now, and how to reach the Licence pane. Set once at the root of the
/// Settings window from `AppSettings.entitlement`.
struct LicenceGate {
    var locked = false
    var open: () -> Void = {}
}

private struct LicenceGateKey: EnvironmentKey {
    static let defaultValue = LicenceGate()
}

extension EnvironmentValues {
    var licenceGate: LicenceGate {
        get { self[LicenceGateKey.self] }
        set { self[LicenceGateKey.self] = newValue }
    }
}

/// `lock.fill` with the caption "Needs a licence" (capsule on `control`).
struct LockBadge: View {
    var caption = true

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "lock.fill").font(.system(size: 9, weight: .semibold))
            if caption { Text("Needs a licence").font(DS.Font.pill) }
        }
        .foregroundStyle(DS.textSecondary)
        .padding(.vertical, 3)
        .padding(.horizontal, caption ? 9 : 6)
        .background(Capsule().fill(DS.control))
        .fixedSize()
        .accessibilityHidden(true)
    }
}

/// The popover a click on a locked control shows.
struct NeedsLicencePopover: View {
    let open: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "lock.fill").font(.system(size: 11, weight: .semibold))
                Text("Needs a licence").font(DS.Font.bodySemibold)
            }
            .foregroundStyle(DS.text)
            Text("Your choice is saved and comes back with a licence.")
                .font(DS.Font.caption)
                .foregroundStyle(DS.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("See Licence") { dismiss(); open() }
                .buttonStyle(.ds(.primary, small: true))
        }
        .padding(14)
        .frame(width: 220, alignment: .leading)
    }
}

/// A control that can be locked. In free mode: dimmed, not clickable, with a lock badge; a click shows the
/// popover.
private struct LicenceLockedModifier: ViewModifier {
    let feature: Feature
    let caption: Bool
    @Environment(\.licenceGate) private var gate
    @State private var showing = false

    func body(content: Content) -> some View {
        if gate.locked {
            HStack(spacing: 8) {
                LockBadge(caption: caption)
                content
                    .opacity(0.5)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onTapGesture { showing = true }
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                NeedsLicencePopover(open: gate.open) { showing = false }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(feature.title), needs a licence")
            .accessibilityAddTraits(.isButton)
        } else {
            content
        }
    }
}

extension View {
    /// Locks the control in free mode (`feature` names it for accessibility). `caption: false` shows the lock
    /// icon alone, for tight rows.
    func licenceLocked(_ feature: Feature, caption: Bool = true) -> some View {
        modifier(LicenceLockedModifier(feature: feature, caption: caption))
    }
}

/// The slim banner at the top of General, Writing and Apps in free mode.
struct FreeModeBanner: View {
    @Environment(\.licenceGate) private var gate

    var body: some View {
        if gate.locked {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.textSecondary)
                Text("Free mode: some settings need a licence.")
                    .font(DS.Font.link)
                    .foregroundStyle(DS.text)
                Spacer(minLength: 0)
                Button("Unlock") { gate.open() }.buttonStyle(.dsLinkStrong)
            }
            .padding(.vertical, 6)
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .background(RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous).fill(DS.brandSoft))
            .padding(.bottom, 14)
            .accessibilityElement(children: .contain)
        }
    }
}
