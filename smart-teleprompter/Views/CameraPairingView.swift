//
//  CameraPairingView.swift
//  smart-teleprompter
//
//  Pair a Sony camera over Bluetooth so the teleprompter can start and stop
//  its recording. Presented as a sheet; callers wrap it in a NavigationStack.
//

import SwiftUI

struct CameraPairingView: View {
    @Environment(SonyCameraController.self) private var camera
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingForget = false

    var body: some View {
        Form {
            if let unavailable = bluetoothUnavailableMessage {
                Section {
                    ContentUnavailableView("Bluetooth Unavailable", systemImage: "antenna.radiowaves.left.and.right.slash",
                                           description: Text(unavailable))
                }
            } else {
                if camera.pairedCameraID != nil { pairedSection }
                nearbySection
                instructionsSection
            }
        }
        .navigationTitle("Camera")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .confirmationDialog("Forget \(camera.pairedCameraName ?? String(localized: "this camera"))?",
                            isPresented: $confirmingForget, titleVisibility: .visible) {
            Button("Forget Camera", role: .destructive) { camera.forgetCamera() }
        } message: {
            Text("The teleprompter will stop connecting to it. You can also remove it from Bluetooth in system Settings.")
        }
        .overlay(alignment: .bottom) { statusOverlay }
        .sensoryFeedback(.success, trigger: camera.isReady) { _, ready in ready }
        .sensoryFeedback(.error, trigger: failureMessage) { _, message in message != nil }
        .onAppear { camera.startScan() }
        .onDisappear { camera.stopScan() }
    }

    // MARK: - Sections

    private var pairedSection: some View {
        Section {
            LabeledContent {
                Text(pairedStatusText).foregroundStyle(camera.isReady ? .green : .secondary)
            } label: {
                Label(camera.pairedCameraName ?? String(localized: "Sony Camera"), systemImage: "camera")
            }
            if !camera.isReady && camera.state != .connecting {
                Button("Reconnect", systemImage: "arrow.clockwise") { camera.reconnectToPairedCamera() }
            }
            Button("Forget Camera", systemImage: "trash", role: .destructive) { confirmingForget = true }
        } header: {
            Text("Paired Camera")
        }
    }

    private var nearbySection: some View {
        Section {
            let nearby = camera.discovered.filter { $0.id != camera.pairedCameraID || !camera.isReady }
            if nearby.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Looking for cameras…").foregroundStyle(.secondary)
                }
            }
            ForEach(nearby) { found in
                Button {
                    camera.connect(to: found)
                } label: {
                    HStack {
                        Label(found.name, systemImage: "camera")
                        Spacer()
                        Image(systemName: "cellularbars", variableValue: signalStrength(found.rssi))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
                .disabled(camera.state == .connecting)
            }
        } header: {
            Text("Nearby Cameras")
        }
    }

    private var instructionsSection: some View {
        Section {
            Label("On the camera, open Menu › Network › Bluetooth and turn on Bluetooth Function.", systemImage: "1.circle")
            Label("Turn on Bluetooth Rmt Ctrl (Bluetooth Remote Control).", systemImage: "2.circle")
            Label("Choose Pairing on the camera, then tap it in Nearby Cameras and accept the pairing request.", systemImage: "3.circle")
        } header: {
            Text("How to Pair")
        } footer: {
            Text("Works with Sony cameras that support Bluetooth remote control, such as Alpha, ZV, and FX models. Put the camera in movie mode to record video.")
        }
    }

    // MARK: - Status overlay

    @ViewBuilder
    private var statusOverlay: some View {
        if camera.state == .connecting {
            statusPill(Text("Connecting… accept the pairing request if asked"), systemImage: "antenna.radiowaves.left.and.right")
        } else if let failureMessage {
            statusPill(Text(failureMessage), systemImage: "exclamationmark.triangle.fill", tint: .red)
        }
    }

    private func statusPill(_ text: Text, systemImage: String, tint: Color? = nil) -> some View {
        Label { text } icon: { Image(systemName: systemImage) }
            .font(.footnote)
            .padding(14)
            .glassEffect(tint.map { .regular.tint($0) } ?? .regular, in: .rect(cornerRadius: 14))
            .padding()
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.default, value: camera.state)
    }

    // MARK: - Helpers

    private var failureMessage: String? {
        if case let .failed(message) = camera.state { return message }
        return nil
    }

    private var bluetoothUnavailableMessage: String? {
        switch camera.state {
        case .bluetoothOff: String(localized: "Turn on Bluetooth to connect to your camera.")
        case .unauthorized: String(localized: "Allow Bluetooth access for SmartPrompter in system Settings.")
        case .unsupported: String(localized: "This device doesn’t support Bluetooth LE.")
        default: nil
        }
    }

    private var pairedStatusText: String {
        switch camera.state {
        case .ready: String(localized: "Connected")
        case .connecting: String(localized: "Connecting…")
        default: String(localized: "Not connected")
        }
    }

    /// Maps RSSI (≈ -90 far … -50 close) to 0…1 for the signal bars.
    private func signalStrength(_ rssi: Int) -> Double {
        min(max(Double(rssi + 90) / 40, 0), 1)
    }
}
