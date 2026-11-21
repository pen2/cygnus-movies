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

        let originalProject = editor.project
        let originalSelection = editor.selection
        let originalPlayhead = editor.playhead
        var openedWindows = [UUID]()
        delegate.presentWindow = { openedWindows.append($0) }
        let secondProject = folder.appendingPathComponent("second.CYGNUSMOVIES")
        var other = Project(); other.name = "Second"
        try JSONEncoder().encode(other).write(to: secondProject)
        delegate.openFiles([secondProject, first], preferred: editor)
        for _ in 0..<400 {
            if delegate.editor !== editor, delegate.editor?.project.sources.count == 1, delegate.editor?.loadingSources == false { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let opened = delegate.editor!
        precondition(opened !== editor && opened.projectURL == secondProject)
        precondition(editor.project == originalProject && editor.selection == originalSelection && editor.playhead == originalPlayhead)
        precondition(openedWindows.count == 1 && delegate.sessions.count == 1)
        let repeated = delegate.openProjectFile(secondProject)
        precondition(repeated === opened && openedWindows.count == 1)
        print("PASS project drop preserves the edited document, opens a separate session, imports mixed media there, and reuses an already-open project")

        let thirdProject = folder.appendingPathComponent("third.cygnusmovies")
        var thirdDocument = Project(); thirdDocument.name = "Third"
        try JSONEncoder().encode(thirdDocument).write(to: thirdProject)
        delegate.openFiles([project, thirdProject], preferred: opened)
        for _ in 0..<400 {
            if delegate.sessions.count == 3 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        precondition(delegate.sessions.count == 3 && openedWindows.count == 3)
        precondition(Set(delegate.sessions.values.compactMap { $0.editor.projectURL }) == Set([secondProject, project, thirdProject]))
        let last = delegate.editor!
        last.renameProject("Changed third")
        precondition(opened.project.name == "Second" && editor.project == originalProject)
        last.undo()
        precondition(last.project.name == "Third")
        let broken = folder.appendingPathComponent("broken.cygnusmovies")
        try Data("invalid".utf8).write(to: broken)
        let count = delegate.sessions.count
        precondition(delegate.openProjectFile(broken, preferred: last) == nil)
        precondition(delegate.sessions.count == count && last.project.name == "Third" && last.error != nil)
        print("PASS multiple projects open independently, undo is isolated, and invalid projects do not replace a document or open an empty window")
        for session in Array(delegate.sessions.values) { delegate.closed(session) }
        delegate.editor = nil
        let previousWindows = openedWindows.count
        delegate.openFiles([thirdProject])
        for _ in 0..<400 {
            if delegate.editor?.projectURL == thirdProject { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        precondition(delegate.sessions.count == 1 && delegate.editor?.projectURL == thirdProject)
        precondition(openedWindows.count == previousWindows + 1)
        print("PASS opening from Finder after all project windows close creates a new window and loads the project")


    }
}
