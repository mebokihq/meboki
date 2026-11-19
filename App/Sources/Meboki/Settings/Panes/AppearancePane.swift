import MebokiCore
import SwiftUI

/// Settings › Appearance: the color tone picker (`ColorTone`) and a live preview of the anchored bubble.
/// Picking a tone applies it at once to the whole app (`AppSettings.colorTone` sets `DS.tone`); the category
/// chips switch the fix shown in the preview.
struct AppearancePane: View {
    @ObservedObject var settings: AppSettings
    @State private var category: FixCategory = .spelling

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroupHeader("Color tone", first: true)
            SettingsGroup {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(ColorTone.allCases) { tone in
                        ToneCard(tone: tone, category: category, selected: tone == settings.colorTone) {
                            settings.colorTone = tone
                        }
                    }
                }
                .padding(14)
                SettingsDivider()
                CategoryChips(selection: $category)
                    .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
                TonePreview(tone: settings.colorTone, category: category, reasons: settings.explainFixes)
                    .padding(EdgeInsets(top: 0, leading: 14, bottom: 14, trailing: 14))
            }
            SettingsFootnote(symbol: "paintpalette", text: "Changes the accent and the category colors in popups, underlines, the menu-bar popover and Settings.")
        }
    }
}

/// One sample fix per category, for the preview and the swatches.
private struct SampleFix {
    let old, new, reason: String

    static func of(_ c: FixCategory) -> SampleFix {
        switch c {
        case .spelling: SampleFix(old: "recieve", new: "receive", reason: "“i” before “e” here.")
        case .grammar: SampleFix(old: "was", new: "were", reason: "A plural subject takes “were”.")
        case .clarity: SampleFix(old: "in order to", new: "to", reason: "Shorter, same meaning.")
        case .punctuation: SampleFix(old: "However", new: "However,", reason: "A comma after an opening word.")
        case .rewrite: SampleFix(old: "a lot of", new: "many", reason: "Plainer for countable nouns.")
        }
    }
}

/// Tone card: a strip of the tone's seven colors, a small suggestion button in the picked category's color,
/// the name and one line. Selected: 2.5 pt brand ring and a check.
private struct ToneCard: View {
    let tone: ColorTone
    let category: FixCategory
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    /// Brand gradient stops, then the five category colors.
    private var swatches: [Color] {
        let p = DS.palette(tone)
        return [p.brand2, p.brand] + FixCategory.allCases.map { $0.color(in: p) }
    }

    var body: some View {
        let p = DS.palette(tone)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                VStack(spacing: 7) {
                    HStack(spacing: 3) {
                        ForEach(swatches.indices, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(swatches[i]).frame(height: 14)
                        }
                    }
                    HStack {
                        Text(SampleFix.of(category).new)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(DS.onAccent)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(category.color(in: p)))
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: DS.Radius.suggestion, style: .continuous).fill(DS.field))
                .brightness(hovering ? 0.02 : 0)
                .overlay {
                    let shape = RoundedRectangle(cornerRadius: DS.Radius.suggestion, style: .continuous)
                    if selected {
                        shape.inset(by: -1.25).strokeBorder(DS.brand, lineWidth: 2.5)
                    } else {
                        shape.strokeBorder(DS.separator, lineWidth: 0.5)
                    }
                }
                HStack(spacing: 6) {
                    if selected {
                        Circle().fill(DS.brandGradient)
                            .overlay(Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy))
                                .foregroundStyle(DS.onAccent))
                            .frame(width: 16, height: 16)
                    }
                    Text(tone.title).font(DS.Font.bodySemibold).foregroundStyle(DS.text)
                }
                Text(tone.detail)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tone.title)
        .accessibilityHint(tone.detail)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// "CATEGORY" and a capsule segmented control with a colored dot per category.
private struct CategoryChips: View {
    @Binding var selection: FixCategory

    var body: some View {
        HStack(spacing: 8) {
            Text("CATEGORY")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(DS.textSecondary)
                .fixedSize()
            HStack(spacing: 2) {
                ForEach(FixCategory.allCases, id: \.self) { c in
                    let on = c == selection
                    Button { selection = c } label: {
                        HStack(spacing: 6) {
                            Circle().fill(c.color).frame(width: 7, height: 7)
                            Text(c.title)
                                .font(.system(size: 12, weight: on ? .semibold : .medium))
                                .foregroundStyle(on ? DS.text : DS.textSecondary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                        .padding(.vertical, 5)
                        .padding(.horizontal, 8)
                        .background(Capsule().fill(on ? DS.controlOn : Color.clear)
                            .shadow(color: on ? DS.thumbShadow : .clear, radius: 1.5, y: 1))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(c.title)
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(3)
            .background(Capsule().fill(DS.control))
            Spacer(minLength: 0)
        }
    }
}

/// The preview: the wallpaper, the tone's name, a note with the underlined word, the real `AnchoredBubble`
/// pointing at it, and the five category buttons.
private struct TonePreview: View {
    let tone: ColorTone
    let category: FixCategory
    let reasons: Bool

    var body: some View {
        let fix = SampleFix.of(category)
        let color = category.color
        VStack(alignment: .leading, spacing: 12) {
            Text(tone.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DS.text)
                .padding(.vertical, 4)
                .padding(.horizontal, 10)
                .background(Capsule().fill(DS.glassStrong))
            VStack(alignment: .leading, spacing: 0) {
                note(fix: fix, color: color)
                AnchoredBubble(state: CardState(category: category, swap: FixSwap(old: fix.old, new: fix.new),
                                                reason: reasons ? "\(category.title): \(fix.reason)" : nil,
                                                dots: [], position: 1, pending: 3, footer: ""))
                    .padding(.leading, 80)
                    .padding(.top, 12)
            }
            HStack(spacing: 6) {
                ForEach(FixCategory.allCases, id: \.self) { c in
                    Text(c.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(DS.onAccent)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(c.color))
                        .shadow(color: c.color.opacity(0.45), radius: 5, y: 4)
                }
            }
            .padding(.top, 6)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Wallpaper())
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.suggestion, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.suggestion, style: .continuous)
            .strokeBorder(DS.separator, lineWidth: 0.5))
        .environment(\.dsGlassBlur, false)
        .allowsHitTesting(false)
        // The bubble's views read the tone when they're drawn; a new identity redraws them.
        .id("\(tone.rawValue)-\(category.rawValue)")
        .accessibilityElement()
        .accessibilityLabel("Preview of the anchored bubble in the \(tone.title) tone")
    }

    /// The note: "Thanks, we [word] the files today and will reply soon." with the word underlined.
    private func note(fix: SampleFix, color: Color) -> some View {
        HStack(spacing: 0) {
            Text("Thanks, we ")
            Text(fix.old)
                .padding(.horizontal, 2)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(color.opacity(0.16)))
                .overlay(alignment: .bottom) {
                    WaveLine().stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .frame(height: 4).offset(y: 3)
                }
            Text(" the files today.")
        }
        .font(.system(size: 14))
        .foregroundStyle(DS.text)
        .lineLimit(1)
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 14, trailing: 14))
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.field.opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 8)
    }
}
