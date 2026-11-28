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
            Picker(L10n.text("Language pair", zh: "常用语言对"), selection: preset) {
                ForEach(presets.indices, id: \.self) { index in Text(presets[index].0).tag(index) }
                Text(L10n.text("Custom", zh: "自定义")).tag(-1)
            }
            Picker(L10n.text("Primary language (A)", zh: "主语言 (A)"), selection: Binding(get: { configuration.languageA }, set: { customPair = true; configuration.setLanguageA($0) })) {
                ForEach(TranslationLanguage.allCases) { Text($0.name).tag($0) }
            }
            Picker(L10n.text("Second language (B)", zh: "第二语言 (B)"), selection: Binding(get: { configuration.languageB }, set: { customPair = true; configuration.setLanguageB($0) })) {
                ForEach(TranslationLanguage.allCases.filter { $0 != configuration.languageA }) { Text($0.name).tag($0) }
            }
            Picker(L10n.text("Direction", zh: "翻译方向"), selection: $configuration.mode) {
                Text(L10n.text("Automatic (A ↔ B)", zh: "自动双向 (A ↔ B)")).tag(TranslationDirectionMode.automatic)
                Text("\(configuration.languageA.shortName) → \(configuration.languageB.shortName)").tag(TranslationDirectionMode.aToB)
                Text("\(configuration.languageB.shortName) → \(configuration.languageA.shortName)").tag(TranslationDirectionMode.bToA)
            }
            HStack { Spacer(); Button(L10n.text("Swap Languages", zh: "互换语言 A / B")) { customPair = true; configuration.swap() } }
        } header: { Text(L10n.text("Translation Languages", zh: "翻译语言")) } footer: {
            VStack(alignment: .leading, spacing: 5) {
                Text(configuration.mode == .automatic
                     ? L10n.text(
                        "Detect the selection and translate between A and B. Other or unrecognized languages translate into \(configuration.languageA.name) (A).",
                        zh: "自动识别选区并在 A 与 B 之间互译；第三语言或无法识别的文本默认译向主语言 \(configuration.languageA.shortName) (A)。"
                     )
                     : L10n.text(
                        "Always translate into \(configuration.mode == .aToB ? configuration.languageB.name : configuration.languageA.name), regardless of the detected source language.",
                        zh: "始终翻译为 \(configuration.mode == .aToB ? configuration.languageB.shortName : configuration.languageA.shortName)，不受源语言识别结果影响。"
                     ))
                Text(L10n.text(
                    "Applies to new selection and clipboard translations. Short or mixed text may be detected incorrectly. Language support and quality depend on the model selected in Models.",
                    zh: "对新的划词与剪贴板翻译生效。短词或混合文本可能识别不准；实际语言能力取决于所选模型。"
                ))
            }
        }
        .onChange(of: configuration) { _, value in value.save() }
    }
}
