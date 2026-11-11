import AppKit

enum AppLanguage: String, CaseIterable {
    case system, japanese, english

    static let preferenceKey = "appLanguage"

    var resolved: AppLanguage {
        guard self == .system else { return self }
        return Bundle.main.preferredLocalizations.first?.hasPrefix("en") == true ? .english : .japanese
    }

    var locale: Locale {
        resolved == .english ? Locale(identifier: "en_US") : Locale(identifier: "ja_JP")
    }
}

enum L10n {
    private static let english = Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:))

    static var language: AppLanguage {
        UserDefaults.standard.string(forKey: AppLanguage.preferenceKey).flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    static func text(_ key: String, language: AppLanguage = L10n.language) -> String {
        guard language.resolved == .english else { return key }
        return english?.localizedString(forKey: key, value: key, table: nil) ?? key
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: language.locale, arguments: arguments)
    }

    @MainActor
    static func updateMenuTitles() {
        let headers = ["ファイル": "ファイル", "File": "ファイル", "編集": "編集", "Edit": "編集",
                       "表示": "表示", "View": "表示", "ウインドウ": "ウインドウ", "Window": "ウインドウ",
                       "ヘルプ": "ヘルプ", "Help": "ヘルプ"]
        let actions = ["hide:": "cygnus moviesを隠す", "hideOtherApplications:": "ほかを隠す",
                       "unhideAllApplications:": "すべてを表示", "terminate:": "cygnus moviesを終了",
                       "performClose:": "閉じる", "performMiniaturize:": "最小化",
                       "cut:": "カット", "copy:": "コピー", "paste:": "ペースト",
                       "pasteAsPlainText:": "標準のスタイルでペースト", "selectAll:": "すべてを選択"]
        func updateActions(_ menu: NSMenu) {
            for item in menu.items {
                if let action = item.action, let key = actions[NSStringFromSelector(action)] { item.title = text(key) }
                if let submenu = item.submenu { updateActions(submenu) }
            }
        }
        guard let mainMenu = NSApp.mainMenu else { return }
        for item in mainMenu.items {
            if let key = headers[item.title] {
                item.title = text(key)
                item.submenu?.title = text(key)
            }
        }
        updateActions(mainMenu)
    }
}
