import AppKit
import SwiftUI

@main
struct CygnusMoviesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var editor = Editor()
    @AppStorage(AppLanguage.preferenceKey) private var language = AppLanguage.system

    var body: some Scene {
        Window("cygnus movies", id: "editor") {
            EditorView(editor: editor)
                .environment(\.locale, language.locale)
                .frame(minWidth: 990, minHeight: 675)
                .preferredColorScheme(.dark)
                .onAppear {
                    delegate.editor = editor
                    DispatchQueue.main.async { L10n.updateMenuTitles() }
                }
                .onChange(of: language) { _ in
                    delegate.refreshHelp()
                    DispatchQueue.main.async { L10n.updateMenuTitles() }
                }
        }
        .defaultSize(width: 1250, height: 825)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(L10n.text("cygnus moviesについて"), action: delegate.showAbout)
            }
            CommandGroup(replacing: .newItem) {
                Button(L10n.text("新規プロジェクト"), action: editor.newProject)
                    .keyboardShortcut("n")
                Button(L10n.text("プロジェクトを開く…"), action: editor.openProject)
                    .keyboardShortcut("o")
                Button(L10n.text("素材を読み込む…"), action: editor.chooseSources)
                    .keyboardShortcut("i")
                Divider()
                Button(L10n.text("プロジェクトファイルを関連付け…"), action: editor.associateProjectFiles)
            }
            EditHistoryCommands(editor: editor)
            CommandGroup(after: .pasteboard) {
                Divider()
                Button(L10n.text("再生位置で分割（B）"), action: editor.split)
                    .keyboardShortcut("b")
                    .disabled(!editor.canSplit)
                Button(L10n.text("選択項目を取り除く（Delete）"), action: editor.deleteSelection)
                    .disabled(editor.selection == nil)
                Button(L10n.text("レイヤーを複製"), action: editor.duplicateLayer)
                    .keyboardShortcut("d")
                    .disabled(editor.selectedLayer == nil)
            }
            CommandGroup(replacing: .help) {
                Button(L10n.text("cygnus movies ヘルプ"), action: delegate.showHelp)
            }
            CommandGroup(replacing: .saveItem) {
                Button(L10n.text("保存…")) { editor.save() }.keyboardShortcut("s")
                Button(L10n.text("別名で保存…")) { editor.save(asNew: true) }.keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandMenu(L10n.text("言語", language: language)) {
                Picker(L10n.text("表示言語", language: language), selection: $language) {
                    Text(L10n.text("システム設定に従う", language: language)).tag(AppLanguage.system)
                    Text(verbatim: "日本語").tag(AppLanguage.japanese)
                    Text(verbatim: "English").tag(AppLanguage.english)
                }
                .pickerStyle(.inline)
            }
        }
        Settings { MovieSettingsView() }
    }
}


private struct EditHistoryCommands: Commands {
    @AppStorage(AppLanguage.preferenceKey) private var language = AppLanguage.system

    @ObservedObject var editor: Editor

    var body: some Commands {
        let _ = language

        CommandGroup(replacing: .undoRedo) {
            Button(L10n.text("取り消す")) { editor.performHistoryCommand(redo: false) }
                .keyboardShortcut("z")
                .disabled(!editor.canPerformHistoryCommand(redo: false))
            Button(L10n.text("やり直す")) { editor.performHistoryCommand(redo: true) }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!editor.canPerformHistoryCommand(redo: true))
        }
    }
}
