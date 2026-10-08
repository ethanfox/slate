import SwiftUI

struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            PageBody {
                VStack(alignment: .leading, spacing: 24) {
                    content()
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .scrollContentBackground(.hidden)
    }
}

struct SettingsGroup<Content: View>: View {
    var title: String
    var mark: BrandMark?
    @ViewBuilder var content: () -> Content

    init(_ title: String, mark: BrandMark? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.mark = mark
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let mark {
                    BrandMarkImage(mark: mark, size: 16)
                }
                Text(title)
                    .font(CraftFont.section)
            }
            VStack(spacing: 0) {
                content()
            }
            .background(CraftColor.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

struct SettingsRow<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 12) {
            content()
        }
        .font(CraftFont.body)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
