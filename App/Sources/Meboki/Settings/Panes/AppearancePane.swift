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
            SettingsGroupHeader("Popups and underlines", first: true)
            SettingsGroup {
                RangeRow(title: "Opacity", low: "Transparent", high: "Solid",
                         accessibility: "Popup opacity", value: $settings.popupOpacity,
                         standard: DS.popupOpacityDefault)
                SettingsDivider()
                RangeRow(title: "Wave", low: "Flat", high: "Curvy",
                         accessibility: "Underline wave", value: $settings.underlineCurve,
                         standard: DS.underlineCurveDefault) {
                    WaveLine(curve: settings.underlineCurve)
                        .stroke(FixCategory.spelling.color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .frame(width: 44, height: 4)
                        .accessibilityHidden(true)
                }
            }
            SettingsFootnote(symbol: "square.on.square.dashed", text: "Opacity: card, bubble, island and their messages. Wave: the mistake underlines.")

            SettingsGroupHeader("Color tone")
            SettingsGroup {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(ColorTone.allCases) { tone in
                        ToneCard(tone: tone, category: category, selected: tone == settings.colorTone) {
                            settings.colorTone = tone
                        }
                    }
                }
                .padding(10)
                SettingsDivider()
                CategoryChips(selection: $category)
                    .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
                TonePreview(tone: settings.colorTone, category: category, reasons: settings.explainFixes,
                            curve: settings.underlineCurve)
                    .environment(\.dsPopupOpacity, settings.popupOpacity)
                    .padding(EdgeInsets(top: 0, leading: 10, bottom: 10, trailing: 10))
            }
            SettingsFootnote(symbol: "paintpalette", text: "Changes the accent and the category colors in popups, underlines, the menu-bar popover and Settings.")
        }
    }
}

/// A 0 … 100 % setting: title with "Default" or "Custom" under it, an optional sample, low label, slider,
/// high label, the percentage, and Reset (disabled at `standard`). The subtitle is always there and one short
/// word, so the row keeps its height while dragging and doesn't wrap at the minimum window width. The labels
/// have fixed widths so the sliders of stacked rows line up.
private struct RangeRow<Sample: View>: View {
    let title, low, high, accessibility: String
    @Binding var value: Double
    let standard: Double
    @ViewBuilder var sample: Sample

    private var isDefault: Bool { abs(value - standard) < 0.001 }

    var body: some View {
        SettingsRow(title, subtitle: isDefault ? "Default" : "Custom") {
            HStack(spacing: 10) {
                sample
                Text(low).font(DS.Font.caption).foregroundStyle(DS.textSecondary)
                    .frame(width: 70, alignment: .trailing)
                // No `step:`: it draws a tick mark per step. Snap to whole percents instead.
                Slider(value: Binding(get: { value }, set: { value = ($0 * 100).rounded() / 100 }), in: 0...1)
                    .tint(DS.brand)
                    .frame(minWidth: 110, maxWidth: 170)
                    .accessibilityLabel(accessibility)
                    .accessibilityValue("\(Int((value * 100).rounded())) percent")
                Text(high).font(DS.Font.caption).foregroundStyle(DS.textSecondary)
                    .frame(width: 36, alignment: .leading)
                Text("\(Int((value * 100).rounded()))%")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(DS.text)
                    .frame(width: 36, alignment: .trailing)
                Button("Reset") { value = standard }
                    .buttonStyle(.ds(.secondary, small: true))
                    .fixedSize()
                    // The DS button style dims a disabled button itself; no extra opacity here.
                    .disabled(isDefault)
            }
        }
    }
}

extension RangeRow where Sample == EmptyView {
    init(title: String, low: String, high: String, accessibility: String,
         value: Binding<Double>, standard: Double) {
        self.init(title: title, low: low, high: high, accessibility: accessibility,
                  value: value, standard: standard) { EmptyView() }
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
            VStack(alignment: .leading, spacing: 6) {
                VStack(spacing: 6) {
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
                        // 6, not 8: the row must fit the 480 pt group at the minimum window width.
                        .padding(.horizontal, 6)
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
    let curve: Double

    var body: some View {
        let fix = SampleFix.of(category)
        let color = category.color
        VStack(alignment: .leading, spacing: 8) {
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
                    .padding(.top, 10)
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
            .padding(.top, 2)
        }
        .padding(14)
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
                    WaveLine(curve: curve).stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .frame(height: 4).offset(y: 3)
                }
            Text(" the files today.")
        }
        .font(.system(size: 14))
        .foregroundStyle(DS.text)
        .lineLimit(1)
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 12, trailing: 12))
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.field.opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 8)
    }
}
