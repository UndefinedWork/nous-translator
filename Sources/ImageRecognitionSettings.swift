import SwiftUI

/// A Section for the existing Models form, with an independent saved image configuration.
struct ImageRecognitionSettings: View {
    @State private var configuration = ImageRecognitionConfiguration.load()
    @State private var key = ""
    @State private var status = ""

    var body: some View {
        Section {
            Picker("Recognize images with", selection: $configuration.provider) {
                Text("Apple Vision · On This Mac").tag(ModelProvider.local)
                Text("OpenAI").tag(ModelProvider.openai)
                Text("Custom API").tag(ModelProvider.custom)
            }
            if configuration.provider == .local {
                Picker("Text recognition", selection: $configuration.fastOCR) {
                    Text("Accurate").tag(false)
                    Text("Fast").tag(true)
                }
                if configuration.fastOCR {
                    Text("Fast recognition may support fewer languages and miss small or complex text.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                if configuration.provider == .custom {
                    TextField("Image API base URL", text: $configuration.baseURL,
                              prompt: Text("https://example.com/v1"))
                } else {
                    LabeledContent("Image API base URL", value: configuration.profile.baseURL)
                }
                TextField("Image model ID", text: $configuration.model,
                          prompt: Text("Enter a model that accepts images"))
                SecureField("API key", text: $key, prompt: Text("Leave blank to reuse a saved key for this address"))
                Text("If this address already has a saved key, leave the field blank to reuse it. The key is shared by features using the same provider and address.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Choose your image model explicitly. Translation and conversation model IDs are not copied here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if configuration.provider != .local {
                    Button("Remove Saved Key") {
                        do {
                            try APIKeyStore.delete(configuration.profile.account)
                            key = ""; status = "Saved key removed for this provider and address."
                        } catch { status = error.localizedDescription }
                    }
                }
                Spacer()
                Button("Save Image Recognition") { save() }
            }
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        } header: { Text("Image Recognition") } footer: {
            if configuration.provider == .local {
                Text("Apple Vision reads image text on this Mac without an API key or model download. The first recognition can take longer while macOS prepares its model. Send only an image to extract its text, or add a question to continue with your conversation model.")
            } else {
                Text("Online recognition sends a resized image to this provider and may incur API charges. The first request to a new host asks for confirmation in the same way as online translation. Send an image by itself to extract its text; add a question to continue with your conversation model. PDF and text attachments are read on this Mac. Images are never sent to another provider as an automatic fallback.")
            }
        }
        .onAppear { configuration = .load() }
        .onChange(of: configuration.provider) { _, selected in
            configuration = .load(provider: selected)
            key = ""; status = ""
        }
        .onChange(of: configuration.baseURL) { _, _ in key = ""; status = "" }
    }

    private func save() {
        do {
            try configuration.validate()
            if configuration.provider != .local, !key.isEmpty {
                let entered = key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !entered.isEmpty else { throw ModelError.message("Enter a valid API key, or leave the field empty to reuse the saved key.") }
                try APIKeyStore.save(entered, account: configuration.profile.account)
                key = ""
            }
            try configuration.save()
            status = configuration.provider == .local
                ? "Saved. Images will be read on this Mac."
                : "Saved. New image requests will use this provider and image model."
        } catch { status = error.localizedDescription }
    }
}
