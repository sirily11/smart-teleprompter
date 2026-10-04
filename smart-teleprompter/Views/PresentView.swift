//
//  PresentView.swift
//  smart-teleprompter
//

import SwiftUI

struct PresentView: View {
    let script: Script
    @Environment(\.dismiss) private var dismiss
    @Environment(SonyCameraController.self) private var camera
    @State private var model: TeleprompterViewModel
    @State private var showControls = true
    @State private var feed = UVCCameraFeed()
    @State private var pinchBaseFontSize: Double?
    @State private var showingCameraPairing = false
    @State private var confirmingCloseWhileRecording = false
    @State private var cameraToast: String?
    @State private var toastTask: Task<Void, Never>?

    init(script: Script) {
        self.script = script
        _model = State(initialValue: TeleprompterViewModel(script: script))
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ZStack {
                    Color.black.ignoresSafeArea()
                    if geo.size.width < 640 {
                        VStack(spacing: 0) {
                            if showControls {
                                compactPanel(width: geo.size.width)
                                    .transition(.move(edge: .top).combined(with: .opacity))
                            }
                            teleprompter
                        }
                    } else {
                        HStack(spacing: 0) {
                            if showControls {
                                sideColumn
                                    .frame(width: min(380, max(300, geo.size.width * 0.3)))
                                    .transition(.move(edge: .leading).combined(with: .opacity))
                            }
                            teleprompter
                        }
                    }

                    if case let .unavailable(reason) = model.recognizerStatus {
                        statusBanner(reason)
                    }

                    if camera.isRecording && !showControls {
                        recordingIndicator
                    }

                    if let cameraToast {
                        cameraToastView(cameraToast)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
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
                    Button("Done", systemImage: "xmark") {
                        if camera.isRecording { confirmingCloseWhileRecording = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingCameraPairing = true
                    } label: {
                        Label(camera.isReady ? "Camera connected" : "Connect camera",
                              systemImage: camera.isReady ? "camera.fill" : "camera")
                    }
                    .tint(camera.isReady ? .green : nil)
                }
                ToolbarItem(placement: .principal) {
                    Text(statusText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        model.toggleSync()
                    } label: {
                        Label(model.isRunning ? "Stop following" : "Follow my voice",
                              systemImage: model.isRunning ? "mic.fill" : "mic.slash")
                    }
                    .tint(model.isRunning ? .green : nil)
                }
            }
        }
        .sheet(isPresented: $showingCameraPairing) {
            NavigationStack { CameraPairingView() }
        }
        .confirmationDialog("Camera is still recording", isPresented: $confirmingCloseWhileRecording,
                            titleVisibility: .visible) {
            Button("Stop Recording and Close", role: .destructive) {
                camera.toggleRecording()
                dismiss()
            }
            Button("Keep Recording and Close") { dismiss() }
        }
        .sensoryFeedback(trigger: camera.isRecording) { _, recording in recording ? .start : .stop }
        .sensoryFeedback(.selection, trigger: showControls)
        .sensoryFeedback(.selection, trigger: [model.mirrorHorizontal, model.mirrorVertical,
                                               model.flipCameraHorizontal, model.flipCameraVertical])
        .onChange(of: camera.isReady) { _, ready in
            showCameraToast(ready ? String(localized: "Camera connected") : String(localized: "Camera disconnected"))
        }
        .task { await feed.start() }
        .onAppear { model.onEnterPresent() }
        .onDisappear {
            toastTask?.cancel()
            feed.stop()
            model.onExitPresent()
        }
    }

    private var teleprompter: some View {
        TeleprompterTextView(model: model)
            .ignoresSafeArea(edges: [.vertical, .trailing])
            .contentShape(Rectangle())
            .onTapGesture { toggleControls() }
            .gesture(magnification)
    }

    // MARK: - Left column: camera feed + controls

    private var sideColumn: some View {
        ScrollView {
            VStack(spacing: 16) {
                cameraWindow
                cameraFlipButtons
                recordControl
                teleprompterButtons
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
        .background(Color(white: 0.07))
    }

    /// Narrow screens (iPhone portrait) put the column's contents in a strip above the script.
    private func compactPanel(width: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 10) {
                cameraWindow
                cameraFlipButtons
            }
            .frame(width: width * 0.5)
            VStack(spacing: 10) {
                recordControl
                teleprompterButtons
            }
        }
        .padding(12)
        .background(Color(white: 0.07))
    }

