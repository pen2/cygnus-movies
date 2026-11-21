import AppKit
import SwiftUI

@main
struct CygnusMoviesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Cygnus Movies", id: "editor", for: UUID.self) { $id in
            ProjectWindow(session: delegate.session(for: id), delegate: delegate)
        }
        .defaultSize(width: 1250, height: 825)
        .commands { ApplicationCommands(delegate: delegate) }

        Settings { MovieSettingsView() }
    }
}

private struct ApplicationCommands: Commands {
    @ObservedObject var delegate: AppDelegate
    var body: some Commands {
        GlobalCommands(delegate: delegate)
        if let editor = delegate.editor {
            ProjectCommands(editor: editor, delegate: delegate)
        } else {
            CommandGroup(replacing: .newItem) {
                Button(L10n.text("新規プロジェクト"), action: delegate.newProjectWindow).keyboardShortcut("n")
                Button(L10n.text("プロジェクトを開く…"), action: delegate.chooseProject).keyboardShortcut("o")
            }
        }
    }
}

private struct GlobalCommands: Commands {
    let delegate: AppDelegate
    @AppStorage(AppLanguage.preferenceKey) private var language = AppLanguage.system
    var body: some Commands {
            CommandGroup(replacing: .appInfo) {
                Button(L10n.text("Cygnus Moviesについて"), action: delegate.showAbout)
            }
            CommandGroup(replacing: .help) {
                Button(L10n.text("Cygnus Movies ヘルプ"), action: delegate.showHelp)
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
}

private struct ProjectCommands: Commands {
    @ObservedObject var editor: Editor
    let delegate: AppDelegate
    @AppStorage(AppLanguage.preferenceKey) private var language = AppLanguage.system
    var body: some Commands {

            CommandGroup(replacing: .newItem) {
                Button(L10n.text("新規プロジェクト"), action: delegate.newProjectWindow)
                    .keyboardShortcut("n")
                Button(L10n.text("プロジェクトを開く…"), action: delegate.chooseProject)
                    .keyboardShortcut("o")
                Button(L10n.text("素材を読み込む…"), action: editor.chooseSources)
                    .keyboardShortcut("i")
                Button(L10n.text("クリップボードから一時的に素材を追加")) { editor.pasteTemporaryMedia() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                    .disabled(editor.loadingSources)
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
            CommandMenu(L10n.text("再生")) {
                Button(L10n.text("再生 / 一時停止"), action: editor.togglePlayback)
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(!editor.canCaptureFrame)
                Button(L10n.text("前のフレーム")) { editor.stepFrame(-1) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(!editor.canCaptureFrame)
                Button(L10n.text("次のフレーム")) { editor.stepFrame(1) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(!editor.canCaptureFrame)
                Divider()
                Button(L10n.text("画像をコピー"), action: editor.copyPreviewFrame)
                    .disabled(!editor.canCaptureFrame || editor.copyingFrame)
            }
            CommandGroup(replacing: .saveItem) {
                Button(L10n.text("保存…")) { editor.save() }.keyboardShortcut("s")
                Button(L10n.text("別名で保存…")) { editor.save(asNew: true) }.keyboardShortcut("s", modifiers: [.command, .shift])
            }

    }
}

private struct ProjectWindow: View {
    @StateObject var session: ProjectSession
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppLanguage.preferenceKey) private var language = AppLanguage.system

    var body: some View {
        EditorView(editor: session.editor, openFiles: { urls in
            delegate.openFiles(urls, preferred: session.editor)
        })
        .environment(\.locale, language.locale)
        .frame(minWidth: 990, minHeight: 675)
        .preferredColorScheme(.dark)
        .background(ProjectWindowBridge(session: session, delegate: delegate).frame(width: 0, height: 0))
        .onAppear {
            delegate.presentWindow = { id in openWindow(id: "editor", value: id) }
            delegate.register(session)
            delegate.editor = session.editor
            DispatchQueue.main.async { L10n.updateMenuTitles() }
        }
        .onChange(of: language) { _ in
            delegate.refreshHelp()
            DispatchQueue.main.async { L10n.updateMenuTitles() }
        }
    }
}

// Keep SwiftUI's own window delegate in the forwarding chain so scene lifecycle
// and the Window menu keep working while each project gets a close/save check.
private struct ProjectWindowBridge: NSViewRepresentable {
    let session: ProjectSession
    let delegate: AppDelegate
    func makeCoordinator() -> Coordinator { Coordinator(session: session, owner: delegate) }
    func makeNSView(context: Context) -> WindowView {
        let view = WindowView(); view.coordinator = context.coordinator; return view
    }
    func updateNSView(_ view: WindowView, context: Context) { view.attach() }
    final class WindowView: NSView {
        weak var coordinator: Coordinator?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach() }
        func attach() { if let window { coordinator?.attach(window) } }
    }
    final class Coordinator: NSObject, NSWindowDelegate {
        let session: ProjectSession
        let owner: AppDelegate
        weak var original: NSWindowDelegate?
        weak var attached: NSWindow?
        init(session: ProjectSession, owner: AppDelegate) { self.session = session; self.owner = owner }
        @MainActor func attach(_ window: NSWindow) {
            guard attached !== window else { return }
            attached = window
            original = window.delegate
            window.delegate = self
            owner.register(session, window: window)
        }
        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || original?.responds(to: selector) == true
        }
        override func forwardingTarget(for selector: Selector!) -> Any? {
            original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
        }
        func windowDidBecomeKey(_ notification: Notification) {
            owner.editor = session.editor
            original?.windowDidBecomeKey?(notification)
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard owner.mayClose(session.editor) else { return false }
            return original?.windowShouldClose?(sender) ?? true
        }
        func windowWillClose(_ notification: Notification) {
            owner.closed(session)
            original?.windowWillClose?(notification)
        }
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
