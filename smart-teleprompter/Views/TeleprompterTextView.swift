//
//  TeleprompterTextView.swift
//  smart-teleprompter
//
//  Renders the script word-by-word, dims already-spoken text, highlights the
//  word currently being spoken, and keeps that word parked on the "reading
//  line" (~40% down the screen) as speech progresses.
//

import SwiftUI
import os

/// Scroll-anchor identity for the run that renders a given script token. A
/// `\n`-delimited paragraph can wrap over several screens, so we scroll to the
/// word itself rather than to the paragraph — otherwise a long paragraph parks
/// its *top* near the reading line and pushes the word being read off-screen.
private struct TokenAnchor: Hashable { let token: Int }

struct TeleprompterTextView: View {
    @Bindable var model: TeleprompterViewModel

    /// 0…1 — where the word being spoken sits in the viewport.
    private let readingAnchorY: CGFloat = 0.4

    private func scrollToCurrentWord(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(TokenAnchor(token: model.sync.currentTokenIndex),
                       anchor: UnitPoint(x: 0.5, y: readingAnchorY))
    }

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    // Eager VStack (not Lazy): ScrollViewReader can only jump to
                    // a word run that's been realized, and teleprompter scripts
                    // are short enough that laying them all out up front is fine.
                    // Paragraphs sit close together — a hair more than the
                    // in-paragraph line gap, just enough to read as separate
                    // paragraphs without a yawning blank band between them.
                    VStack(alignment: .leading, spacing: model.fontSize * 0.25) {
                        Color.clear.frame(height: geo.size.height * readingAnchorY)
                        ForEach(model.lines.indices, id: \.self) { index in
                            TeleprompterLineView(runs: model.lineRuns[index],
                                                 currentTokenIndex: model.sync.currentTokenIndex,
                                                 matchedTokenIndex: model.sync.matchedTokenIndex,
                                                 highlightCurrent: model.isRunning,
                                                 fontSize: model.fontSize)
                                .contextMenu {
                                    Button("Start from here", systemImage: "arrow.turn.down.right") {
                                        model.startReading(fromLine: index)
                                    }
                                }
                        }
                        Color.clear.frame(height: geo.size.height * (1 - readingAnchorY))
                    }
                    .padding(.horizontal, max(20, geo.size.width * 0.06))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
                // System edge shading spreads across the script when the scroll
                // view is vertically mirrored. Keep the reading surface crisp.
                .scrollEdgeEffectHidden()
                .onChange(of: model.sync.currentTokenIndex) { _, new in
                    Log.ui.debug("scroll to token \(new) (line \(model.sync.currentLineIndex) of \(model.lines.count))")
                    // A gentle spring (rather than a fresh ease curve each word)
                    // retargets without restarting, so a run of word advances
                    // blends into one continuous glide instead of stutter-steps.
                    withAnimation(.smooth(duration: 0.6)) { scrollToCurrentWord(proxy) }
                }
                .onChange(of: model.fontSize) { _, _ in scrollToCurrentWord(proxy) }
                .onAppear { scrollToCurrentWord(proxy) }
            }
        }
        .background(.black)
        // Mirror for beam-splitter rigs: flip the rendered text, not the controls.
        .scaleEffect(x: model.mirrorHorizontal ? -1 : 1,
                     y: model.mirrorVertical ? -1 : 1)
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
                    .modifier(TokenAnchorID(token: run.tokenIndex))
            }
        }
        .font(.system(size: fontSize, weight: .semibold, design: .rounded))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Tags a word run with its `TokenAnchor` so `ScrollViewProxy` can scroll to it;
/// inter-word runs (whitespace, bare punctuation) carry no token, hence no id.
private struct TokenAnchorID: ViewModifier {
    let token: Int?
    func body(content: Content) -> some View {
        if let token { content.id(TokenAnchor(token: token)) } else { content }
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
