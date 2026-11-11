import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var editor: Editor? {
        didSet {
            if let pendingURL {
                editor?.openProject(at: pendingURL)
                self.pendingURL = nil
            }
        }
    }

    private var pendingURL: URL?
    private var helpWindow: NSWindow?

    func showHelp() {
        if let helpWindow {
            helpWindow.title = L10n.text("cygnus movies ヘルプ")
            helpWindow.contentViewController = NSHostingController(rootView: MovieHelpView())
            helpWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: MovieHelpView()))
        window.title = L10n.text("cygnus movies ヘルプ")
        window.styleMask.insert(.resizable)
        window.setContentSize(NSSize(width: 680, height: 680))
        window.minSize = NSSize(width: 460, height: 400)
        window.isReleasedWhenClosed = false
        window.center()
        helpWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    func refreshHelp() {
        guard helpWindow?.isVisible == true else { return }
        showHelp()
    }

    func showAbout() {
        let credits = NSMutableAttributedString(string: L10n.text("制作  cygnus2\n"))
        if let website = URL(string: "https://cygnus2.jp/") {
            credits.append(NSAttributedString(string: "https://cygnus2.jp/", attributes: [.link: website]))
        }
        credits.append(NSAttributedString(string: "\n\n"))
        if let license = Bundle.main.url(forResource: "LICENSE", withExtension: "txt") {
            credits.append(NSAttributedString(string: L10n.text("MITライセンス"), attributes: [.link: license]))
        } else {
            credits.append(NSAttributedString(string: L10n.text("MITライセンス")))
        }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let range = NSRange(location: 0, length: credits.length)
        credits.addAttributes([.paragraphStyle: style, .font: NSFont.systemFont(ofSize: 12)], range: range)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if let editor { editor.openProject(at: url) }
        else { pendingURL = url }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let editor else { return .terminateNow }
        if editor.exporting {
            let alert = NSAlert()
            alert.messageText = L10n.text("書き出しを中止して終了しますか？")
            alert.addButton(withTitle: L10n.text("作業を続ける"))
            alert.addButton(withTitle: L10n.text("中止して終了"))
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        guard editor.mayDiscardChanges() else { return .terminateCancel }
        if editor.exporting {
            editor.cancelExport()
            Task {
                while editor.exporting { try? await Task.sleep(for: .milliseconds(100)) }
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        return .terminateNow
    }
}

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
