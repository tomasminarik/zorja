import SwiftUI
import UIKit

/// Splits a sentence into lines the way the Figma Now frames do:
///
/// 1. Text of more than one word takes at least two lines, and never more than it needs at
///    the available width.
/// 2. Within that number of lines the longest line is as short as it can be (balanced lines).
///    Where another split is within 3 % of that, the earlier lines take more words
///    ("Checking Again / At 22:20.", not "Checking / Again At 22:20.").
/// 3. Two sentences on two lines break between the sentences when that is within 25 % of
///    the balanced split ("…daylight hides it. / Tonight is checked on its own.").
/// 4. A line never breaks inside the underlined part.
/// 5. A phrase with a `subject` (the night it is about, "Tonight", "Thursday") keeps the
///    subject alone on the first line when the rest fits on the second.
///
/// When a word is wider than the space, or the rule finds no lines that fit (very large text
/// sizes), it returns nil and the text wraps on its own.
struct LineBalancer {
    /// Width of one line of text, in points.
    let measure: (String) -> CGFloat

    func lines(_ text: String, emphasis: String? = nil, subject: String? = nil, width: CGFloat) -> [String]? {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count > 1, width > 0 else { return nil }
        let widths = words.map(measure)
        guard widths.allSatisfy({ $0 <= width }) else { return nil }

        if let subject, text.hasPrefix(subject + " ") {
            let rest = String(text.dropFirst(subject.count + 1))
            if measure(subject) <= width, measure(rest) <= width { return [subject, rest] }
        }

        let allowed = allowedBreaks(words: words, text: text, emphasis: emphasis)
        let count = max(2, greedyLineCount(words: words, width: width))
        guard let lines = balanced(words: words, lineCount: count, allowed: allowed, width: width) else { return nil }
        if count == 2, let sentences = sentenceSplit(words: words, allowed: allowed, width: width,
                                                     balancedWidth: lines.map(measure).max() ?? width) {
            return sentences
        }
        return lines
    }

    /// How much longer than the balanced longest line a break between sentences may make it.
    static let sentenceTolerance: CGFloat = 0.25

    /// The two-line split between sentences closest to balanced, if one is close enough.
    private func sentenceSplit(words: [String], allowed: [Bool], width: CGFloat, balancedWidth: CGFloat) -> [String]? {
        let limit = min(width, balancedWidth * (1 + Self.sentenceTolerance))
        var best: (lines: [String], width: CGFloat)?
        for index in 1..<words.count where allowed[index] {
            guard let last = words[index - 1].last, ".!?".contains(last) else { continue }
            let lines = [words[..<index].joined(separator: " "), words[index...].joined(separator: " ")]
            let longest = lines.map(measure).max() ?? .infinity
            if longest <= limit, longest < (best?.width ?? .infinity) { best = (lines, longest) }
        }
        return best?.lines
    }

    /// Lines a plain left-to-right fill needs.
    private func greedyLineCount(words: [String], width: CGFloat) -> Int {
        var count = 1
        var line = words[0]
        for word in words.dropFirst() {
            let candidate = line + " " + word
            if measure(candidate) <= width {
                line = candidate
            } else {
                count += 1
                line = word
            }
        }
        return count
    }

    /// `allowed[i]` is true when a line may start at word `i`.
    private func allowedBreaks(words: [String], text: String, emphasis: String?) -> [Bool] {
        var allowed = Array(repeating: true, count: words.count)
        guard let emphasis, let range = text.range(of: emphasis, options: .backwards) else { return allowed }
        var offset = 0
        for (index, word) in words.enumerated() {
            let start = text.index(text.startIndex, offsetBy: offset)
            // A break before this word falls on the space just before it.
            if index > 0 {
                let space = text.index(before: start)
                if range.contains(space) { allowed[index] = false }
            }
            offset += word.count + 1
        }
        return allowed
    }

    /// The split into `lineCount` lines whose longest line is shortest.
    private func balanced(words: [String], lineCount: Int, allowed: [Bool], width: CGFloat) -> [String]? {
        let n = words.count
        guard lineCount <= n else { return nil }
        func line(_ from: Int, _ to: Int) -> String { words[from..<to].joined(separator: " ") }
        var lineWidth: [[CGFloat]] = Array(repeating: Array(repeating: .infinity, count: n + 1), count: n + 1)
        for i in 0..<n { for j in (i + 1)...n { lineWidth[i][j] = measure(line(i, j)) } }

        // cost[l][j]: the longest line when words 0..<j are set in l lines.
        var cost = Array(repeating: Array(repeating: CGFloat.infinity, count: n + 1), count: lineCount + 1)
        var from = Array(repeating: Array(repeating: -1, count: n + 1), count: lineCount + 1)
        for j in 1...n { cost[1][j] = lineWidth[0][j] }
        if lineCount > 1 {
            for l in 2...lineCount {
                for j in l...n {
                    for i in (l - 1)..<j where allowed[i] {
                        let candidate = max(cost[l - 1][i], lineWidth[i][j])
                        if candidate < cost[l][j] {
                            cost[l][j] = candidate
                            from[l][j] = i
                        }
                    }
                }
            }
        }
        guard cost[lineCount][n] <= width else { return nil }

        if let filled = fill(words: words, lineCount: lineCount, allowed: allowed,
                             limit: min(width, cost[lineCount][n] * (1 + Self.tieTolerance)), lineWidth: lineWidth) {
            return filled
        }

        var lines: [String] = []
        var end = n
        for l in stride(from: lineCount, to: 1, by: -1) {
            let start = from[l][end]
            lines.insert(line(start, end), at: 0)
            end = start
        }
        lines.insert(line(0, end), at: 0)
        return lines
    }

