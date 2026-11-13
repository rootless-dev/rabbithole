import Foundation
import Observation

/// The two daemon calls about buckets. They take the credentials in the request, so they
/// work during the first-launch setup, before anything is saved.
struct BucketService: Sendable {
    var list: @Sendable (AWSAccess) async throws -> [Bucket]
    var create: @Sendable (AWSAccess, String) async throws -> Void

    init(
        list: @escaping @Sendable (AWSAccess) async throws -> [Bucket],
        create: @escaping @Sendable (AWSAccess, String) async throws -> Void
    ) {
        self.list = list
        self.create = create
    }

    init(client: DaemonClient) {
        self.init(
            list: { try await client.listBuckets($0) },
            create: { try await client.createBucket($0, name: $1) })
    }

    /// For when there is no daemon to ask.
    static let unavailable = BucketService(
        list: { _ in throw DaemonError.unavailable }, create: { _, _ in throw DaemonError.unavailable })
}

/// The bucket selector: the buckets of the account, loaded from the daemon, and whether its
/// menu is open. When the list cannot be loaded the selector falls back to a text field, so
/// a key without permission to list buckets can still be used with a bucket typed by name.
@MainActor
@Observable
final class BucketListModel {
    enum Phase: Equatable, Sendable {
        /// No access key to ask with yet.
        case noAccount
        case loading
        case loaded
        /// Listing failed; carries the words to show.
        case failed(String)
    }

    /// An entry of the open menu.
    enum Entry: Hashable, Sendable {
        case bucket(String)
        case create
        case reload
    }

    static let createTitle = "Create new bucket…"
    static let reloadTitle = "Reload list"

    private(set) var phase: Phase = .noAccount
    private(set) var buckets: [Bucket] = []
    var isOpen = false
    /// The entry under the pointer.
    var highlighted: Entry?

    @ObservationIgnored private let service: BucketService
    @ObservationIgnored private let access: () async -> AWSAccess?
    @ObservationIgnored private let selection: () -> (name: String, region: String)
    @ObservationIgnored private let pick: (Bucket) -> Void
    /// The key and region the list was loaded with. Never the secret.
    @ObservationIgnored private var loadedFor: (keyID: String, region: String)?
    @ObservationIgnored private var generation = 0

    /// - Parameters:
    ///   - access: the credentials and region to ask with; nil when there are none yet.
    ///   - selection: the bucket and region currently chosen in the form around the selector.
    ///   - pick: called with the bucket the user chose or created.
    init(
        service: BucketService,
        access: @escaping () async -> AWSAccess?,
        selection: @escaping () -> (name: String, region: String),
        pick: @escaping (Bucket) -> Void
    ) {
        self.service = service
        self.access = access
        self.selection = selection
        self.pick = pick
    }

    /// The bucket chosen in the form around the selector.
    var selectedName: String { selection().name }

    /// True when the selector offers the list; otherwise the name is typed.
    var offersList: Bool { phase == .loaded || (phase == .loading && !buckets.isEmpty) }

    /// The line under the selector: how many buckets there are, or why there is no list.
    var note: String {
        switch phase {
        case .noAccount: "Connect your AWS account to list its buckets."
        case .loading: "Looking for the buckets in this account…"
        case .loaded: Self.foundNote(buckets.count)
        case .failed(let message): "\(Self.sentence(message)) You can still type the bucket's name."
        }
    }

    static func foundNote(_ count: Int) -> String {
        switch count {
        case 0: "No buckets found in this account."
        case 1: "1 bucket found in this account."
        default: "\(count) buckets found in this account."
        }
    }

    /// The message with a full stop, when it does not end a sentence already.
    static func sentence(_ message: String) -> String {
        guard let last = message.last, !".!?…".contains(last) else { return message }
        return message + "."
    }

    /// Loads the list unless it is already there for the same key and region.
    func loadIfNeeded() async {
        await load(force: false)
    }

    /// "Reload list": asks again.
    func reload() async {
        await load(force: true)
    }

    private func load(force: Bool) async {
        generation += 1
        let mine = generation
        guard let access = await access() else {
            guard mine == generation else { return }
            buckets = []
            loadedFor = nil
            phase = .noAccount
            return
        }
        guard mine == generation else { return }
        let same = loadedFor.map { $0.keyID == access.accessKeyID && $0.region == access.region } ?? false
        if same, !force, phase == .loaded { return }
        if !same { buckets = [] }
        phase = .loading
        do {
            let listed = try await service.list(access)
            guard mine == generation else { return }
            buckets = listed.sorted { $0.name < $1.name }
            loadedFor = (access.accessKeyID, access.region)
            phase = .loaded
        } catch {
            guard mine == generation else { return }
            buckets = []
            loadedFor = nil
            isOpen = false
            phase = .failed(Self.message(forListError: error))
        }
    }

