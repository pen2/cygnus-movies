import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published var editor: Editor? {
        didSet { processOpenRequests() }
    }

    var presentWindow: ((UUID) -> Void)?
    private(set) var sessions: [UUID: ProjectSession] = [:]
    private var windows: [UUID: NSWindow] = [:]
    private struct OpenRequest { let urls: [URL]; let preferred: Editor? }
    private var pendingOpenRequests: [OpenRequest] = []
    private var processingOpenRequests = false
    private var helpWindow: NSWindow?

    private var checkedRecovery = false
    func offerRecovery() {
        guard !checkedRecovery else { return }
        checkedRecovery = true
        Edition.documents?.offerRecovery { id, document in
            let recovered = Editor(recoveryID: id)
            recovered.restore(document)
            let session = ProjectSession(id: UUID(), editor: recovered)
            register(session)
            presentWindow?(session.id)
        }
    }

    func showHelp() {
        if let helpWindow {
            helpWindow.title = L10n.text("Cygnus Movies ヘルプ")
            helpWindow.contentViewController = NSHostingController(rootView: MovieHelpView())
            helpWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: MovieHelpView()))
        window.title = L10n.text("Cygnus Movies ヘルプ")
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

    func session(for id: UUID?) -> ProjectSession {
        if let id, let existing = sessions[id] { return existing }
        return ProjectSession(id: id ?? UUID(), editor: Editor())
    }

    func register(_ session: ProjectSession, window: NSWindow? = nil) {
        sessions[session.id] = session
        if let window {
            windows[session.id] = window
            session.editor.showExportWindow = { [weak window] in window?.makeKeyAndOrderFront(nil) }
        }
    }

    func closed(_ session: ProjectSession) {
        session.editor.player.pause()
        session.editor.player.replaceCurrentItem(with: nil)
        Edition.documents?.forget(session.editor.recoveryID)
        session.editor.temporaryMedia.cleanup()
        sessions[session.id] = nil
        windows[session.id] = nil
        if editor === session.editor { editor = sessions.values.first?.editor }
    }

    private func show(_ target: Editor) {
        if let session = sessions.values.first(where: { $0.editor === target }) {
            windows[session.id]?.makeKeyAndOrderFront(nil)
        }
        editor = target
    }

    func newProjectWindow() {
        if let editor, !editor.hasOpenProject { show(editor); return }
        let session = ProjectSession(id: UUID(), editor: Editor())
        register(session)
        editor = session.editor
        presentWindow?(session.id)
    }

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(exportedAs: "local.cygnus-movies.project")]
        panel.allowsMultipleSelection = true
        panel.title = L10n.text("プロジェクトを開く")
        panel.prompt = L10n.text("開く")
        if panel.runModal() == .OK { openFiles(panel.urls, preferred: editor) }
    }

    @discardableResult
    func openProjectFile(_ url: URL, preferred: Editor? = nil) -> Editor? {
        let url = url.standardizedFileURL
        if let existing = allEditors.first(where: { $0.projectURL?.standardizedFileURL == url }) {
            show(existing)
            return existing
        }
        let current = preferred ?? editor
        let target = current.flatMap { $0.hasOpenProject ? nil : $0 } ?? Editor()
        guard target.openProject(at: url) else {
            current?.error = target.error
            return nil
        }
        if target !== current {
            let session = ProjectSession(id: UUID(), editor: target)
            register(session)
            editor = target
            presentWindow?(session.id)
        } else { show(target) }
        return target
    }

    func application(_ application: NSApplication, open urls: [URL]) { openFiles(urls) }

    func openFiles(_ urls: [URL], preferred: Editor? = nil) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        pendingOpenRequests.append(OpenRequest(urls: files, preferred: preferred))
        if editor == nil, presentWindow != nil { newProjectWindow() }
        processOpenRequests()
    }

    private func processOpenRequests() {
        guard editor != nil, !processingOpenRequests else { return }
        processingOpenRequests = true
        Task { @MainActor in
            defer { processingOpenRequests = false }
            while !pendingOpenRequests.isEmpty, editor != nil {
                let request = pendingOpenRequests.removeFirst()
                var target = request.preferred ?? editor!
                let projects = request.urls.filter { $0.pathExtension.lowercased() == "cygnusmovies" }
                let media = request.urls.filter { $0.pathExtension.lowercased() != "cygnusmovies" }
                var failed = false
                for project in projects {
                    guard let opened = openProjectFile(project, preferred: target) else { failed = true; break }
                    target = opened
                }
                if failed { continue }
                while target.loadingSources { try? await Task.sleep(for: .milliseconds(25)) }
                if !media.isEmpty { target.importSources(media) }
            }
        }
    }

    private var allEditors: [Editor] {
        var result = sessions.values.map(\.editor)
        if let editor, !result.contains(where: { $0 === editor }) { result.append(editor) }
        return result
    }

    func mayClose(_ editor: Editor) -> Bool {
        if editor.exporting || editor.loadingSources {
            let alert = NSAlert()
            alert.messageText = L10n.text("処理が完了するか中止してから、ウインドウを閉じてください。")
            alert.addButton(withTitle: L10n.text("閉じる"))
            alert.runModal()
            return false
        }
        return editor.mayDiscardChanges()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let editors = allEditors
        if editors.contains(where: \.exporting) {
            let alert = NSAlert()
            alert.messageText = L10n.text("書き出しを中止して終了しますか？")
            alert.addButton(withTitle: L10n.text("作業を続ける"))
            alert.addButton(withTitle: L10n.text("中止して終了"))
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        guard editors.allSatisfy({ $0.mayDiscardChanges() }) else { return .terminateCancel }
        if editors.contains(where: \.exporting) {
            editors.forEach { $0.cancelExport() }
            Task {
                while editors.contains(where: \.exporting) { try? await Task.sleep(for: .milliseconds(100)) }
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        allEditors.forEach { Edition.documents?.forget($0.recoveryID); $0.temporaryMedia.cleanup() }
        AudioPreparationCache.shared.removeTemporaryFiles()
    }
}

@MainActor
final class ProjectSession: ObservableObject, Identifiable {
    let id: UUID
    let editor: Editor
    init(id: UUID, editor: Editor) { self.id = id; self.editor = editor }
}
