import AVKit
import SwiftUI
import UniformTypeIdentifiers

private let accent = Color(red: 0.43, green: 0.85, blue: 0.81)
private let brightAccent = Color(red: 0.75, green: 1, blue: 0.97)
private let surface = Color(red: 0.098, green: 0.111, blue: 0.13)
private let workspace = Color(red: 0.069, green: 0.08, blue: 0.096)

struct EditorView: View {
    @AppStorage(AppLanguage.preferenceKey) private var language = AppLanguage.system

    @ObservedObject var editor: Editor
    @State private var removeTimeline = false
    @State private var timelineRemovalTarget: Timeline?
    @State private var zoom = 0.56
    @State private var fitTimeline = false
    @AppStorage("timelineSnapping") private var snapping = true
    @State private var renamingProject = false
    @State private var projectNameDraft = ""
    @State private var renamingTimeline = false
    @State private var timelineRenameTarget: UUID?
    @State private var timelineName = ""
    @State private var bulkRename = false
    @State private var showExportProgress = false
    @State private var inspectorTab = InspectorTab.timeline
    @State private var timelineDropTarget: UUID?
    @State private var dragAvatar: TimelineDragAvatar?
    @State private var timelineTabFrames: [UUID: CGRect] = [:]
    @State private var timelineTabViewport = CGRect.null

    private enum InspectorTab { case timeline, selection }

    private struct PreviewRequest: Equatable {
        let id: UUID
        let clips: [Clip]
        let layers: [VisualLayer]
        let size: CGSize
        let fps: Int
        let color: OutputColor
        let sources: [Source]
    }

