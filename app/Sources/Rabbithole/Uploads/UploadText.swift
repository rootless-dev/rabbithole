import Foundation
import UniformTypeIdentifiers

/// The words and numbers shown for uploads, as written in the approved mockups.
enum UploadText {
    enum Tone: Equatable, Sendable { case normal, ok, warn, bad }

    struct Line: Equatable, Sendable {
        let text: String
        let tone: Tone
    }

    // MARK: Sizes and speeds

    /// "184 KB", "2.1 MB", "800 MB", "1.9 GB": decimal units, one decimal below 100 from MB up.
    static func bytes(_ count: Int64) -> String {
        let value = Double(max(count, 0))
        if value < 1000 { return count == 1 ? "1 byte" : "\(max(count, 0)) bytes" }
        if value < 999_500 { return "\(Int((value / 1000).rounded())) KB" }
        for (unit, size) in [("MB", 1e6), ("GB", 1e9), ("TB", 1e12)] {
            let scaled = value / size
            if scaled < 999.5 || unit == "TB" {
                return scaled < 99.95
                    ? String(format: "%.1f %@", scaled, unit)
                    : "\(Int(scaled.rounded())) \(unit)"
            }
        }
        return "\(count) bytes"
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        "\(bytes(Int64(bytesPerSecond.rounded())))/s"
    }

    /// "about 3 min", rounded up so the estimate is not optimistic.
    static func timeLeft(seconds: Double) -> String {
        if seconds < 60 { return "less than a minute" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "about \(minutes) min" }
        return "about \(Int((Double(minutes) / 60).rounded(.up))) h"
    }

    // MARK: Progress lines

    /// The line under an upload's name in the Overview list and in the detail header.
    static func progressLine(_ record: UploadRecord) -> Line {
        switch record.state {
        case .queued:
            return Line(text: "Waiting, \(bytes(record.bytesTotal)) to send", tone: .normal)
        case .uploading:
            var text =
                "\(bytes(record.bytesSent)) of \(bytes(record.bytesTotal)) sent, \(bytes(record.bytesLeft)) left"
            if let seconds = record.secondsLeft { text += ", \(timeLeft(seconds: seconds))" }
            return Line(text: text, tone: .normal)
        case .finished:
            return Line(text: "Finished, \(bytes(record.bytesTotal)) sent", tone: .ok)
        case .failed:
            return Line(text: "Failed, \(reason(record.errorMessage))", tone: .bad)
        }
    }

    /// The line for an upload that failed because of the condition a banner is announcing:
    /// it says how far it got, in the banner's color.
    static func stoppedLine(_ record: UploadRecord, condition: ServiceCondition) -> Line {
        let progress = "Stopped at \(bytes(record.bytesSent)) of \(bytes(record.bytesTotal))"
        switch condition {
        case .offline: return Line(text: "\(progress), no internet connection", tone: .warn)
        case .keyRejected: return Line(text: "\(progress), access key rejected", tone: .bad)
        case .none: return progressLine(record)
        }
    }

    /// The same line for History, where ended uploads also say when they ended.
    static func historyLine(_ record: UploadRecord, now: Date, calendar: Calendar = .current) -> Line {
        guard let endedAt = record.endedAt else { return progressLine(record) }
        let when = dayAndTime(endedAt, now: now, calendar: calendar)
        switch record.state {
        case .finished:
            return Line(text: "Finished \(when), \(bytes(record.bytesTotal)) sent", tone: .ok)
        case .failed:
            return Line(text: "Failed \(when), \(reason(record.errorMessage))", tone: .bad)
        case .queued, .uploading:
            return progressLine(record)
        }
    }

    /// The short status at the right of a file row in the upload detail.
    static func fileLine(_ record: UploadRecord) -> Line {
        switch record.state {
        case .queued: Line(text: "Waiting, \(bytes(record.bytesTotal))", tone: .normal)
        case .uploading:
            Line(text: "\(bytes(record.bytesSent)) of \(bytes(record.bytesTotal))", tone: .normal)
        case .finished: Line(text: "Finished, \(bytes(record.bytesTotal))", tone: .ok)
        case .failed: Line(text: "Failed, \(reason(record.errorMessage))", tone: .bad)
        }
    }

