//
//  TeleprompterTextView.swift
//  smart-teleprompter
//
//  Renders the script line-by-line, dims already-spoken text, highlights the
//  word currently being spoken, and keeps the active line parked on the
//  "reading line" (~40% down the screen) as speech progresses.
//

import SwiftUI
import os

struct TeleprompterTextView: View {
    @Bindable var model: TeleprompterViewModel

    /// 0…1 — where the start of the active line sits when you begin reading it.
    private let readingAnchorY: CGFloat = 0.4
    @State private var lastScrolledLine = 0

    /// As you read through a (possibly multi-line-wrapping) paragraph, slide its
    /// top upward so the word you're on stays near the reading guide instead of
    /// drifting toward the bottom of the screen.
    private func anchorY(forLine line: Int) -> CGFloat {
        guard model.tokensByLine.indices.contains(line) else { return readingAnchorY }
        let lineTokens = model.tokensByLine[line]
        guard let first = lineTokens.first?.index, let last = lineTokens.last?.index, last > first else {
            return readingAnchorY
        }
        let cur = min(max(model.sync.currentTokenIndex, first), last)
        let progress = CGFloat(cur - first) / CGFloat(last - first)
        return max(0.06, readingAnchorY - progress * (readingAnchorY - 0.06))
    }

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: model.fontSize * 0.45) {
                        Color.clear.frame(height: geo.size.height * readingAnchorY)
                        ForEach(model.lines.indices, id: \.self) { index in
                            TeleprompterLineView(runs: model.lineRuns[index],
                                                 currentTokenIndex: model.sync.currentTokenIndex,
                                                 matchedTokenIndex: model.sync.matchedTokenIndex,
                                                 highlightCurrent: model.isRunning,
                                                 fontSize: model.fontSize)
                                .id(index)
                        }
                        Color.clear.frame(height: geo.size.height * (1 - readingAnchorY))
                    }
                    .padding(.horizontal, max(20, geo.size.width * 0.06))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
                .onChange(of: model.sync.currentTokenIndex) { _, _ in
                    let line = model.sync.currentLineIndex
                    let lineChanged = line != lastScrolledLine
                    lastScrolledLine = line
                    if lineChanged { Log.ui.debug("scroll to line \(line) of \(model.lines.count)") }
                    withAnimation(.easeOut(duration: lineChanged ? 0.4 : 0.25)) {
                        proxy.scrollTo(line, anchor: UnitPoint(x: 0.5, y: anchorY(forLine: line)))
                    }
                }
                .onChange(of: model.fontSize) { _, _ in
                    let line = model.sync.currentLineIndex
                    proxy.scrollTo(line, anchor: UnitPoint(x: 0.5, y: anchorY(forLine: line)))
                }
                .onAppear {
                    let line = model.sync.currentLineIndex
                    lastScrolledLine = line
                    proxy.scrollTo(line, anchor: UnitPoint(x: 0.5, y: anchorY(forLine: line)))
                }
            }
        }
        .background(.black)
        // Mirror for beam-splitter rigs: flip the rendered text, not the controls.
        .scaleEffect(x: model.mirrorHorizontal ? -1 : 1,
                     y: model.mirrorVertical ? -1 : 1)
        .overlay(alignment: .top) { readingGuide }
    }

    private var readingGuide: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(.white.opacity(0.12))
                .frame(height: 2)
                .offset(y: geo.size.height * readingAnchorY)
        }
        .allowsHitTesting(false)
    }
}

/// One rendered line. Each word (or CJK character) is its own `Text` so its
/// colour can cross-fade independently as speech reaches it; a small wrapping
/// layout flows them like a paragraph.
private struct TeleprompterLineView: View {
    let runs: [LineRun]
    let currentTokenIndex: Int
    let matchedTokenIndex: Int
    let highlightCurrent: Bool
    let fontSize: Double

    private static let spokenColor = Color.white.opacity(0.32)

    private func color(for run: LineRun) -> Color {
        if let tokenIndex = run.tokenIndex {
            if tokenIndex <= matchedTokenIndex { return Self.spokenColor }
            if highlightCurrent && tokenIndex == currentTokenIndex { return .yellow }
            return .white
        }
        // Whitespace / bare punctuation: dim once the word before it is spoken.
        return run.precedingTokenIndex >= 0 && run.precedingTokenIndex <= matchedTokenIndex
            ? Self.spokenColor : .white
    }

    var body: some View {
        WrappingTextLayout(lineSpacing: fontSize * 0.2) {
            ForEach(runs) { run in
                Text(run.text)
                    .foregroundStyle(color(for: run))
                    .animation(.easeOut(duration: 0.3), value: color(for: run))
            }
        }
        .font(.system(size: fontSize, weight: .semibold, design: .rounded))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Minimal left-to-right wrapping layout — flows its subviews like words in a
/// paragraph, breaking to a new row when the next one won't fit the width.
private struct WrappingTextLayout: Layout {
    var lineSpacing: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0, rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0, totalHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0 && rowWidth + size.width > maxWidth {
                totalWidth = max(totalWidth, rowWidth)
                totalHeight += rowHeight + lineSpacing
                rowWidth = 0; rowHeight = 0
            }
            rowWidth += size.width
            rowHeight = max(rowHeight, size.height)
        }
        totalWidth = max(totalWidth, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: min(totalWidth, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && (x - bounds.minX) + size.width > bounds.width {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width
            rowHeight = max(rowHeight, size.height)
        }
    }
}