    /// How much longer than the balanced longest line a line may be, so earlier lines can
    /// take more words.
    static let tieTolerance: CGFloat = 0.03

    /// Fills each line as far as `limit` allows, breaking only where allowed. Nil unless this
    /// gives exactly `lineCount` lines.
    private func fill(words: [String], lineCount: Int, allowed: [Bool], limit: CGFloat, lineWidth: [[CGFloat]]) -> [String]? {
        let n = words.count
        var lines: [String] = []
        var start = 0
        while start < n {
            var end = start + 1
            while end < n, lineWidth[start][end + 1] <= limit { end += 1 }
            while end < n, !allowed[end] { end -= 1 }
            guard end > start, lineWidth[start][end] <= limit else { return nil }
            lines.append(words[start..<end].joined(separator: " "))
            start = end
        }
        return lines.count == lineCount ? lines : nil
    }
}

extension LineBalancer {
    /// Measures lines in a Zorja text style with UIKit, as SwiftUI sets them.
    static func measuring(_ style: ZorjaTextStyle, dynamicTypeSize: DynamicTypeSize = .large, size: CGFloat? = nil, scale: CGFloat = 1) -> LineBalancer {
        let metrics = style.metrics(for: dynamicTypeSize, size: size, scale: scale)
        let font = style.uiFont(metrics)
        return LineBalancer { string in
            ceil(NSAttributedString(string: string, attributes: [.font: font, .kern: metrics.tracking]).size().width)
        }
    }
}

/// Text in a Zorja text style, set on balanced lines (see `LineBalancer`), with the
/// phrase's underlined part. Used for the headline, lead and bottom line on Now.
struct BalancedText: View {
    let text: String
    var emphasis: String?
    var subject: String?
    let style: ZorjaTextStyle
    /// Replaces the style's font size, keeping its line height.
    var size: CGFloat?
    /// Centred on Now; Tonight sets its headline from the left.
    var alignment: TextAlignment = .center

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var width: CGFloat = 0

    /// Room kept free at the end of each line.
    nonisolated static let slack: CGFloat = 1

    init(_ phrase: Phrase, style: ZorjaTextStyle, size: CGFloat? = nil, alignment: TextAlignment = .center) {
        text = phrase.text
        emphasis = phrase.emphasis
        subject = phrase.subject
        self.style = style
        self.size = size
        self.alignment = alignment
    }

    init(_ text: String, style: ZorjaTextStyle) {
        self.text = text
        self.style = style
    }

    var body: some View {
        let scale = fitScale
        Text(attributed(scale: scale))
            .textStyle(style, size: size, scale: scale)
            .foregroundStyle(.textPrimary)
            .multilineTextAlignment(alignment)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : alignment == .trailing ? .trailing : .center)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
    }

    /// Below 1 only when the longest word is wider than the line, which happens to display text
    /// at the accessibility text sizes ("Connection." at Display/XL). Shrinking the text then
    /// keeps every word whole instead of breaking it across lines.
    private var fitScale: CGFloat {
        let room = width - Self.slack
        guard room > 0 else { return 1 }
        let balancer = LineBalancer.measuring(style, dynamicTypeSize: dynamicTypeSize, size: size)
        let longest = text.split(separator: " ").map { balancer.measure(String($0)) }.max() ?? 0
        // 2 % spare: widths are rounded up when measured.
        return longest > room ? room / longest * 0.98 : 1
    }

    private func lines(scale: CGFloat) -> [String]? {
        let balancer = LineBalancer.measuring(style, dynamicTypeSize: dynamicTypeSize, size: size, scale: scale)
        // Widths are rounded up when measured; 1 pt more keeps a measured line from wrapping
        // again on screen.
        return balancer.lines(text, emphasis: emphasis, subject: subject, width: width - Self.slack)
    }

    private func attributed(scale: CGFloat) -> AttributedString {
        var result = AttributedString(lines(scale: scale)?.joined(separator: "\n") ?? text)
        if let emphasis, let range = result.range(of: emphasis, options: .backwards) {
            result[range].underlineStyle = .single
        }
        return result
    }
}
