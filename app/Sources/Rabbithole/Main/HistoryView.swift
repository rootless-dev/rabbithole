import SwiftUI

/// History: a search field, state filters with counts, file type chips and the list, in the
/// same row style as Overview. It lists the uploads of this run of the app.
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
                    records: query.apply(to: all), topPadding: 12,
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
                    ThumbnailView(path: record.localPath, fileName: record.fileName, side: 50)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(record.fileName)
                        .font(.system(size: 19, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(UploadText.displayPath(record.localPath))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .padding(.top, 3)
                    Text(headline.text)
                        .monospacedDigit()
                        .foregroundStyle(headline.tone == .normal ? Theme.ink : headline.tone.color)
                        .lineLimit(1)
                        .padding(.top, 8)
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
                    Fact(label: "Files", value: record.state == .finished ? "1 of 1 sent" : "0 of 1 sent")
                    Fact(label: "Speed", value: record.bytesPerSecond.map(UploadText.speed) ?? "–")
                    Fact(label: "Started", value: UploadText.started(record.startedAt, now: timeline.date))
                    Fact(
                        label: "Goes to",
                        value: UploadText.destination(
                            record, prefix: context.account.summary.destination.uploadsPrefix))
                }
                .padding(.vertical, 12)
                .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
                .padding(.top, 14)
            }

            ListBand(title: "Files in this upload", topPadding: 12) {
                FilterTabs(
                    tabs: [
                        .init(value: UploadStateFilter.all, title: "All"),
                        .init(value: .inProgress, title: "Sending"),
                        .init(value: .waiting, title: "Waiting"),
                        .init(value: .finished, title: "Finished"),
                        .init(value: .failed, title: "Failed"),
                    ],
                    selection: $model.detailFilter)
            }

            let files = UploadQuery(state: model.detailFilter).apply(to: [record])
            if files.isEmpty {
                Text("No files in this state.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 16)
                    .frame(maxWidth: .infinity)
            }
            ForEach(files) { file in
                FileRow(record: file, retry: { context.actions.retry([file]) })
            }
            .padding(.top, 4)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    private var headline: UploadText.Line { UploadText.progressLine(record) }

    /// Pausing and cancelling are designed but the engine cannot do them yet, so the buttons
    /// are shown disabled while an upload runs. A failed upload can really be sent again.
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
            case .failed:
                Button("Try again") { context.actions.retry([record]) }
                    .buttonStyle(style)
            case .finished:
                EmptyView()
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
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One file of an upload: a plain thumbnail, the name, a short status and a thin line.
private struct FileRow: View {
    let record: UploadRecord
    let retry: () -> Void

    var body: some View {
        let line = UploadText.fileLine(record)
        HStack(spacing: 12) {
            ThumbnailView(path: record.localPath, fileName: record.fileName, side: 26)
                .frame(width: 30, height: 26)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(record.fileName)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(line.text)
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(line.tone.color)
                        .lineLimit(1)
                    if record.state == .failed {
                        Button("Try again", action: retry)
                            .buttonStyle(LinkButtonStyle(fontSize: 12))
                    }
                }
                ThinBar(fraction: record.ringFraction, color: record.ringColor)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}
