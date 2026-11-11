import SwiftUI

struct MovieSettingsView: View {
    @AppStorage(AppLanguage.preferenceKey) private var language = AppLanguage.system
    @AppStorage(EncodingPreferences.hardwareKey) private var hardware = true

    var body: some View {
        let _ = language
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("書き出し設定")).font(.title2.weight(.semibold))
            Toggle(L10n.text("ハードウェアエンコードを使用"), isOn: $hardware)
                .toggleStyle(.switch)
            Text(L10n.text("対応するMacではハードウェアを優先します。利用できない場合はソフトウェアに切り替えます。オフにするとソフトウェアで書き出します。"))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(L10n.text("実際に使用した方式は「書き出し状況」に表示されます。"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 430)
        .environment(\.locale, language.locale)
        .preferredColorScheme(.dark)
    }
}
