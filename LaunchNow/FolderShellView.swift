import SwiftUI

struct FolderShellView: View {
    let name: String

    private let titlePadding: CGFloat = 16

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Text(name)
                    .font(.title)
                    .foregroundColor(.primary)
                    .padding()
                Spacer()
            }
            .padding(.horizontal, titlePadding)

            Spacer()
        }
        .padding()
    }
}
