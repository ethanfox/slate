import SwiftUI

enum BrandMark: String, CaseIterable, Identifiable {
    case github = "GitHub"
    case gitlab = "GitLab"
    case chatgpt = "ChatGPT"
    case cursor = "Cursor"

    var id: String { rawValue }
}

struct BrandMarkImage: View {
    var mark: BrandMark
    var size: CGFloat = 16

    var body: some View {
        Image(mark.rawValue)
            .resizable()
            .interpolation(.high)
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

extension CodeAttachmentKind {
    var mark: BrandMark? {
        switch self {
        case .folder: nil
        case .github: .github
        case .gitlab: .gitlab
        }
    }
}
