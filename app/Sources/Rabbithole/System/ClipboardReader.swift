import AppKit

/// Turns what is on the clipboard into files that can be uploaded.
///
/// Files and folders copied in Finder are used as they are. An image (a screenshot sent to
/// the clipboard, a picture copied in a browser) or a piece of text is not a file, so it is
/// first saved as one, in a folder of its own inside the app's support folder: the upload
/// needs the file to stay there until it ends, and to send it again if it fails.
enum ClipboardReader {
    enum Failure: Error, Equatable {
        /// The clipboard holds nothing that can be uploaded.
        case empty
        /// The image or text could not be saved to a file.
        case notSaved
    }

    /// Saved clipboard files older than this are removed by `prune`.
    static let keepFor: TimeInterval = 7 * 24 * 60 * 60

    /// The files to upload for what is on `pasteboard` now. Copied files win over an image,
    /// and an image over text, because copying a file also puts its name on the clipboard
    /// as text and often its icon as an image.
    static func files(from pasteboard: NSPasteboard, savingIn directory: URL, now: Date) throws -> [URL] {
        let copied = copiedFiles(pasteboard)
        if !copied.isEmpty { return copied }
        if let png = imageData(pasteboard) {
            return [try save(png, as: "png", in: directory, now: now)]
        }
        if let text = pasteboard.string(forType: .string),
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return [try save(Data(text.utf8), as: "txt", in: directory, now: now)]
        }
        throw Failure.empty
    }

    /// Removes saved clipboard files last changed more than `keepFor` ago. A file that an
    /// upload still needs is far younger than that.
    static func prune(_ directory: URL, now: Date) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            let changed = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let changed, now.timeIntervalSince(changed) > keepFor {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// The name of a saved clipboard file, in the style macOS gives screenshots.
    static func fileName(extension ext: String, now: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        return String(
            format: "Clipboard %04d-%02d-%02d at %02d.%02d.%02d.%@",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0, ext)
    }

    private static func copiedFiles(_ pasteboard: NSPasteboard) -> [URL] {
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return (objects as? [URL]) ?? []
    }

    /// The clipboard's image as PNG data: PNG as it is, anything else AppKit can read converted.
    private static func imageData(_ pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard let tiff = pasteboard.data(forType: .tiff), let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func save(_ data: Data, as ext: String, in directory: URL, now: Date) throws -> URL {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = freeURL(in: directory, named: fileName(extension: ext, now: now))
            try data.write(to: url, options: .withoutOverwriting)
            return url
        } catch {
            throw Failure.notSaved
        }
    }

    /// `name` in `directory`, or the first "name 2", "name 3" that is not taken: two copies
    /// sent within the same second must not land on one file.
    private static func freeURL(in directory: URL, named name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var url = directory.appending(path: name, directoryHint: .notDirectory)
        var attempt = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appending(path: "\(base) \(attempt).\(ext)", directoryHint: .notDirectory)
            attempt += 1
        }
        return url
    }
}
