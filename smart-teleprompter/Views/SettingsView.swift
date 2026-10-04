import SwiftUI

struct SettingsView: View {
    @Environment(SonyCameraController.self) private var camera
    @State private var showingCameraPairing = false

    private var legalBaseURL: URL? {
        URL(string: "https://teleprompter.rxlab.app")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("App", value: "Smart Teleprompter")
                    LabeledContent("Developer", value: "RxLab")
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                } header: { Text("About") }
                Section {
                    Button {
                        showingCameraPairing = true
                    } label: {
                        LabeledContent {
                            Text(camera.isReady ? "Connected" : camera.pairedCameraID == nil ? "Not paired" : "Not connected")
                        } label: {
                            Label(camera.pairedCameraName ?? String(localized: "Sony Camera"), systemImage: "camera")
                        }
                    }
                } header: { Text("Camera") } footer: {
                    Text("Pair a Sony camera over Bluetooth to start and stop recording from the teleprompter.")
                }
                Section {
                    if let base = legalBaseURL {
                        Link(destination: base.appendingPathComponent("privacy")) {
                            Label("Privacy Policy", systemImage: "hand.raised")
                        }
                        Link(destination: base.appendingPathComponent("tos")) {
                            Label("Terms of Service", systemImage: "doc.text")
                        }
                    } else {
                        Label("Legal pages are not available yet", systemImage: "doc.text")
                            .foregroundStyle(.secondary)
                    }
                } header: { Text("Legal") }
                Section {
                    Text("Voice following uses your microphone and Apple speech recognition. Recognition may use Apple’s servers when on-device processing is unavailable.")
                    #if os(iOS)
                    Link("Open System Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
                    #endif
                } header: { Text("Speech & Privacy") } footer: {
                    Text("Manage microphone and speech recognition permissions in system Settings. Your scripts are stored on this device.")
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showingCameraPairing) {
                NavigationStack { CameraPairingView() }
            }
        }
    }
}