    var body: some View {
        let _ = language

        GeometryReader { geometry in
            let base: CGFloat = editor.timeline.showWaveform == true ? 230 : 190
            let row = TimelineTrack.layerRowHeight
            let available = max(1, Int((geometry.size.height - 55 - 180 - base) / row))
            let inspectorWidth: CGFloat = 288
            let layerHeight = CGFloat(min(15, available, editor.timeline.layers.count)) * row
            VStack(spacing: 0) {
                toolbar
                Divider()
                HStack(spacing: 0) {
                    library.frame(width: 236)
                    Divider()
                    monitor
                        .layoutPriority(1)
                        .clipped()
                    Divider()
                    inspector(width: inspectorWidth)
                        .frame(width: inspectorWidth)
                        .clipped()
                }
                Divider()
                timelineArea(layerHeight: layerHeight, viewportWidth: geometry.size.width).frame(height: base + layerHeight)
            }
        }
        .background(workspace)
        .overlay {
            if let dragAvatar {
                HStack(spacing: 7) {
                    if let source = dragAvatar.source {
                        SourceThumbnail(source: source, missing: !FileManager.default.fileExists(atPath: source.path),
                                        frame: dragAvatar.frame)
                    } else {
                        Image(systemName: dragAvatar.symbol).foregroundStyle(accent)
                    }
                    Text(dragAvatar.title).lineLimit(1)
                    if dragAvatar.count > 1 { Text("+\(dragAvatar.count - 1)").monospacedDigit() }
                    if dragAvatar.copying { Image(systemName: "plus.circle.fill").foregroundStyle(.orange) }
                }
                .font(.caption.weight(.semibold))
                .padding(8)
                .background(surface.opacity(0.93), in: RoundedRectangle(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(accent.opacity(0.6)) }
                .shadow(color: .black.opacity(0.4), radius: 7, y: 3)
                .frame(maxWidth: 240)
                .position(x: dragAvatar.location.x, y: dragAvatar.location.y - 30)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .coordinateSpace(name: TimelineScale.editorSpace)
        .background(EditorShortcuts(editor: editor).frame(width: 0, height: 0))
        .onChange(of: editor.selection) { selection in
            switch selection {
            case .clip, .layer: inspectorTab = .selection
            case .source, nil: inspectorTab = .timeline
            }
        }
        .tint(accent)
        .buttonStyle(HoverButtonStyle())
        .task(id: PreviewRequest(id: editor.timeline.id, clips: editor.timeline.clips,
                                 layers: editor.timeline.layers, size: editor.timeline.output.size,
                                 fps: editor.timeline.output.fps, color: editor.timeline.output.colorMode, sources: editor.project.sources)) {
            await editor.rebuildPreview()
        }
        .alert("cygnus movies", isPresented: Binding(get: { editor.error != nil }, set: { if !$0 { editor.error = nil } })) {
            Button(L10n.text("閉じる"), role: .cancel) {}
        } message: {
            Text(editor.error ?? "")
        }
        .alert(L10n.text("タイムラインを削除しますか？"), isPresented: $removeTimeline, presenting: timelineRemovalTarget) { timeline in
            Button(L10n.text("削除"), role: .destructive) { editor.deleteTimeline(timeline.id) }
            Button(L10n.text("キャンセル"), role: .cancel) {}
        } message: { timeline in
            Text(L10n.format("「%@」をプロジェクトから削除します。", String(describing: timeline.name)))
        }
        .alert(L10n.text("プロジェクト名を変更"), isPresented: $renamingProject) {
            TextField(L10n.text("プロジェクト名"), text: $projectNameDraft)
            Button(L10n.text("キャンセル"), role: .cancel) {}
            Button(L10n.text("変更")) { editor.renameProject(projectNameDraft) }
        }
        .alert(L10n.text("タイムライン名を変更"), isPresented: $renamingTimeline) {
            TextField(L10n.text("タイムライン名"), text: $timelineName)
            Button(L10n.text("キャンセル"), role: .cancel) {}
            Button(L10n.text("変更")) {
                if let id = timelineRenameTarget { editor.renameTimeline(id, to: timelineName) }
            }
        }
        .sheet(item: $editor.exportPlan, onDismiss: {
            if showExportProgress {
                showExportProgress = false
                editor.showingJobs = true
            }
        }) { plan in
            ExportNamesView(plan: plan) { edited in
                try editor.confirmExport(edited)
                showExportProgress = true
            }
        }
        .sheet(isPresented: $editor.showingJobs) { exportSheet }
        .sheet(isPresented: $bulkRename) {
            TimelineNamesView(timelines: editor.project.timelines, apply: editor.renameTimelines)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "film.stack").font(.system(size: 20, weight: .medium)).foregroundStyle(accent)
            HStack(spacing: 8) {
                Text(editor.projectName ?? L10n.text("名称未設定"))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if editor.dirty {
                    Text(L10n.text("未保存"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.orange.opacity(0.13), in: RoundedRectangle(cornerRadius: 5))
                        .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.orange.opacity(0.32)) }
                        .fixedSize()
                }
            }
            Button {
                projectNameDraft = editor.projectName ?? ""
                renamingProject = true
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(HoverColorButtonStyle(color: accent, hoverColor: brightAccent))
            .help(L10n.text("プロジェクト名を変更"))
            .accessibilityLabel(L10n.text("プロジェクト名を変更"))
            Spacer()
            Button { editor.save() } label: { Label(L10n.text("保存"), systemImage: "tray.and.arrow.down") }
            if !editor.jobs.isEmpty {
                Button { editor.showingJobs = true } label: { Label(L10n.text("書き出し状況"), systemImage: "list.bullet.rectangle") }
            }
            Menu {
                Button(L10n.text("現在のタイムライン…")) { editor.startExport(all: false) }
                    .disabled(!editor.timeline.hasContent)
                Button(L10n.text("すべてのタイムライン…")) { editor.startExport(all: true) }
            } label: {
                Label(L10n.text("書き出し"), systemImage: "square.and.arrow.up")
            }
            .fixedSize()
            .editorHover()
            .disabled(editor.exporting || !editor.project.timelines.contains(where: \.hasContent))
        }
        .padding(.horizontal, 17)
        .frame(height: 55)
        .background(surface)
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.text("素材")).font(.headline)
                Text("\(editor.librarySources.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                if editor.loadingSources { ProgressView().controlSize(.small) }
                Button {
                    if let source = editor.selectedSource { editor.removeSource(source) }
                } label: { Image(systemName: "minus") }
                    .buttonStyle(HoverColorButtonStyle(color: accent, hoverColor: .orange, bordered: true))
                    .help(L10n.text("素材一覧から取り除く")).disabled(editor.selectedSource == nil)
                Button(action: editor.chooseSources) { Image(systemName: "plus") }
                    .help(L10n.text("素材を読み込む")).disabled(editor.loadingSources)
            }
            .padding(13)

            if editor.librarySources.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "film").font(.system(size: 24)).foregroundStyle(.tertiary)
                    Text(L10n.text("動画・画像をドロップ")).font(.caption).foregroundStyle(.secondary)
                    Button(L10n.text("素材を読み込む…"), action: editor.chooseSources).disabled(editor.loadingSources)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(editor.librarySources) { source in
                            sourceRow(source)
                        }
                    }
                    .padding(.horizontal, 9)
                }
                .safeAreaInset(edge: .bottom) {
                    Button {
                        if let source = editor.selectedSource { editor.addClip(source) }
                    } label: {
                        Label(L10n.text("タイムラインに追加"), systemImage: "plus.circle")
                    }
                    .disabled(editor.selectedSource == nil)
                    .padding(11)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(surface)
        .dropDestination(for: URL.self) { urls, _ in
            editor.importSources(urls.filter(\.isFileURL))
            return urls.contains(where: \.isFileURL)
        }
    }

    private func sourceRow(_ source: Source) -> some View {
        let missing = !FileManager.default.fileExists(atPath: source.path)
        return HStack(spacing: 7) {
            SourceThumbnail(source: source, missing: missing)
            VStack(alignment: .leading, spacing: 3) {
                Text(source.name).font(.callout).lineLimit(1).truncationMode(.middle)
                Text(missing ? L10n.text("見つかりません") : source.isImage ? L10n.text("画像") : timecode(source.frames))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button { editor.addClip(source) } label: { Image(systemName: "plus.circle") }
                .buttonStyle(.borderless).editorHover().help(L10n.text("タイムラインに追加"))
        }
        .padding(8)
        .background(editor.sourceID == source.id ? accent.opacity(0.14) : .white.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .editorHover(radius: 6)
        .onTapGesture(count: 2) {
            editor.addClip(source)
        }
        .onTapGesture { editor.selectSource(source.id) }
        .draggable(TimelineDrag(payload: "source:\(source.id.uuidString)"))
        .contextMenu {
            Button(L10n.text("このタイムラインに追加")) { editor.addClip(source) }.disabled(missing)
            let otherTimelines = editor.project.timelines.filter { $0.id != editor.timeline.id }
            if !otherTimelines.isEmpty {
                Menu(L10n.text("他のタイムラインに追加")) {
                    ForEach(otherTimelines) { timeline in
                        Button(editor.timelineDisplayName(timeline)) { editor.addClip(source, to: timeline.id) }
                    }
                }
                .disabled(missing)
            }
            Button(L10n.text("新しいタイムラインに追加")) { editor.addTimeline(with: source) }.disabled(missing)
            if source.isImage {
                Button(L10n.text("画像レイヤーとして追加")) { editor.addLayer(.image, source: source) }
                    .disabled(missing)
            }
            Divider()
            Button(L10n.text("Finderで元ファイルを表示")) { NSWorkspace.shared.activateFileViewerSelecting([source.url]) }
                .disabled(missing)
            Button(L10n.text("元ファイルを再指定…")) { editor.relink(source) }.disabled(editor.loadingSources)
            Divider()
            Button(L10n.text("素材一覧から取り除く")) { editor.removeSource(source) }
        }
        .buttonStyle(.automatic)
        .help(source.path)
    }

    private var monitor: some View {
        VStack(spacing: 0) {
            HStack {
                Label(L10n.text("プレビュー"), systemImage: "play.rectangle").font(.caption.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 8)
                Text("\(Int(editor.timeline.output.size.width)) × \(Int(editor.timeline.output.size.height))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 13).padding(.vertical, 11)
            GeometryReader { geometry in
                let size = editor.timeline.output.size
                let scale = min(geometry.size.width / size.width, geometry.size.height / size.height)
                ZStack {
                    PlayerSurface(player: editor.player)
                    if !editor.timeline.hasContent || editor.previewError != nil {
                        Color.black
                        VStack(spacing: 12) {
                            Image(systemName: editor.previewError == nil ? "play.rectangle" : "exclamationmark.triangle")
                                .font(.system(size: 26)).foregroundStyle(.secondary)
                            Text(editor.previewError ?? L10n.text("タイムラインに素材かレイヤーを追加"))
                                .font(.callout).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center).padding(.horizontal)
                        }
                    }
                }
                .frame(width: size.width * scale, height: size.height * scale)
                .overlay {
                    if let layer = editor.selectedLayer, editor.previewError == nil, editor.timeline.hasContent,
                       !editor.playing {
                        LayerRegionGuide(layer: layer, editor: editor).id(layer.id)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 13)
            HStack(spacing: 12) {
                Button { editor.seek(0) } label: { Image(systemName: "backward.end.fill") }.help(L10n.text("先頭へ"))
                Button(action: editor.togglePlayback) {
                    Image(systemName: editor.playing ? "pause.fill" : "play.fill").frame(width: 19)
                }
                .keyboardShortcut(.space, modifiers: [])
                .help(L10n.text("再生 / 一時停止"))
                Button { editor.seek(editor.totalFrames) } label: { Image(systemName: "forward.end.fill") }.help(L10n.text("末尾へ"))
                Text(timecode(editor.previewFrame, fps: editor.previewFPS))
                    .font(.system(.callout, design: .monospaced)).foregroundStyle(accent)
                Text("/ " + timecode(editor.previewFrameCount, fps: editor.previewFPS))
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                let frameNumber = editor.previewFrameCount == 0 ? 0 : editor.previewFrame + 1
                Text(L10n.format("フレーム %@ / %@", String(describing: frameNumber), String(describing: editor.previewFrameCount)))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .buttonStyle(HoverColorButtonStyle(color: accent, hoverColor: brightAccent))
            .disabled(!editor.timeline.hasContent || editor.previewError != nil)
            .frame(height: 44)
        }
        .frame(maxWidth: .infinity)
    }

    private func inspector(width: CGFloat) -> some View {
        let contentWidth = width - 34
        return VStack(spacing: 0) {
            Picker(L10n.text("表示する設定"), selection: $inspectorTab) {
                Text(L10n.text("タイムライン設定")).tag(InspectorTab.timeline)
                Text(selectionTabTitle).tag(InspectorTab.selection)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    if inspectorTab == .timeline {
                        timelineSettings
                    } else if let layer = editor.selectedLayer {
                        LayerInspector(editor: editor, layer: layer, width: contentWidth).id(layer.id)
                    } else if let clip = editor.selectedClip {
                        clipInspector(clip, width: contentWidth)
                    } else {
                        Text(L10n.text("タイムラインのクリップまたはレイヤーを選択"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(width: contentWidth, alignment: .leading)
                .padding(.leading, 13)
                .padding(.vertical, 13)
                .frame(width: width, alignment: .leading)
            }
        }
        .background(surface)
    }

    private var selectionTabTitle: String {
        if let layer = editor.selectedLayer { return L10n.format("%@レイヤー", layer.kind.title) }
        return editor.selectedClip == nil ? L10n.text("選択項目") : L10n.text("クリップ")
    }

    private var timelineSettings: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(editor.timelineDisplayName(editor.timeline)).font(.callout.weight(.semibold)).lineLimit(1)
            VStack(spacing: 6) {
                inspectorPicker(L10n.text("解像度"), selection: sizingBinding(\.ultraHD), values: [false, true]) { $0 ? "4K" : "FHD" }
                inspectorPicker(L10n.text("画面比率"), selection: sizingBinding(\.aspectRatio), values: AspectRatio.allCases, title: \.title)
                inspectorPicker("fps", selection: Binding(
                    get: { editor.timeline.output.frameRate ?? .fps30 },
                    set: { value in editor.updateOutputSizing { $0.frameRate = value } }
                ), values: FrameRate.allCases) { "\($0.rawValue) fps" }
                if editor.timeline.outputOrigin == .automatic {
                    Text(L10n.text("素材から自動選択されました"))
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider().padding(.vertical, 4)
                inspectorPicker(L10n.text("形式"), selection: outputBinding(\.container), values: Container.allCases) { $0.rawValue.uppercased() }
                inspectorPicker(L10n.text("コーデック"), selection: Binding(
                    get: { editor.timeline.output.videoCodec },
                    set: { value in editor.updateTimeline { $0.output.codec = value } }
                ), values: Codec.allCases, title: \.title)
                .disabled(editor.timeline.output.colorMode == .hdr)
                inspectorPicker(L10n.text("色設定"), selection: Binding(
                    get: { editor.timeline.output.colorMode },
                    set: { value in editor.updateTimeline { $0.output.color = value } }
                ), values: OutputColor.allCases, title: \.title)
                inspectorPicker(L10n.text("音声"), selection: Binding(
                    get: { editor.timeline.output.audioFormat },
                    set: { value in editor.updateTimeline { $0.output.audio = value } }
                ), values: editor.timeline.output.audioOptions, title: \.title)
            }
            if editor.timeline.output.colorMode == .hdr {
                Text(L10n.text("HDRはHEVC 10-bit / HLGで書き出します。")).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func clipInspector(_ clip: Clip, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(editor.name(of: clip)).font(.callout.weight(.medium)).lineLimit(1)
            Text(L10n.text("素材の使用範囲（フレーム）")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(L10n.text("開始"))
                TextField(L10n.text("開始"), value: Binding(get: { editor.selectedClip?.start ?? clip.start },
                                                set: { editor.trim(clip.id, start: $0) }), format: .number.grouping(.never))
                    .frame(width: (width - 76) / 2)
                    .editorHover()
                Text(L10n.text("終了"))
                TextField(L10n.text("終了"), value: Binding(get: { editor.selectedClip?.end ?? clip.end },
                                                set: { editor.trim(clip.id, end: $0) }), format: .number.grouping(.never))
                    .frame(width: (width - 76) / 2)
                    .editorHover()
            }
            .font(.caption.monospacedDigit())
            Text(timecode(clip.start) + "  –  " + timecode(clip.end))
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            if editor.project.sources.first(where: { $0.id == clip.sourceID })?.isImage == false {
                HStack(spacing: 6) {
                    Text(L10n.text("再生速度")).frame(width: 82, alignment: .leading)
                    TextField(L10n.text("再生速度"), value: Binding(
                        get: { (editor.selectedClip ?? clip).playbackRate * 100 },
                        set: { editor.setSpeed(clip.id, percent: $0) }
                    ), format: .number.grouping(.never).precision(.fractionLength(0...2)))
                    .textFieldStyle(.roundedBorder)
                    Text("%")
                    Menu {
                        ForEach([25, 50, 100, 150, 200, 400, 800], id: \.self) { percent in
                            Button("\(percent)%") { editor.setSpeed(clip.id, percent: Double(percent)) }
                        }
                    } label: { Image(systemName: "chevron.down") }
                    .fixedSize()
                }
                .font(.caption)
                Text(L10n.text("10〜800％で指定できます。音声の高さを保持します。"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            inspectorPicker(L10n.text("余白の埋め方"), selection: Binding(
                get: { editor.selectedClip?.canvasFill ?? .black },
                set: { fill in editor.updateClip(clip.id) { $0.canvasFill = fill == .black ? nil : fill } }
            ), values: CanvasFill.allCases, title: \.title)
            if let source = editor.project.sources.first(where: { $0.id == clip.sourceID }),
               !FileManager.default.fileExists(atPath: source.path) {
                Button(L10n.text("元ファイルを再指定…")) { editor.relink(source) }.disabled(editor.loadingSources)
            }
            Toggle(L10n.text("無音化"), isOn: Binding(get: { editor.selectedClip?.muted == true },
                                           set: { value in editor.updateClip(clip.id) { $0.muted = value ? true : nil } }))
                .editorHover()
            HStack {
                Text(L10n.text("音量"))
                Slider(value: Binding(get: { editor.selectedClip?.volume ?? 1 },
                                      set: { value in editor.updateClip(clip.id) { $0.volume = value == 1 ? nil : value } }),
                       in: 0...1, step: 0.01)
                    .accessibilityLabel(L10n.text("音量")).editorHover()
                Text((clip.volume ?? 1).formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption.monospacedDigit()).frame(width: 38, alignment: .trailing)
            }
            .disabled(clip.muted == true)
            Toggle(L10n.text("フェードイン"), isOn: clipBinding(clip, \.fadeIn)).editorHover()
            Toggle(L10n.text("フェードアウト"), isOn: clipBinding(clip, \.fadeOut)).editorHover()
            inspectorPicker(L10n.text("次への切替"), selection: clipBinding(clip, \.transition),
                            values: Transition.allCases, title: \.title)
            .disabled(editor.timeline.clips.last?.id == clip.id)
            Text(L10n.text("フェードと切替は最長 0.3 秒")).font(.caption2).foregroundStyle(.secondary)
            if editor.project.sources.first(where: { $0.id == clip.sourceID })?.isImage == false {
                Divider().padding(.vertical, 4)
                HStack {
                    Text(L10n.text("色補正")).font(.headline)
                    Spacer()
                    Button(L10n.text("リセット")) { editor.updateClip(clip.id) { $0.colorCorrection = nil } }
                        .disabled(clip.colorCorrection == nil)
                }
                colorParameter(L10n.text("明るさ"), clip: clip, key: \.brightness, range: -1...1, step: 0.01)
                colorParameter(L10n.text("色温度"), clip: clip, key: \.temperature, range: 2000...12000, step: 50, unit: "K")
                colorParameter(L10n.text("色かぶり"), clip: clip, key: \.tint, range: -150...150, step: 1)
                colorParameter(L10n.text("ガンマ"), clip: clip, key: \.gamma, range: 0.1...4, step: 0.01)
                colorParameter(L10n.text("彩度"), clip: clip, key: \.saturation, range: 0...2, step: 0.01)
                colorParameter(L10n.text("色相"), clip: clip, key: \.hue, range: -180...180, step: 1, unit: "°")
            }
        }
    }

    private func colorParameter(_ label: String, clip: Clip, key: WritableKeyPath<ClipColorCorrection, Double>,
                                range: ClosedRange<Double>, step: Double, unit: String = "") -> some View {
        let binding = Binding<Double>(
            get: { ((editor.selectedClip ?? clip).colorCorrection ?? ClipColorCorrection())[keyPath: key] },
            set: { value in
                guard value.isFinite else { return }
                editor.updateClip(clip.id) {
                    var correction = $0.colorCorrection ?? ClipColorCorrection()
                    correction[keyPath: key] = min(range.upperBound, max(range.lowerBound, value))
                    $0.colorCorrection = correction == ClipColorCorrection() ? nil : correction
                }
            }
        )
        return HStack(spacing: 6) {
            Text(label).lineLimit(1).frame(width: 72, alignment: .leading)
            Slider(value: binding, in: range, step: step).accessibilityLabel(label).editorHoverBrightness()
            TextField(label, value: binding, format: .number.grouping(.never).precision(.fractionLength(0...2)))
                .frame(width: 55).textFieldStyle(.roundedBorder)
            if !unit.isEmpty { Text(unit).foregroundStyle(.secondary) }
        }
        .font(.caption.monospacedDigit())
    }

    private func sizingBinding<T>(_ key: WritableKeyPath<OutputSettings, T>) -> Binding<T> {
        Binding(get: { editor.timeline.output[keyPath: key] },
                set: { value in editor.updateOutputSizing { $0[keyPath: key] = value } })
    }

    private func inspectorPicker<Value: Hashable>(
        _ label: String, selection: Binding<Value>, values: [Value], title: @escaping (Value) -> String
    ) -> some View {
        HStack(spacing: 9) {
            Text(label).frame(width: 82, alignment: .leading)
            InspectorPopup(selection: selection, values: values, titles: values.map(title), label: label)
                .frame(maxWidth: .infinity)
                .frame(height: 25)
                .editorHover()
        }
        .font(.callout)
    }

    private func outputBinding<T>(_ key: WritableKeyPath<OutputSettings, T>) -> Binding<T> {
        Binding(get: { editor.timeline.output[keyPath: key] },
                set: { value in editor.updateTimeline { $0.output[keyPath: key] = value } })
    }

    private func clipBinding<T>(_ clip: Clip, _ key: WritableKeyPath<Clip, T>) -> Binding<T> {
        Binding(get: { editor.timeline.clips.first(where: { $0.id == clip.id })?[keyPath: key] ?? clip[keyPath: key] },
                set: { value in editor.updateClip(clip.id) { $0[keyPath: key] = value } })
    }

    private func timelineArea(layerHeight: CGFloat, viewportWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 5) {
                            ForEach(editor.project.timelines) { timeline in
                                timelineTab(timeline).id(timeline.id)
                            }
                            Button(action: editor.addTimeline) { Image(systemName: "plus") }
                                .help(L10n.text("タイムラインを追加"))
                        }
                    }
                    .scrollIndicators(.hidden)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(TimelineScale.editorSpace)) } action: {
                        timelineTabViewport = $0
                    }
                    .onChange(of: editor.timeline.id) { id in proxy.scrollTo(id) }
                }
                Divider().frame(height: 18)
                timelineActions
            }
            .padding(.horizontal, 13).frame(height: 37).background(surface)
            Divider()
            HStack(spacing: 10) {
                Button(action: editor.split) { Label(L10n.text("分割"), systemImage: "scissors") }
                    .help(L10n.text("再生位置でクリップとレイヤーを分割")).disabled(!editor.canSplit)
                Button(action: editor.deleteSelection) { Label(L10n.text("削除"), systemImage: "trash") }
                    .buttonStyle(HoverColorButtonStyle(color: accent, hoverColor: .red, bordered: true))
                    .help(L10n.text("選択したクリップ・レイヤーを取り除く"))
                    .disabled(!editor.hasTimelineSelection)
                if editor.selectedLayer != nil {
                    layerOrderButton(-1)
                    layerOrderButton(1)
                    Button(action: editor.duplicateLayer) { Label(L10n.text("複製"), systemImage: "plus.square.on.square") }
                        .help(L10n.text("レイヤーを複製"))
                } else {
                    moveButton(-1)
                    moveButton(1)
                }
                Menu {
                    ForEach(LayerKind.allCases.filter { $0 != .image }, id: \.self) { kind in
                        Button { editor.addLayer(kind) } label: {
                            Label { Text(kind.title) } icon: { LayerIcon(kind: kind) }
                        }
                    }
                    Menu {
                        ForEach(editor.librarySources.filter(\.isImage)) { source in
                            Button(source.name) { editor.addLayer(.image, source: source) }
                        }
                        Button(L10n.text("画像ファイルを選ぶ…"), action: editor.chooseLayerImage)
                            .disabled(editor.loadingSources)
                    } label: {
                        LayerLabel(kind: .image, title: L10n.text("画像"))
                    }
                } label: {
                    Label(L10n.text("レイヤーを追加"), systemImage: "square.3.layers.3d")
                }
                .fixedSize()
                .editorHover()
                Spacer()
                Toggle(L10n.text("吸着"), isOn: $snapping)
                    .toggleStyle(.switch).controlSize(.small).editorHoverBrightness()
                    .help(L10n.text("ドラッグ中にクリップや隣のレイヤーの端に吸着"))
                Toggle(L10n.text("音声波形"), isOn: Binding(get: { editor.timeline.showWaveform == true },
                                               set: { show in editor.updateTimeline { $0.showWaveform = show ? true : nil } }))
                    .toggleStyle(.switch).controlSize(.small).editorHoverBrightness()
                    .help(L10n.text("このタイムラインの音声波形を表示"))
                HStack(spacing: 10) {
                    Text(L10n.text("ズーム")).font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(get: {
                        fitTimeline ? TimelineScale(width: viewportWidth).zoomToFit(frames: fittedFrames) : zoom
                    }, set: { value in
                        fitTimeline = false
                        zoom = value
                    }), in: 0...1)
                        .frame(width: 105)
                        .accessibilityLabel(L10n.text("タイムラインのズーム"))
                }
                .editorHoverBrightness()
                Button { fitTimeline = true } label: {
                    Image(systemName: "arrow.left.and.right.square")
                }
                .help(L10n.text("全尺を表示幅に合わせる"))
                .accessibilityLabel(L10n.text("全尺を表示幅に合わせる"))
                .disabled(fittedFrames == 0)
            }
            .padding(.horizontal, 13).frame(height: 38)
            TimelineTrack(editor: editor, zoom: zoom, fittedFrames: fitTimeline ? fittedFrames : nil,
                          snapping: snapping, layerHeight: layerHeight,
                          tabFrames: timelineTabFrames.mapValues { $0.intersection(timelineTabViewport) },
                          tabDropTarget: $timelineDropTarget, dragAvatar: $dragAvatar)
            Spacer(minLength: 0)
        }
    }

    private var fittedFrames: Int {
        editor.totalFrames
    }

    private var timelineActions: some View {
        HStack(spacing: 10) {
            Button { requestTimelineRename(editor.timeline) } label: { Label(L10n.text("名前"), systemImage: "pencil") }
                .help(L10n.text("選択中のタイムライン名を変更"))
                .accessibilityLabel(L10n.text("選択中のタイムライン名を変更"))
            Button { bulkRename = true } label: { Label(L10n.text("複数"), systemImage: "list.bullet") }
                .help(L10n.text("タイムライン名をまとめて変更"))
                .accessibilityLabel(L10n.text("タイムライン名をまとめて変更"))
            Toggle(isOn: Binding(get: { editor.numbersTimelines }, set: { enabled in
                if enabled != editor.numbersTimelines { editor.toggleTimelineNumbers() }
            })) {
                Label(L10n.text("連番"), systemImage: "list.number")
            }
            .toggleStyle(.button)
            .buttonStyle(HoverColorButtonStyle(color: editor.numbersTimelines ? accent : .secondary,
                                              hoverColor: brightAccent))
            .padding(.horizontal, 4)
            .background(accent.opacity(editor.numbersTimelines ? 0.20 : 0), in: RoundedRectangle(cornerRadius: 5))
            .help(L10n.text("タイムライン名と書き出しファイル名に連番を付ける"))
            Button { requestTimelineRemoval(editor.timeline) } label: { Label(L10n.text("削除"), systemImage: "trash") }
                .buttonStyle(HoverColorButtonStyle(color: accent, hoverColor: .red))
                .help(L10n.text("選択中のタイムラインを削除"))
                .disabled(editor.project.timelines.count == 1)
        }
        .buttonStyle(HoverColorButtonStyle(color: accent, hoverColor: brightAccent))
        .fixedSize()
    }

    private func timelineTab(_ timeline: Timeline) -> some View {
        let selected = editor.timeline.id == timeline.id
        let receivingDrop = timelineDropTarget == timeline.id
        return Button { editor.selectTimeline(timeline.id) } label: {
            Text(editor.timelineDisplayName(timeline))
                .lineLimit(1).frame(maxWidth: 145)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(receivingDrop ? Color.orange : selected ? accent.opacity(0.18) : .white.opacity(0.04),
                            in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .editorHover()
        .foregroundStyle(receivingDrop ? .black : selected ? accent : .secondary)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(TimelineScale.editorSpace)) } action: {
            timelineTabFrames[timeline.id] = $0
        }
        .onDisappear { timelineTabFrames[timeline.id] = nil }
        .contextMenu {
            Button(L10n.text("名前を変更…")) { requestTimelineRename(timeline) }
            Button(L10n.text("このタイムラインを書き出す…")) { editor.startExport(all: false, for: timeline.id) }
                .disabled(!timeline.hasContent || editor.exporting)
            Divider()
            Button(L10n.text("タイムラインを削除…"), role: .destructive) { requestTimelineRemoval(timeline) }
                .disabled(editor.project.timelines.count == 1)
        }
        .buttonStyle(.automatic)
    }

    private func requestTimelineRename(_ timeline: Timeline) {
        timelineRenameTarget = timeline.id
        timelineName = timeline.name
        renamingTimeline = true
    }

    private func requestTimelineRemoval(_ timeline: Timeline) {
        timelineRemovalTarget = timeline
        removeTimeline = true
    }

    private func layerOrderButton(_ step: Int) -> some View {
        Button { editor.reorderLayer(by: step) } label: {
            Image(systemName: step > 0 ? "arrow.up" : "arrow.down")
        }
        .help(step > 0 ? L10n.text("レイヤーを前面へ") : L10n.text("レイヤーを背面へ"))
        .disabled(!editor.canReorderLayer(by: step))
    }

    private func moveButton(_ offset: Int) -> some View {
        let clips = editor.timeline.clips
        let selected = clips.indices.filter { editor.selections.contains(.clip(clips[$0].id)) }
        let edge = offset < 0 ? selected.first : selected.last
        return Button {
            guard let edge else { return }
            editor.moveClip(clips[edge].id, to: edge + (offset < 0 ? -1 : 2))
        } label: {
            Image(systemName: offset < 0 ? "arrow.left" : "arrow.right")
        }
        .help(offset < 0 ? L10n.text("クリップを左へ移動") : L10n.text("クリップを右へ移動"))
        .disabled(edge.map { !clips.indices.contains($0 + offset) } ?? true)
    }

    private var exportSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("書き出し")).font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(editor.jobs) { job in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(job.destination.lastPathComponent).fontWeight(.medium)
                                Spacer()
                                Text(job.progress.formatted(.percent.precision(.fractionLength(0))))
                                    .font(.caption.monospacedDigit())
                            }
                            ProgressView(value: job.progress).labelsHidden()
                            Text(job.status.title).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            if let encoder = job.encoder {
                                Text(encoder.title).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 80, idealHeight: 220, maxHeight: 360)
            HStack {
                Button(L10n.text("保存先を表示")) {
                    if let job = editor.jobs.first {
                        NSWorkspace.shared.open(job.destination.deletingLastPathComponent())
                    }
                }
                Spacer()
                if editor.exporting { Button(L10n.text("書き出しを中止"), action: editor.cancelExport) }
                Button(L10n.text("閉じる")) { editor.showingJobs = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 530)
        .buttonStyle(HoverButtonStyle())
    }
}

struct InspectorPopup<Value: Hashable>: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var selection: Value
    let values: [Value]
    let titles: [String]
    let label: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.font = .systemFont(ofSize: 12)
        button.cell?.lineBreakMode = .byTruncatingTail
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.target = context.coordinator
        button.action = #selector(Coordinator.choose(_:))
        return button
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        proposal.width.map { CGSize(width: $0, height: 25) }
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        if button.itemTitles != titles {
            button.removeAllItems()
            button.addItems(withTitles: titles)
        }
        button.selectItem(at: values.firstIndex(of: selection) ?? -1)
        button.isEnabled = isEnabled
        button.setAccessibilityLabel(label)
        context.coordinator.change = { index in
            if values.indices.contains(index) { selection = values[index] }
        }
    }

    final class Coordinator: NSObject {
        var change: ((Int) -> Void)?
        @objc func choose(_ sender: NSPopUpButton) { change?(sender.indexOfSelectedItem) }
    }
}

private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.showsFullScreenToggleButton = false
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}
}

