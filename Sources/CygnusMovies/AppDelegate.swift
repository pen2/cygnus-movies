import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var editor: Editor? {
        didSet { processOpenRequests() }
    }

    private var pendingOpenRequests: [[URL]] = []
    private var processingOpenRequests = false
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
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        pendingOpenRequests.append(files)
        processOpenRequests()
    }

    private func processOpenRequests() {
        guard editor != nil, !processingOpenRequests else { return }
        processingOpenRequests = true
        Task { @MainActor in
            defer { processingOpenRequests = false }
            while !pendingOpenRequests.isEmpty, let editor {
                // Finder can deliver several open events during startup or an import.
                // Wait instead of losing a request to importSources' busy guard.
                while editor.loadingSources {
                    try? await Task.sleep(for: .milliseconds(25))
                }
                let urls = pendingOpenRequests.removeFirst()
                let projects = urls.filter { $0.pathExtension.lowercased() == "cygnusmovies" }
                let media = urls.filter { $0.pathExtension.lowercased() != "cygnusmovies" }
                if let project = projects.first, !editor.openProject(at: project) {
                    continue
                }
                if !media.isEmpty { editor.importSources(media) }
            }
        }
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