    /// The daemon's own words when it gave any, and plain ones otherwise.
    static func message(forListError error: Error) -> String {
        switch error as? DaemonError {
        case .rejected(let message) where !message.isEmpty: message
        case .invalidArgument(let message) where !message.isEmpty: message
        case .unavailable: "Uploads are unavailable right now"
        default: "The buckets could not be listed"
        }
    }

    // MARK: The menu

    func toggle() {
        isOpen.toggle()
        highlighted = nil
    }

    func close() {
        isOpen = false
        highlighted = nil
    }

    /// A bucket of the list was clicked. One in another region brings its region along:
    /// the daemon has to reach the bucket where it lives.
    func choose(_ bucket: Bucket) {
        close()
        pick(bucket)
    }

    /// The model of the "Create a new bucket" window. `close` is called when the window
    /// should go away; a bucket that was created is already in the list and chosen by then.
    func makeCreateModel(close: @escaping () -> Void) -> CreateBucketModel {
        self.close()
        let region = selection().region
        return CreateBucketModel(
            region: region.isEmpty ? "us-east-1" : region, service: service, access: access
        ) { [weak self] created in
            if let created, let self {
                if !self.buckets.contains(where: { $0.name == created.name }) {
                    self.buckets = (self.buckets + [created]).sorted { $0.name < $1.name }
                }
                self.pick(created)
            }
            close()
        }
    }
}

/// The state of the "Create a new bucket" window: what was typed, whether the daemon is
/// working on it, and what went wrong the last time. A failure keeps the window open.
@MainActor
@Observable
final class CreateBucketModel: Identifiable {
    static let nameHint = "Lowercase letters, numbers and hyphens. Unique in all of AWS."
    /// Shown in the box when the daemon gave no words of its own.
    static let genericFailure = "The bucket could not be created"

    /// Where a failure is shown: a problem with the name under the name field, any other
    /// in the box above the buttons.
    enum Failure: Equatable, Sendable {
        case name(String)
        case box(String)
    }

    var name = "" {
        didSet {
            // What was wrong with the old name says nothing about the new one.
            if name != oldValue, case .name = failure { failure = nil }
        }
    }
    var region: String
    private(set) var isWorking = false
    private(set) var failure: Failure?

    @ObservationIgnored private let service: BucketService
    @ObservationIgnored private let access: () async -> AWSAccess?
    @ObservationIgnored private let close: (Bucket?) -> Void

    /// `close` is called with the bucket after the daemon created it, and with nil on Cancel.
    init(
        region: String, service: BucketService, access: @escaping () async -> AWSAccess?,
        close: @escaping (Bucket?) -> Void
    ) {
        self.region = region
        self.service = service
        self.access = access
        self.close = close
    }

    var nameError: String? {
        if case .name(let message) = failure { return message }
        return nil
    }

    var boxError: String? {
        if case .box(let message) = failure { return message }
        return nil
    }

    func cancel() {
        guard !isWorking else { return }
        close(nil)
    }

    /// "Create and use". Asks the daemon once: a second click while it works does nothing.
    func confirm() async {
        guard !isWorking else { return }
        isWorking = true
        failure = nil
        defer { isWorking = false }
        guard var access = await access() else {
            failure = .box("Connect your AWS account first.")
            return
        }
        access.region = region
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await service.create(access, wanted)
        } catch {
            failure = Self.failure(for: error)
            return
        }
        isWorking = false
        close(Bucket(name: wanted, region: region))
    }

    /// Places a failure by the kind of error the daemon answered with. Its message is shown
    /// as received.
    static func failure(for error: Error) -> Failure {
        switch error as? DaemonError {
        case .alreadyExists(let message) where !message.isEmpty: .name(message)
        case .invalidArgument(let message) where !message.isEmpty: .name(message)
        case .rejected(let message) where !message.isEmpty: .box(message)
        case .unavailable: .box("Uploads are unavailable right now. Try again in a moment.")
        default: .box(genericFailure)
        }
    }
}

extension AWSRegion {
    /// The region as AWS names it: "South America (São Paulo)".
    var longTitle: String {
        guard let area = Self.areas.first(where: { code.hasPrefix($0.prefix) })?.name else { return title }
        // "Canada (Central)": the one region whose place is the area itself.
        return area == place ? "\(area) (Central)" : "\(area) (\(place))"
    }

    private static let areas: [(prefix: String, name: String)] = [
        ("us-east-", "US East"), ("us-west-", "US West"), ("ca-", "Canada"), ("sa-", "South America"),
        ("eu-", "Europe"), ("ap-", "Asia Pacific"), ("me-", "Middle East"), ("af-", "Africa"),
    ]
}
