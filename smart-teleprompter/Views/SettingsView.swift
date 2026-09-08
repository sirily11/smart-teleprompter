import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    private var legalBaseURL: URL? {
        #if targetEnvironment(simulator)
        return URL(string: "http://localhost:3100")
        #else
        guard let value = Bundle.main.object(forInfoDictionaryKey: "LegalBaseURL") as? String,
              let url = URL(string: value), url.scheme == "https", url.host != nil else { return nil }
        return url
        #endif
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
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
