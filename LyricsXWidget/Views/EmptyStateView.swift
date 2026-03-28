import SwiftUI

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.4))
            Text("Not Playing")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
        }
    }
}