    /// Picture-in-picture window showing the Sony camera's USB (UVC) feed.
    private var cameraWindow: some View {
        ZStack {
            Color.black
            if feed.isRunning {
                CameraPreviewView(session: feed.session,
                                  flipHorizontal: model.flipCameraHorizontal,
                                  flipVertical: model.flipCameraVertical)
            } else {
                feedPlaceholder
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(camera.isRecording ? Color.red : Color.white.opacity(0.15),
                              lineWidth: camera.isRecording ? 3 : 1)
        }
        .overlay(alignment: .topLeading) {
            if camera.isRecording {
                recordingBadge.padding(8)
            }
        }
        .animation(.default, value: camera.isRecording)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(feedAccessibilityLabel)
    }

    @ViewBuilder
    private var feedPlaceholder: some View {
        VStack(spacing: 8) {
            switch feed.state {
            case .idle, .authorizing, .running:
                ProgressView()
            case .unauthorized:
                placeholderText(Text("Allow camera access in Settings to see your camera here."),
                                systemImage: "video.slash")
            case .noCamera:
                placeholderText(Text("Connect your Sony camera over USB and turn on USB Streaming."),
                                systemImage: "cable.connector")
            case let .failed(message):
                placeholderText(Text(message), systemImage: "exclamationmark.triangle")
            }
        }
        .padding(12)
    }

    private func placeholderText(_ text: Text, systemImage: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage).font(.title2)
            text.font(.caption).multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
    }

    private var feedAccessibilityLabel: String {
        switch feed.state {
        case let .running(name): String(localized: "Live feed from \(name)")
        default: String(localized: "Camera feed unavailable")
        }
    }

    /// Start and stop recording from the same button; offers pairing until the remote is connected.
    @ViewBuilder
    private var recordControl: some View {
        if camera.isReady {
            Button {
                camera.toggleRecording()
            } label: {
                Label(camera.isRecording ? "Stop Recording" : "Record",
                      systemImage: camera.isRecording ? "stop.fill" : "record.circle")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .tint(.red)
            .accessibilityLabel(camera.isRecording ? "Stop camera recording" : "Start camera recording")
        } else {
            Button {
                showingCameraPairing = true
            } label: {
                Label(camera.state == .connecting ? "Connecting to Camera…" : "Connect Camera to Record",
                      systemImage: "camera")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        }
    }

    /// Flip the camera picture independently of the script, e.g. to undo a rig's mirroring.
    private var cameraFlipButtons: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                glassToggleButton("arrow.left.and.right.righttriangle.left.righttriangle.right",
                                  label: "Flip camera left–right",
                                  isOn: model.flipCameraHorizontal) {
                    model.flipCameraHorizontal.toggle()
                }
                glassToggleButton("arrow.up.and.down.righttriangle.up.righttriangle.down",
                                  label: "Flip camera top–bottom",
                                  isOn: model.flipCameraVertical) {
                    model.flipCameraVertical.toggle()
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var teleprompterButtons: some View {
        GlassEffectContainer(spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 8)], spacing: 8) {
                glassButton("textformat.size.smaller", label: "Smaller text") { model.decreaseFont() }
                glassButton("textformat.size.larger", label: "Larger text") { model.increaseFont() }
                glassButton("arrow.up.to.line", label: "Back to top") { model.resetToTop() }
                glassToggleButton("rectangle.righthalf.inset.filled.arrow.right",
                                  label: "Mirror left–right",
                                  isOn: model.mirrorHorizontal) {
                    model.mirrorHorizontal.toggle()
                }
                glassToggleButton("rectangle.bottomhalf.inset.filled",
                                  label: "Mirror top–bottom",
                                  isOn: model.mirrorVertical) {
                    model.mirrorVertical.toggle()
                }
            }
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

    // MARK: - Recording status

    private var recordingBadge: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Label {
                Text(elapsedText(at: context.date)).monospacedDigit()
            } icon: {
                Image(systemName: "circle.fill").foregroundStyle(.red)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Camera recording")
    }

    /// Shown over the script while the column is hidden, so recording is never invisible.
    private var recordingIndicator: some View {
        VStack {
            HStack {
                Spacer()
                recordingBadge
            }
            Spacer()
        }
        .padding(.top, 12)
        .padding(.horizontal, 16)
        .allowsHitTesting(false)
    }

    private func elapsedText(at date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(camera.recordingStartedAt ?? date)))
        return String(format: "REC %02d:%02d", seconds / 60, seconds % 60)
    }

    private func cameraToastView(_ message: String) -> some View {
        VStack {
            Label(message, systemImage: "camera")
                .font(.footnote.weight(.semibold))
                .padding(14)
                .glassEffect(.regular, in: .rect(cornerRadius: 14))
                .padding(.top, 60)
            Spacer()
        }
        .allowsHitTesting(false)
    }

    private func showCameraToast(_ message: String) {
        toastTask?.cancel()
        withAnimation { cameraToast = message }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation { cameraToast = nil }
        }
    }

    private func statusBanner(_ reason: String) -> some View {
        VStack {
            Spacer()
            Text(reason)
                .font(.footnote)
                .padding(14)
                .glassEffect(.regular.tint(.red), in: .rect(cornerRadius: 14))
                .padding(.bottom, 24)
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
    }
}
