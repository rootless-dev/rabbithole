import SwiftUI

/// History: a search field, state filters with counts, file type chips and the list, in the
/// same row style as Overview. It lists the history the daemon keeps, earlier runs included.
struct HistoryView: View {
    let context: MainContext

    var body: some View {
        @Bindable var model = context.model
        let all = context.uploads.ordered
        let query = model.historyQuery
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Text("History").font(.system(size: 19, weight: .semibold))
                SearchField(text: $model.historyQuery.text)
            }
            .padding(.bottom, 12)

            FilterTabs(
                tabs: UploadStateFilter.allCases.map {
                    .init(value: $0, title: $0.title, count: query.count($0, in: all))
                },
                selection: $model.historyQuery.state
            )
            .padding(.bottom, 8)

            HStack(spacing: 6) {
                ForEach(FileKind.allCases, id: \.self) { kind in
                    FilterChip(title: kind.title, isOn: query.kinds.contains(kind)) {
                        if !model.historyQuery.kinds.insert(kind).inserted {
                            model.historyQuery.kinds.remove(kind)
                        }
                    }
                }
            }
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }

            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                UploadList(
                    records: query.apply(to: all), topPadding: 12, menus: model,
                    line: { UploadText.historyLine($0, now: timeline.date) },
                    open: { model.openDetail(id: $0.id, from: .history) },
                    empty: {
                        if all.isEmpty {
                            EmptyState(
                                title: "No uploads yet",
                                text: "Drop a file or folder on the Rabbithole icon in the menu bar, or pick one here.",
                                actionTitle: "Choose file", primary: true,
                                action: context.actions.chooseFile
                            )
                            .disabled(!context.tray.acceptsUploads)
                        } else {
                            EmptyState(
                                title: query.emptyTitle,
                                text: "Check the spelling, or search across every state and file type.",
                                actionTitle: "Clear search and filters",
                                action: { model.historyQuery.clear() })
                        }
                    })
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
    }
}

private struct SearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.muted)
            TextField(
                "", text: $text,
                prompt: Text("Search uploads by name or folder").foregroundStyle(Theme.muted)
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused($focused)
        }
        .fieldBox(focused: focused)
    }
}

// MARK: - Upload detail

/// What opens when an upload row is clicked: the large thumbnail in its ring, the facts and
/// the files of the upload with straight progress lines.
struct UploadDetailView: View {
    let context: MainContext
    let record: UploadRecord
    let origin: MainSection

