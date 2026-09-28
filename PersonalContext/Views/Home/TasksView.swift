import SwiftUI

struct TasksView: View {
    var body: some View {
        ScrollView {
            PageBody {
                EmptyLine(text: "Tasks aren’t connected yet.")
                    .padding(.horizontal, 32)
                    .padding(.vertical, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .scrollContentBackground(.hidden)
    }
}
