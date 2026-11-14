import AppKit

// Exercise the actual NSApplicationDelegate routing, including pre-window events.
@main struct OpenFilesCheck {
    @MainActor static func waitForImports(_ editor: Editor, count: Int) async throws {
        for _ in 0..<400 {
            if editor.project.sources.count == count && !editor.loadingSources { return }
            if let error = editor.error { fatalError(error) }
            try await Task.sleep(for: .milliseconds(25))
        }
        fatalError("Import timed out: expected \(count), got \(editor.project.sources.count)")
    }

    @MainActor static func main() async throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        let app = NSApplication.shared
        let first = folder.appendingPathComponent("first.MP4")
        let second = folder.appendingPathComponent("second.mov")
        let image = folder.appendingPathComponent("image.png")
        let delegate = AppDelegate()
        delegate.application(app, open: [first, image])
        delegate.application(app, open: [second])
        let editor = Editor()
        delegate.editor = editor
        try await waitForImports(editor, count: 3)
        precondition(Set(editor.project.sources.map(\.path)) == Set([first, second, image].map(\.path)))
        precondition(editor.timeline.clips.isEmpty)
        precondition(editor.projectURL == nil && editor.error == nil)
        print("PASS cold start: all queued files, uppercase MP4, MOV, image; library only")

        let third = folder.appendingPathComponent("third.mp4")
        let fourth = folder.appendingPathComponent("fourth.mp4")
        editor.importSources([third])
        delegate.application(app, open: [fourth])
        try await waitForImports(editor, count: 5)
        precondition(editor.error == nil)
        print("PASS running app: files arriving during an import are added without replacing the project")

        delegate.application(app, open: [first, image])
        // Allow the queued event to finish even though all sources already exist.
        try await Task.sleep(for: .milliseconds(200))
        precondition(editor.project.sources.count == 5 && editor.error == nil)
        print("PASS repeated opens do not duplicate library sources")

        let project = folder.appendingPathComponent("saved.cygnusmovies")
        try JSONEncoder().encode(Project()).write(to: project)
        let projectDelegate = AppDelegate()
        projectDelegate.application(app, open: [project, first])
        let projectEditor = Editor()
        projectDelegate.editor = projectEditor
        try await waitForImports(projectEditor, count: 1)
        precondition(projectEditor.projectURL == project && projectEditor.error == nil)
        print("PASS project opening preserved; mixed request imports media into the opened project")
    }
}
