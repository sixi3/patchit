import SwiftUI

private struct SummaryWidthKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - ExpandableSummaryText
// Tap to expand blueprint summary; collapsed copy is a measured two-line prefix so
// line breaks stay stable when expanding (no orphaned word jumping to line 3).
struct ExpandableSummaryText: View {
    let text: String
    @Binding var isExpanded: Bool

    @State private var containerWidth: CGFloat = 0

    private var collapsedText: String {
        guard containerWidth > 0 else { return text }
        return SummaryTruncation.twoLineWordPrefix(text, width: containerWidth)
    }

    private var displayText: String {
        isExpanded ? text : collapsedText
    }

    private var canExpand: Bool {
        containerWidth > 0 && SummaryTruncation.isTruncated(text, width: containerWidth)
    }

    var body: some View {
        Button {
            guard canExpand || isExpanded else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        } label: {
            Text(displayText)
                .font(LoupeFont.body)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.leading)
                .lineLimit(isExpanded || containerWidth > 0 ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, LoupeSpace.xs)
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: SummaryWidthKey.self, value: proxy.size.width)
            }
            .frame(height: 0)
        }
        .onPreferenceChange(SummaryWidthKey.self) { containerWidth = $0 }
        .buttonStyle(.plain)
        .accessibilityLabel("Blueprint summary")
        .accessibilityHint(
            isExpanded
                ? "Tap to collapse"
                : (canExpand ? "Tap to show full summary" : "")
        )
    }
}
