import SwiftUI

/// Loading placeholders shaped like the rows they stand in for, with a soft shimmer
/// (still when Reduce Motion is on), instead of a spinner over an empty list.
struct SkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat = 12
    var cornerRadius: CGFloat = 4

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.secondary.opacity(0.18))
            .frame(width: width, height: height)
    }
}

/// Sweeps a highlight across the placeholders it is applied to.
private struct Shimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                if !reduceMotion {
                    GeometryReader { geo in
                        LinearGradient(colors: [.clear, Color.white.opacity(0.35), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 0.6)
                            .offset(x: phase * geo.size.width * 1.6)
                    }
                    .blendMode(.plusLighter)
                    .mask(content)
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

extension View {
    func shimmering() -> some View { modifier(Shimmer()) }
}

/// Stands in for a VersionRow: version name, release date, Install button.
struct VersionRowSkeleton: View {
    let index: Int

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                SkeletonBlock(width: [64, 52, 72, 58][index % 4], height: 16)
                SkeletonBlock(width: 96, height: 10)
            }
            Spacer()
            SkeletonBlock(width: 68, height: 30, cornerRadius: 8)
        }
        .padding(.vertical, 4)
        .shimmering()
        .accessibilityHidden(true)
    }
}

/// Stands in for a Modrinth search result: icon, title, two lines of description, stats.
struct ModrinthHitSkeleton: View {
    let index: Int

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SkeletonBlock(width: 44, height: 44, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 6) {
                SkeletonBlock(width: [140, 110, 170, 125][index % 4], height: 15)
                SkeletonBlock(height: 10)
                SkeletonBlock(width: [180, 150, 200, 120][index % 4], height: 10)
                SkeletonBlock(width: 110, height: 9)
            }
        }
        .padding(.vertical, 2)
        .shimmering()
        .accessibilityHidden(true)
    }
}