struct SourceThumbnail: View {
    let source: Source
    let missing: Bool
    var frame = 30
    @State private var image: CGImage?

    private struct Request: Equatable {
        let path: String
        let frame: Int
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.34)
            if missing {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            } else if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else {
                Image(systemName: "film").foregroundStyle(accent)
            }
        }
        .frame(width: 52, height: 32)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityHidden(true)
        .task(id: Request(path: source.path, frame: frame)) {
            image = nil
            guard !missing, let loaded = try? await sourceThumbnail(source, frame: frame), !Task.isCancelled else { return }
            image = loaded
        }
    }
}

private struct ExportNamesView: View {
    @AppStorage(AppLanguage.preferenceKey) private var language = AppLanguage.system

    @Environment(\.dismiss) private var dismiss
    @State var plan: Editor.ExportPlan
    let onExport: (Editor.ExportPlan) throws -> Void
    @State private var error: String?

    var body: some View {
        let _ = language

        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("書き出すファイル名")).font(.title2.weight(.semibold))
            Text(plan.folder.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    ForEach(plan.timelines.indices, id: \.self) { index in
                        let timeline = plan.timelines[index]
                        VStack(alignment: .leading, spacing: 4) {
                            Text(timeline.name).font(.caption).foregroundStyle(.secondary)
                            HStack {
                                if !plan.prefixes[index].isEmpty {
                                    Text(plan.prefixes[index])
                                        .monospacedDigit().foregroundStyle(accent)
                                }
                                TextField(L10n.text("ファイル名"), text: $plan.names[index])
                                    .textFieldStyle(.roundedBorder)
                                    .editorHover()
                                    .accessibilityLabel(L10n.format("%@のファイル名", String(describing: timeline.name)))
                                Text(".\(timeline.output.container.rawValue)")
                                    .monospaced().foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .frame(height: min(300, CGFloat(plan.timelines.count) * 56))
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button(L10n.text("キャンセル")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.text("書き出す")) {
                    do { try onExport(plan) }
                    catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 530)
        .buttonStyle(HoverButtonStyle())
    }
}


private struct TimelineNamesView: View {
    @AppStorage(AppLanguage.preferenceKey) private var language = AppLanguage.system

    @Environment(\.dismiss) private var dismiss
    let timelines: [Timeline]
    let apply: ([UUID: String]) -> Void
    @State private var drafts: [UUID: String]

    init(timelines: [Timeline], apply: @escaping ([UUID: String]) -> Void) {
        self.timelines = timelines
        self.apply = apply
        _drafts = State(initialValue: Dictionary(uniqueKeysWithValues: timelines.map { ($0.id, $0.name) }))
    }

    var body: some View {
        let _ = language

        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("タイムライン名をまとめて変更")).font(.title2.weight(.semibold))
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Array(timelines.enumerated()), id: \.element.id) { index, timeline in
                        HStack(spacing: 12) {
                            Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 25)
                            TextField(L10n.text("タイムライン名"), text: Binding(
                                get: { drafts[timeline.id] ?? timeline.name },
                                set: { drafts[timeline.id] = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .editorHover()
                            .accessibilityLabel(L10n.format("タイムライン %@ の名前", String(describing: index + 1)))
                        }
                    }
                }
            }
            .frame(minHeight: 60, idealHeight: min(320, CGFloat(timelines.count) * 38), maxHeight: 320)
            HStack {
                Spacer()
                Button(L10n.text("キャンセル")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.text("変更")) {
                    apply(drafts)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(drafts.values.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            }
        }
        .padding(20)
        .frame(width: 450)
        .buttonStyle(HoverButtonStyle())
    }
}
