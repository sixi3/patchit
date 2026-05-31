import UIKit

// MARK: - Summary truncation
// Collapsed summary uses a word-boundary prefix that fits exactly two lines at the
// measured width, so expanding to the full string does not reflow the first lines.

enum SummaryTruncation {
    private static let fontSize: CGFloat = 15
    private static let font: UIFont = UIFont(name: "FamiljenGrotesk-Regular", size: fontSize)
        ?? .systemFont(ofSize: fontSize)

    /// Prefix of `text` that fits in two lines (word-trimmed) plus "…", or `text` if it already fits.
    static func twoLineWordPrefix(_ text: String, width: CGFloat) -> String {
        guard width > 0, !text.isEmpty else { return text }

        let maxHeight = twoLineHeight(width: width)
        if measuredHeight(text, width: width) <= maxHeight + 0.5 {
            return text
        }

        let ellipsis = "…"
        var low = 0
        var high = text.count
        var best = 0

        while low <= high {
            let mid = (low + high) / 2
            let candidate = String(text.prefix(upTo: safeIndex(text, offset: mid)))
            let probe = candidate + ellipsis
            if measuredHeight(probe, width: width) <= maxHeight {
                best = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        var slice = String(text.prefix(upTo: safeIndex(text, offset: best)))
        if let lastBreak = slice.lastIndex(where: { $0.isWhitespace || $0.isNewline }) {
            slice = String(slice[..<lastBreak])
        }
        slice = slice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !slice.isEmpty else { return ellipsis }
        return slice + ellipsis
    }

    static func isTruncated(_ text: String, width: CGFloat) -> Bool {
        twoLineWordPrefix(text, width: width) != text
    }

    private static func safeIndex(_ text: String, offset: Int) -> String.Index {
        text.index(text.startIndex, offsetBy: min(offset, text.count), limitedBy: text.endIndex)
            ?? text.endIndex
    }

    private static func twoLineHeight(width: CGFloat) -> CGFloat {
        let label = UILabel()
        label.font = font
        label.numberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        label.text = "Measure\nTwo lines"
        label.preferredMaxLayoutWidth = width
        return ceil(
            label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        )
    }

    private static func measuredHeight(_ text: String, width: CGFloat) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraph,
        ]
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs,
            context: nil
        )
        return ceil(rect.height)
    }
}
