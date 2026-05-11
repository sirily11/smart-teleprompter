//
//  PresentView.swift
//  smart-teleprompter
//

import SwiftUI

struct PresentView: View {
    let script: Script
    @Environment(\.dismiss) private var dismiss
    @State private var model: TeleprompterViewModel
    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var pinchBaseFontSize: Double?

    init(script: Script) {
        self.script = script
        _model = State(initialValue: TeleprompterViewModel(script: script))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                TeleprompterTextView(model: model)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { toggleControls() }
                    .gesture(magnification)

                if showControls {
                    bottomControls
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                if case let .unavailable(reason) = model.recognizerStatus {
                    statusBanner(reason)
                }
            }
            .navigationTitle("")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .statusBarHidden(true)
            .persistentSystemOverlays(.hidden)
            .toolbar(showControls ? .visible : .hidden, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    Text(statusText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        model.toggleSync()
                        scheduleHide()
                    } label: {
                        Label(model.isRunning ? "Stop following" : "Follow my voice",
                              systemImage: model.isRunning ? "mic.fill" : "mic.slash")
                    }
                    .tint(model.isRunning ? .green : nil)
                }
            }
        }
        .onAppear {
            model.onEnterPresent()
            scheduleHide()
        }
        .onDisappear {
            hideTask?.cancel()
            model.onExitPresent()
        }
    }

    // MARK: - Bottom controls (Liquid Glass)

    private var bottomControls: some View {
        VStack {
            Spacer()
            GlassEffectContainer(spacing: 14) {
                HStack(spacing: 14) {
                    glassButton("textformat.size.smaller", label: "Smaller text") {
                        model.decreaseFont(); scheduleHide()
                    }
                    glassButton("textformat.size.larger", label: "Larger text") {
                        model.increaseFont(); scheduleHide()
                    }
                    glassButton("arrow.up.to.line", label: "Back to top") {
                        model.resetToTop(); scheduleHide()
                    }
                    glassToggleButton("rectangle.righthalf.inset.filled.arrow.right",
                                      label: "Mirror left–right",
                                      isOn: model.mirrorHorizontal) {
                        model.mirrorHorizontal.toggle(); scheduleHide()
                    }
                    glassToggleButton("rectangle.bottomhalf.inset.filled",
                                      label: "Mirror top–bottom",
                                      isOn: model.mirrorVertical) {
                        model.mirrorVertical.toggle(); scheduleHide()
                    }
                }
            }
            .padding(.bottom, 28)
        }
    }

    private func glassButton(_ systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.title2)
                .frame(width: 44, height: 40)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private func glassToggleButton(_ systemName: String, label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        let button = Button(action: action) {
            Image(systemName: systemName)
                .font(.title2)
                .frame(width: 44, height: 40)
        }
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])

        if isOn {
            button.buttonStyle(.glassProminent).tint(.yellow)
        } else {
            button.buttonStyle(.glass)
        }
    }

    private func statusBanner(_ reason: String) -> some View {
        VStack {
            Spacer()
            Text(reason)
                .font(.footnote)
                .padding(14)
                .glassEffect(.regular.tint(.red), in: .rect(cornerRadius: 14))
                .padding(.bottom, 110)
        }
        .allowsHitTesting(false)
    }

    private var languageName: String {
        Locale.current.localizedString(forIdentifier: model.recognitionLocale.identifier)
            ?? model.recognitionLocale.identifier
    }

    private var statusText: String {
        switch model.recognizerStatus {
        case .idle: return model.isRunning ? "Listening (\(languageName))…" : "Tap the mic to follow your voice · \(languageName)"
        case .authorizing: return "Requesting permission…"
        case .listening: return "Listening (\(languageName))…"
        case .unavailable: return "Speech unavailable"
        }
    }

    // MARK: - Gestures & chrome

    private var magnification: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard let base = pinchBaseFontSize else { pinchBaseFontSize = model.fontSize; return }
                model.setFont(base * value.magnification)
            }
            .onEnded { _ in pinchBaseFontSize = nil }
    }

    private func toggleControls() {
        withAnimation { showControls.toggle() }
        if showControls { scheduleHide() }
    }

    private func scheduleHide() {
        if !showControls { withAnimation { showControls = true } }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation { showControls = false }
        }
    }
}
