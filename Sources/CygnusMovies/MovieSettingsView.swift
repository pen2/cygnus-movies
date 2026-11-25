import SwiftUI

struct MovieSettingsView: View {
    @AppStorage(AppLanguage.preferenceKey) private var language = AppLanguage.system
    @AppStorage(EncodingPreferences.hardwareKey) private var hardware = true

    @AppStorage(LayerColor.preferenceKey) private var shapeRGB = LayerColor.defaultRGB

    var body: some View {
        let _ = language
        VStack(alignment: .leading, spacing: 14) {
            ColorPicker(L10n.text("シェイプの初期色"), selection: Binding(get: {
                let color = LayerColor.fromRGB(shapeRGB)
                return Color(.sRGB, red: color.red, green: color.green, blue: color.blue)
            }, set: { value in
                guard let color = NSColor(value).usingColorSpace(.sRGB) else { return }
                func byte(_ value: CGFloat) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
                shapeRGB = byte(color.redComponent) << 16 | byte(color.greenComponent) << 8 | byte(color.blueComponent)
            }), supportsOpacity: false)
            Divider()
            Text(L10n.text("書き出し設定")).font(.title2.weight(.semibold))
            Toggle(L10n.text("ハードウェアエンコードを使用"), isOn: $hardware)
                .toggleStyle(.switch)
            Text(L10n.text("対応するMacではハードウェアを優先します。利用できない場合はソフトウェアに切り替えます。オフにするとソフトウェアで書き出します。"))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            MovieExtensions.exports?.settings()
            Text(L10n.text("実際に使用した方式は「書き出し状況」に表示されます。"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 430)
        .environment(\.locale, language.locale)
        .preferredColorScheme(.dark)
    }
}
