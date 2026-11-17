import SwiftUI

/// The reference wallpaper from the HTML (`--wall`), light and dark.
struct Wallpaper: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let base: [UInt32] = dark ? [0x1A1222, 0x120F1C, 0x0B1A20] : [0xFFE6D6, 0xFFD3E2, 0xD3F1F6]
        let blobColors: [UInt32] = dark ? [0x7A2E5C, 0x3B2A8C, 0x0F6170, 0x8A3A1E] : [0xFFB287, 0xFF77A9, 0x5ED0E6, 0xB79CFF]
        let centers = [UnitPoint(x: 0.12, y: 0.18), UnitPoint(x: 0.88, y: 0.10), UnitPoint(x: 0.80, y: 0.95), UnitPoint(x: 0.15, y: 0.98)]
        let blobs = Array(zip(blobColors, centers))
        GeometryReader { geo in
            let r = max(geo.size.width, geo.size.height) * 0.55
            ZStack {
                LinearGradient(colors: base.map { Color(nsColor: .hex($0)) }, startPoint: .topLeading, endPoint: .bottomTrailing)
                ForEach(blobs.indices, id: \.self) { i in
                    RadialGradient(colors: [Color(nsColor: .hex(blobs[i].0)), Color(nsColor: .hex(blobs[i].0, 0))],
                                   center: blobs[i].1, startRadius: 0, endRadius: r)
                }
            }
        }
    }
}