    var body: some View {
        @Bindable var model = context.model
        VStack(alignment: .leading, spacing: 0) {
            Button("‹ \(origin.title)") { model.closeDetail() }
                .buttonStyle(LinkButtonStyle())

            HStack(alignment: .center, spacing: 18) {
                ProgressRing(
                    fraction: record.ringFraction, color: record.ringColor, size: 92, hole: 84,
                    holeColor: Theme.main
                ) {
                    UploadThumbnail(record: record, side: 50)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(UploadText.name(record))
                        .font(.system(size: 19, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(UploadText.location(record))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .padding(.top, 3)
                    TimelineView(.periodic(from: .now, by: 60)) { timeline in
                        // An ended upload also says when it ended, as History does.
                        let headline = UploadText.historyLine(record, now: timeline.date)
                        Text(headline.text)
                            .monospacedDigit()
                            .foregroundStyle(headline.tone == .normal ? Theme.ink : headline.tone.color)
                            .lineLimit(1)
                            .padding(.top, 8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                actionButtons
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 16)
            .padding(.bottom, 4)

            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                HStack(alignment: .top, spacing: 14) {
                    Fact(label: "Files", value: UploadText.filesSent(record))
                    // A finished upload says how long it took and where it went; until then
                    // the same places hold the speed and where it is going.
                    if record.state == .finished, let duration = record.duration {
                        Fact(label: "Took", value: UploadText.took(seconds: duration))
                    } else {
                        Fact(label: "Speed", value: record.bytesPerSecond.map(UploadText.speed) ?? "–")
                    }
                    Fact(label: "Started", value: UploadText.started(record.startedAt, now: timeline.date))
                    Fact(
                        label: record.state == .finished ? "Went to" : "Goes to",
                        value: UploadText.destination(
                            record, prefix: context.account.summary.destination.uploadsPrefix))
                }
                .padding(.vertical, 12)
                .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
                .padding(.top, 14)
            }

            // Once the upload has ended nothing is being sent or waiting, so those two tabs
            // go away, and a filter left on one of them shows every file.
            let filter = Self.fileFilter(model.detailFilter, for: record)
            ListBand(title: "Files in this upload", topPadding: 12) {
                FilterTabs(
                    tabs: Self.fileTabs(for: record),
                    selection: Binding(get: { filter }, set: { model.detailFilter = $0 }))
            }

            UploadFileRows(
                files: model.detailFiles, filter: filter,
                hiddenPrefix: UploadText.hiddenFilePrefix(record),
                standIn: record.kind == .singleFile ? FileSnapshot(standingFor: record) : nil,
                menus: model
            )
            .equatable()
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    /// The state tabs over the files: all five while the upload runs, and without Sending
    /// and Waiting once it has ended.
    static func fileTabs(for record: UploadRecord) -> [FilterTabs<UploadStateFilter>.Tab] {
        let running: [FilterTabs<UploadStateFilter>.Tab] =
            record.isActive ? [.init(value: .inProgress, title: "Sending"), .init(value: .waiting, title: "Waiting")] : []
        return [.init(value: .all, title: "All")] + running
            + [.init(value: .finished, title: "Finished"), .init(value: .failed, title: "Failed")]
    }

    /// The filter in effect: one of the tabs that are shown.
    static func fileFilter(_ chosen: UploadStateFilter, for record: UploadRecord) -> UploadStateFilter {
        fileTabs(for: record).contains { $0.value == chosen } ? chosen : .all
    }

    /// Pausing and cancelling are designed but the engine cannot do them yet, so the buttons
    /// are shown disabled while an upload runs. Once it has ended, the three dots open what
    /// can be done with it.
    @ViewBuilder private var actionButtons: some View {
        let style = BoxButtonStyle(horizontal: 13, vertical: 5, radius: 7, fontSize: 12.5)
        HStack(spacing: 8) {
            switch record.state {
            case .queued, .uploading:
                Button("Pause") {}
                    .buttonStyle(style)
                    .disabled(true)
                    .help("Pausing is not available yet")
                Button("Cancel upload") {}
                    .buttonStyle(BoxButtonStyle(kind: .danger, horizontal: 13, vertical: 5, radius: 7, fontSize: 12.5))
                    .disabled(true)
                    .help("Cancelling is not available yet")
            case .failed, .finished:
                MoreButton(
                    target: .upload(id: record.id), actions: UploadAction.available(for: record),
                    menus: context.model, boxed: true)
            }
        }
    }
}

private struct Fact: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11.5)).foregroundStyle(Theme.muted)
            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The scrolling list of an upload's files under the state tabs. It is rebuilt only when
/// one of the values compared below changes or when a file appears or changes state, not on
/// every progress report of the upload around it; rows are made as they scroll into view.
private struct UploadFileRows: View, Equatable {
    let files: UploadFilesModel
    let filter: UploadStateFilter
    /// The start of every file's path that the header already shows.
    let hiddenPrefix: String
    /// The one file of a single-file upload, drawn from the upload itself until the files
    /// stream delivers it (or when the daemon no longer knows the upload).
    let standIn: FileSnapshot?
    /// Where the rows' actions menus open.
    let menus: MainWindowModel

    nonisolated static func == (lhs: UploadFileRows, rhs: UploadFileRows) -> Bool {
        lhs.files === rhs.files && lhs.filter == rhs.filter && lhs.hiddenPrefix == rhs.hiddenPrefix
            && lhs.standIn == rhs.standIn && lhs.menus === rhs.menus
    }

    var body: some View {
        let indexes = files.indexes(filter)
        if files.count > 0 {
            if indexes.isEmpty {
                note("No files in this state.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(indexes, id: \.self) { index in
                            LiveFileRow(files: files, index: index, hiddenPrefix: hiddenPrefix, menus: menus)
                        }
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 12)
                    .padding(.trailing, 14)
                }
            }
        } else if let standIn {
            if filter.includes(standIn.state) {
                FileRow(file: standIn, name: standIn.relativePath, menus: menus)
                    .padding(.top, 4)
                    .padding(.trailing, 14)
                Spacer(minLength: 0)
            } else {
                note("No files in this state.")
            }
        } else if files.phase == .unavailable {
            note("The list of files is no longer available for this upload.")
        } else {
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.muted)
            .padding(.top, 16)
            .frame(maxWidth: .infinity)
        Spacer(minLength: 0)
    }
}

extension FileSnapshot {
    /// The only file of a single-file upload, as far as the upload itself tells.
    init(standingFor record: UploadRecord) {
        self.init(
            uploadID: record.id, index: 0, relativePath: record.fileName, localPath: record.localPath,
            objectKey: record.objectKey, bytesTotal: record.bytesTotal, bytesSent: record.bytesSent,
            state: record.state, errorMessage: record.errorMessage)
    }

    /// Progress from 0 to 1 for the row's line. A failed file keeps how far it got, as the
    /// mockup draws it; a finished one is always full, including an empty file.
    var barFraction: Double {
        if state == .finished { return 1 }
        guard bytesTotal > 0 else { return 0 }
        return min(max(Double(bytesSent) / Double(bytesTotal), 0), 1)
    }
}

/// A row of the lazy list: it looks its file up when drawn, so progress redraws only the
/// rows on screen.
private struct LiveFileRow: View {
    let files: UploadFilesModel
    let index: Int
    let hiddenPrefix: String
    let menus: MainWindowModel

    var body: some View {
        if let file = files.file(at: index) {
            FileRow(file: file, name: UploadText.fileName(file, hiding: hiddenPrefix), menus: menus)
        }
    }
}

/// One file of an upload: a plain thumbnail, the name, a short status, a thin line and,
/// once the file has ended, the three dots that open its actions.
private struct FileRow: View {
    let file: FileSnapshot
    let name: String
    let menus: MainWindowModel
    @State private var hovered = false

    var body: some View {
        let line = UploadText.fileLine(file)
        let target = UploadActionTarget.file(uploadID: file.uploadID, index: file.index)
        let actions = UploadAction.available(for: file)
        let menuIsOpen = menus.actionsMenu?.target == target
        HStack(spacing: 12) {
            ThumbnailView(path: file.localPath, fileName: name, side: 26)
                .frame(width: 30, height: 26)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(line.text)
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(line.tone.color)
                        .lineLimit(1)
                }
                ThinBar(fraction: file.barFraction, color: file.state.color)
            }
            MoreButton(target: target, actions: actions, menus: menus)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 7)
        // The rule under the row takes its own point, as the mockup's border does.
        .padding(.bottom, 1)
        .background(hovered || menuIsOpen ? Theme.hover : .clear)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .contentShape(.rect)
        .onHover { hovered = $0 }
        .background {
            if !actions.isEmpty {
                SecondaryClickArea { menus.openActionsMenu(for: target, actions: actions, at: $0) }
            }
        }
    }
}
