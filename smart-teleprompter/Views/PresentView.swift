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
    @State private var cameraToast: CameraToast?
    @State private var showingPhotosAccessAlert = false
    @State private var toastTask: Task<Void, Never>?
    @AppStorage("presentSidePanelWidth") private var sidePanelWidth: Double = 340
    @State private var resizeStartWidth: Double?
    @AppStorage("recordingDestination") private var recordingDestination: RecordingDestination = .camera

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
                                    .frame(width: clampedSidePanelWidth(sidePanelWidth, in: geo.size.width))
                                    .transition(.move(edge: .leading).combined(with: .opacity))
                                sidePanelResizeHandle(containerWidth: geo.size.width)
                                    .transition(.opacity)
                            }
                            teleprompter
                        }
                    }

                    if case let .unavailable(reason) = model.recognizerStatus {
                        statusBanner(reason)
                    }

                    if isRecording && !showControls {
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
                        if isRecording { confirmingCloseWhileRecording = true } else { dismiss() }
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
        .confirmationDialog(recordsOnDevice ? "Still recording" : "Camera is still recording",
                            isPresented: $confirmingCloseWhileRecording, titleVisibility: .visible) {
            Button("Stop Recording and Close", role: .destructive) {
                if recordsOnDevice { feed.stopRecording() } else { camera.toggleRecording() }
                dismiss()
            }
            // A recording on this device needs the presenter's camera feed.
            if !recordsOnDevice {
                Button("Keep Recording and Close") { dismiss() }
            }
        } message: {
            if recordsOnDevice {
                Text("Closing stops the recording and saves it to Photos.")
            }
        }
        .alert("Allow Access to Photos", isPresented: $showingPhotosAccessAlert) {
            #if os(iOS)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            #endif
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Recordings made on this device are saved to Photos. Allow SmartPrompter to add photos in Settings.")
        }
        .sensoryFeedback(trigger: isRecording) { _, recording in recording ? .start : .stop }
        .sensoryFeedback(.selection, trigger: showControls)
        .sensoryFeedback(.impact(weight: .light), trigger: resizeStartWidth == nil)
        .sensoryFeedback(.selection, trigger: [model.mirrorHorizontal, model.mirrorVertical,
                                               model.flipCameraHorizontal, model.flipCameraVertical])
        .onChange(of: camera.isReady) { _, ready in
            showCameraToast(CameraToast(message: ready ? String(localized: "Camera connected")
                                                       : String(localized: "Camera disconnected"),
                                        systemImage: "camera"))
        }
        .onChange(of: feed.lastRecording) { _, result in
            if let result { handleRecordingResult(result.outcome) }
        }
        .sensoryFeedback(trigger: feed.lastRecording) { _, result in
            switch result?.outcome {
            case .savedToPhotos, .savedToFiles: .success
            case .failed, .photosAccessDenied: .error
            case nil: nil
            }
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
            VStack(spacing: 24) {
                cameraWindow
                cameraFlipButtons
                recordingDestinationPicker
                recordControl
                teleprompterButtons
                SpiritLevelView()
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
        .background(Color(white: 0.07))
    }

    private static let sidePanelMinWidth: Double = 240

    private func clampedSidePanelWidth(_ width: Double, in containerWidth: CGFloat) -> Double {
        let maxWidth = max(Self.sidePanelMinWidth, containerWidth * 0.6)
        return min(max(width, Self.sidePanelMinWidth), maxWidth)
    }

    /// Drag to resize the side column; the width is remembered across sessions.
    private func sidePanelResizeHandle(containerWidth: CGFloat) -> some View {
        Capsule()
            .fill(Color.white.opacity(resizeStartWidth == nil ? 0.25 : 0.6))
            .frame(width: 4, height: 44)
            .frame(width: 16)
            .frame(maxHeight: .infinity)
            .background(Color(white: 0.07))
            .contentShape(Rectangle())
            #if os(macOS)
            .pointerStyle(.frameResize(position: .trailing))
            #endif
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = resizeStartWidth ?? clampedSidePanelWidth(sidePanelWidth, in: containerWidth)
                        if resizeStartWidth == nil { resizeStartWidth = start }
                        sidePanelWidth = clampedSidePanelWidth(start + value.translation.width, in: containerWidth)
                    }
                    .onEnded { _ in resizeStartWidth = nil }
            )
            .accessibilityElement()
            .accessibilityLabel("Resize side panel")
            .accessibilityValue("\(Int(clampedSidePanelWidth(sidePanelWidth, in: containerWidth))) points")
            .accessibilityAdjustableAction { direction in
                let step: Double = direction == .increment ? 40 : -40
                sidePanelWidth = clampedSidePanelWidth(sidePanelWidth + step, in: containerWidth)
            }
    }

    /// Narrow screens (iPhone portrait) put the column's contents in a strip above the script.
    private func compactPanel(width: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 14) {
                cameraWindow
                cameraFlipButtons
            }
            .frame(width: width * 0.5)
            VStack(spacing: 14) {
                recordingDestinationPicker
                recordControl
                teleprompterButtons
                SpiritLevelView()
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
                // Mirroring the script top–bottom means the screen is seen upside down
                // through the rig, so the camera picture turns with it.
                CameraPreviewView(session: feed.session,
                                  flipHorizontal: model.flipCameraHorizontal,
                                  flipVertical: model.flipCameraVertical != model.mirrorVertical)
            } else {
                feedPlaceholder
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(isRecording ? Color.red : Color.white.opacity(0.15),
                              lineWidth: isRecording ? 3 : 1)
        }
        .overlay(alignment: .topLeading) {
            if isRecording {
                recordingBadge.padding(8)
            }
        }
        .animation(.default, value: isRecording)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(feedAccessibilityLabel)
    }

    @ViewBuilder
    private var feedPlaceholder: some View {
        VStack(spacing: 8) {
            switch feed.state {
            case .idle, .authorizing, .running:
                ProgressView()
            case let .starting(name):
                ProgressView()
                Text("Starting \(name)…").font(.caption).foregroundStyle(.secondary)
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

    // MARK: - Recording

    /// Sony cameras can't record to their card while USB Streaming is on, so the
    /// USB feed can be recorded on this device instead.
    private var recordsOnDevice: Bool {
        recordingDestination == .device && (feed.isRunning || feed.isRecording)
    }

    private var isRecording: Bool {
        recordsOnDevice ? feed.isRecording : camera.isRecording
    }

    private var recordingStartedAt: Date? {
        recordsOnDevice ? feed.recordingStartedAt : camera.recordingStartedAt
    }

    private var deviceName: String {
        #if os(iOS)
        UIDevice.current.localizedModel
        #else
        String(localized: "Mac")
        #endif
    }

    /// Only offered while the USB feed is live, since that's what a device recording captures.
    @ViewBuilder
    private var recordingDestinationPicker: some View {
        #if !os(visionOS)
        if feed.isRunning || feed.isRecording {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Record on", selection: $recordingDestination) {
                    Label("Camera", systemImage: "camera").tag(RecordingDestination.camera)
                    Label(deviceName, systemImage: "ipad.landscape").tag(RecordingDestination.device)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(isRecording || feed.isSavingRecording)
                .sensoryFeedback(.selection, trigger: recordingDestination)

                Text(recordingDestination == .camera
                     ? "Sony cameras usually can't record to their card while USB Streaming is on."
                     : "Records the USB feed and saves it to Photos.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        #endif
    }

    @ViewBuilder
    private var recordControl: some View {
        if recordsOnDevice {
            deviceRecordControl
        } else {
            cameraRecordControl
        }
    }

    private var deviceRecordControl: some View {
        Button {
            if feed.isRecording {
                feed.stopRecording()
            } else {
                Task { await feed.startRecording() }
            }
        } label: {
            Group {
                if feed.isSavingRecording {
                    Label("Saving…", systemImage: "square.and.arrow.down")
                } else {
                    Label(feed.isRecording ? "Stop Recording" : "Record on \(deviceName)",
                          systemImage: feed.isRecording ? "stop.fill" : "record.circle")
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .tint(.red)
        .disabled(!feed.isRecording && !feed.canRecord)
        .accessibilityLabel(feed.isRecording ? "Stop recording on \(deviceName)" : "Start recording on \(deviceName)")
    }

    /// Start and stop recording from the same button; offers pairing until the remote is connected.
    @ViewBuilder
    private var cameraRecordControl: some View {
        if camera.isReady {
            Button {
                camera.toggleRecording()
            } label: {
                Label(camera.isRecording ? "Stop Recording" : "Record",
                      systemImage: camera.isRecording ? "stop.fill" : "record.circle")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.extraLarge)
            .tint(.red)
            .accessibilityLabel(camera.isRecording ? "Stop camera recording" : "Start camera recording")
        } else {
            Button {
                showingCameraPairing = true
            } label: {
                Label(camera.state == .connecting ? "Connecting to Camera…" : "Connect Camera to Record",
                      systemImage: "camera")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.extraLarge)
        }
    }

    private static let controlIconSize: CGFloat = 52
    private static let controlSpacing: CGFloat = 16
    /// Room for the icon plus the glass button's own padding, so cells never overlap.
    private static let controlCellWidth: CGFloat = controlIconSize + 24
    /// Glass shapes closer than this blend together; keep it below the button gap.
    private static let glassMergeDistance: CGFloat = 4

    /// Flip the camera picture independently of the script, e.g. to undo a rig's mirroring.
    private var cameraFlipButtons: some View {
        GlassEffectContainer(spacing: Self.glassMergeDistance) {
            HStack(spacing: Self.controlSpacing) {
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
        GlassEffectContainer(spacing: Self.glassMergeDistance) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.controlCellWidth), spacing: Self.controlSpacing)],
                      spacing: Self.controlSpacing) {
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
                .font(.title)
                .frame(width: Self.controlIconSize, height: Self.controlIconSize)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private func glassToggleButton(_ systemName: String, label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        let button = Button(action: action) {
            Image(systemName: systemName)
                .font(.title)
                .frame(width: Self.controlIconSize, height: Self.controlIconSize)
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
        .accessibilityLabel(recordsOnDevice ? "Recording on \(deviceName)" : "Camera recording")
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
        let seconds = max(0, Int(date.timeIntervalSince(recordingStartedAt ?? date)))
        return String(format: "REC %02d:%02d", seconds / 60, seconds % 60)
    }

    private func cameraToastView(_ toast: CameraToast) -> some View {
        VStack {
            Label(toast.message, systemImage: toast.systemImage)
                .font(.footnote.weight(.semibold))
                .padding(14)
                .glassEffect(.regular, in: .rect(cornerRadius: 14))
                .padding(.top, 60)
            Spacer()
        }
        .allowsHitTesting(false)
    }

    private func handleRecordingResult(_ outcome: UVCCameraFeed.RecordingOutcome) {
        switch outcome {
        case .savedToPhotos:
            showCameraToast(CameraToast(message: String(localized: "Recording saved to Photos"),
                                        systemImage: "checkmark.circle"))
        case .savedToFiles:
            showCameraToast(CameraToast(message: String(localized: "Couldn't add to Photos. Recording kept in the app's Recordings folder."),
                                        systemImage: "folder"))
        case .photosAccessDenied:
            showingPhotosAccessAlert = true
        case let .failed(message):
            showCameraToast(CameraToast(message: String(localized: "Recording failed: \(message)"),
                                        systemImage: "exclamationmark.triangle"))
        }
    }

    private func showCameraToast(_ toast: CameraToast) {
        toastTask?.cancel()
        withAnimation { cameraToast = toast }
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

private struct CameraToast: Equatable {
    let message: String
    let systemImage: String
}

/// Where the record button records: on the Sony camera's card (via the Bluetooth
/// remote) or on this device from the USB feed.
enum RecordingDestination: String {
    case camera
    case device
}
