import SwiftUI

/// Insert directly into the General settings Form; it owns no window or nested Form.
struct TranslationLanguageSettings: View {
    @State private var configuration = TranslationLanguageConfiguration.load()
    @State private var customPair = false
    private let presets: [(String, TranslationLanguage, TranslationLanguage)] = [
        ("Chinese ↔ English", .chinese, .english),
        ("Chinese ↔ Japanese", .chinese, .japanese),
        ("Chinese ↔ Korean", .chinese, .korean),
        ("English ↔ Japanese", .english, .japanese),
        ("English ↔ Spanish", .english, .spanish),
        ("English ↔ French", .english, .french),
        ("English ↔ German", .english, .german)
    ]
    private var preset: Binding<Int> {
        Binding(get: { customPair ? -1 : presets.firstIndex { $0.1 == configuration.languageA && $0.2 == configuration.languageB } ?? -1 },
                set: { index in
            customPair = index == -1
            guard presets.indices.contains(index) else { return }
            configuration = .init(languageA: presets[index].1, languageB: presets[index].2, mode: configuration.mode)
        })
    }
    var body: some View {
        Section {
            Picker("Language pair", selection: preset) {
                ForEach(presets.indices, id: \.self) { index in Text(presets[index].0).tag(index) }
                Text("Custom").tag(-1)
            }
            Picker("Primary language (A)", selection: Binding(get: { configuration.languageA }, set: { customPair = true; configuration.setLanguageA($0) })) {
                ForEach(TranslationLanguage.allCases) { Text($0.name).tag($0) }
            }
            Picker("Second language (B)", selection: Binding(get: { configuration.languageB }, set: { customPair = true; configuration.setLanguageB($0) })) {
                ForEach(TranslationLanguage.allCases.filter { $0 != configuration.languageA }) { Text($0.name).tag($0) }
            }
            Picker("Direction", selection: $configuration.mode) {
                Text("Automatic (A ↔ B)").tag(TranslationDirectionMode.automatic)
                Text("\(configuration.languageA.shortName) → \(configuration.languageB.shortName)").tag(TranslationDirectionMode.aToB)
                Text("\(configuration.languageB.shortName) → \(configuration.languageA.shortName)").tag(TranslationDirectionMode.bToA)
            }
            HStack { Spacer(); Button("Swap Languages") { customPair = true; configuration.swap() } }
        } header: { Text("Translation Languages") } footer: {
            VStack(alignment: .leading, spacing: 5) {
                Text(configuration.mode == .automatic
                     ? "Detect the selection and translate between A and B. Other or unrecognized languages translate into \(configuration.languageA.name) (A)."
                     : "Always translate into \(configuration.mode == .aToB ? configuration.languageB.name : configuration.languageA.name), regardless of the detected source language.")
                Text("Applies to new selection and clipboard translations. Short or mixed text may be detected incorrectly. Language support and quality depend on the model selected in Models.")
            }
        }
        .onChange(of: configuration) { _, value in value.save() }
    }
}
