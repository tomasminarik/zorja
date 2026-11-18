#if DEBUG
import SwiftUI

/// Development check that the bundled fonts and icons load. Not shown in the app.
struct ResourceGallery: View {
    var body: some View {
        ScrollView {
            ResourceSheet()
        }
        .background(.bgBase)
    }
}

/// The gallery content without scrolling, so it can also be rendered to an image.
struct ResourceSheet: View {
    private let rows: [[ZorjaIcon]] = stride(from: 0, to: ZorjaIcon.allCases.count, by: 5).map {
        Array(ZorjaIcon.allCases[$0..<min($0 + 5, ZorjaIcon.allCases.count)])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(OutfitFont.allCases, id: \.self) { font in
                Text("\(font.name): Clear skies from 22:40.")
                    .font(.custom(font.name, size: 20))
            }
            Grid(alignment: .top, horizontalSpacing: 8, verticalSpacing: 20) {
                ForEach(rows, id: \.self) { row in
                    GridRow {
                        ForEach(row, id: \.self) { icon in
                            VStack(spacing: 6) {
                                icon.image
                                    .frame(width: 24, height: 24)
                                Text(icon.rawValue)
                                    .font(.custom(OutfitFont.regular.name, size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 62)
                        }
                    }
                }
            }
        }
        .padding(24)
        .foregroundStyle(.white)
    }
}

#Preview {
    ResourceGallery()
        .onAppear { OutfitFont.register() }
        .preferredColorScheme(.dark)
}
#endif