    /// A daemon message placed after a comma: "No internet connection" reads
    /// "no internet connection", while "AWS rejected…" keeps its capitals.
    static func reason(_ message: String) -> String {
        let text = message.isEmpty ? "Upload failed" : message
        let characters = Array(text)
        guard characters.count > 1, characters[0].isUppercase, characters[1].isLowercase else {
            return text
        }
        return characters[0].lowercased() + String(characters.dropFirst())
    }

    // MARK: Dates

    /// "today at 11:56", "yesterday at 18:20", "on Tuesday at 09:14", "on 3 Nov at 15:02".
    static func dayAndTime(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        "\(day(date, now: now, calendar: calendar, inSentence: true)) at \(time(date, calendar: calendar))"
    }

    /// "Today, 11:52" for the detail's Started fact.
    static func started(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        "\(day(date, now: now, calendar: calendar, inSentence: false)), \(time(date, calendar: calendar))"
    }

    /// "Thu 12:58", as a menu bar clock writes it.
    static func menuBarClock(_ date: Date, calendar: Calendar = .current) -> String {
        formatted(date, "EEE HH:mm", calendar: calendar)
    }

    /// "2m", "1h", "Tue": the age shown beside a recent upload in the tray.
    static func shortAge(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let seconds = max(now.timeIntervalSince(date), 0)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        return formatted(date, "EEE", calendar: calendar)
    }

    /// "2 minutes ago" for the Overview card.
    static func longAge(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let seconds = max(now.timeIntervalSince(date), 0)
        if seconds < 60 { return "Just now" }
        if seconds < 3600 {
            let minutes = Int(seconds / 60)
            return minutes == 1 ? "1 minute ago" : "\(minutes) minutes ago"
        }
        if seconds < 86_400 {
            let hours = Int(seconds / 3600)
            return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
        }
        let days = Int(seconds / 86_400)
        return days == 1 ? "Yesterday" : "\(days) days ago"
    }

    private static func day(_ date: Date, now: Date, calendar: Calendar, inSentence: Bool) -> String {
        let from = calendar.startOfDay(for: date)
        let to = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: from, to: to).day ?? 0
        switch days {
        case ...0: return inSentence ? "today" : "Today"
        case 1: return inSentence ? "yesterday" : "Yesterday"
        case 2...6:
            let weekday = formatted(date, "EEEE", calendar: calendar)
            return inSentence ? "on \(weekday)" : weekday
        default:
            let dayMonth = formatted(date, "d MMM", calendar: calendar)
            return inSentence ? "on \(dayMonth)" : dayMonth
        }
    }

    private static func time(_ date: Date, calendar: Calendar) -> String {
        formatted(date, "HH:mm", calendar: calendar)
    }

    private static func formatted(_ date: Date, _ format: String, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    // MARK: Paths

    /// The path with the home folder written as "~".
    static func displayPath(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// Where the upload lands in the bucket: the resolved key, or the folder and name before
    /// the daemon has resolved one.
    static func destination(_ record: UploadRecord, prefix: String) -> String {
        record.objectKey.isEmpty ? prefix + record.fileName : record.objectKey
    }
}

/// The file types History can filter by.
enum FileKind: String, CaseIterable, Sendable {
    case documents, images, videos, audio, archives, folders, other

    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    private static let archiveExtensions: Set<String> = [
        "zip", "gz", "tgz", "tar", "bz2", "xz", "7z", "rar", "zst", "dmg", "iso",
    ]

    /// The kind of a file, judged by its name only. The engine uploads single files, so
    /// nothing is classified as a folder yet.
    static func of(fileName: String) -> FileKind {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return .other }
        if archiveExtensions.contains(ext) { return .archives }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .image) { return .images }
        if type.conforms(to: .audiovisualContent) && !type.conforms(to: .audio) { return .videos }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .archive) { return .archives }
        let documentTypes: [UTType] = [.text, .pdf, .presentation, .spreadsheet, .compositeContent]
        if documentTypes.contains(where: { type.conforms(to: $0) }) { return .documents }
        return .other
    }
}
