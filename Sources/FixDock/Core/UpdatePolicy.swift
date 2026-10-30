// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Foundation

/// Every decision self-update makes, as pure functions over plain values.
/// Foundation only and no other FixDock type, so a harness compiles this file
/// on its own. The shell (UpdateService, UpdateTransport, UpdateVerifier,
/// UpdateWorkspace, Relauncher) gathers facts, calls these, and acts.
enum UpdatePolicy {
    static let maxFeedBytes = 1 << 20
    static let maxArchiveBytes: Int64 = 64 << 20
    static let maxExpandedBytes: Int64 = 512 << 20
    static let maxArchiveEntries = 5_000
    static let maxNotesCharacters = 20_000
    static let firstCheckDelay: TimeInterval = 6
    static let automaticInterval: TimeInterval = 60 * 60
    static let staleAfter: TimeInterval = 15 * 60
    /// The helper gives the app this long to exit, then gives up untouched.
    static let quitDeadline: TimeInterval = 20
    /// The new version must confirm within this long. After it, a version
    /// that is not running is rolled back; one that is running is left alone.
    static let launchConfirmDeadline: TimeInterval = 60
    /// An attempt older than this cannot have a live helper. A record dated
    /// more than this in the future is stale too, so a clock set back cannot
    /// keep an attempt waiting for a helper forever.
    static let attemptLifetime: TimeInterval = 5 * 60
    /// Tools/notarize.sh output.
    static let releaseBundleName = "FixDock.app"
    static let releaseExecutableName = "FixDock"

    // MARK: Feed -> offer

    /// GitHub's `releases/latest` answer as a domain outcome. A newer tag that
    /// fails an asset rule is `.releaseIncomplete`, never an offer, and the
    /// archive URL must be the one `location` derives, so the feed cannot point
    /// the download anywhere else.
    static func evaluateFeed(_ response: FeedResponse, running: SemanticVersion,
                             location: ReleaseLocation) -> FeedOutcome {
        switch response.status {
        case 200: break
        case 403, 429: return .failed(.rateLimited(until: response.retryAfter))
        case 404: return .upToDate
        default: return .failed(.server(response.status))
        }
        guard response.body.count <= maxFeedBytes,
              let wire = try? JSONDecoder().decode(WireRelease.self, from: response.body)
        else { return .failed(.unreadable) }
        guard !wire.draft, !wire.prerelease, let version = SemanticVersion(tag: wire.tag_name),
              version > running
        else { return .upToDate }

        let matches = wire.assets.filter { $0.name == "FixDock-\(version).zip" }
        guard matches.count == 1, let asset = matches.first, asset.state == "uploaded",
              asset.browser_download_url == location.archiveURL(for: version).absoluteString,
              (1...maxArchiveBytes).contains(asset.size),
              let digest = asset.digest.flatMap(ArchiveDigest.init(github:)),
              let page = URL(string: wire.html_url), location.isReleasePage(page)
        else { return .failed(.releaseIncomplete(version)) }

        return .offer(UpdateOffer(version: version,
                                  archiveURL: location.archiveURL(for: version),
                                  archiveSize: asset.size,
                                  archiveDigest: digest,
                                  notes: String((wire.body ?? "").prefix(maxNotesCharacters)),
                                  releasePage: page))
    }

    // MARK: Can this copy update itself?

    /// Identity first, so a developer, ad-hoc or foreign build makes no request
    /// at all; then location, where a release is still worth mentioning.
    static func mode(for facts: BuildFacts, expected: ExpectedIdentity) -> UpdateMode {
        guard facts.bundleID == expected.bundleID else { return .inert(.developerBuild) }
        guard let team = facts.teamID, facts.isDeveloperIDApplication
        else { return .inert(.notDeveloperIDSigned) }
        guard team == expected.teamID else { return .inert(.foreignTeam) }
        if facts.bundlePath.contains("/AppTranslocation/") { return .notifyOnly(.translocated) }
        guard facts.parentPath == expected.installFolder else { return .notifyOnly(.outsideApplications) }
        guard facts.canWriteParent, facts.canWriteBundle else { return .notifyOnly(.notWritable) }
        guard facts.sharesVolumeWithWorkspace else { return .notifyOnly(.otherVolume) }
        return .inPlace
    }

    // MARK: Archive listing (before ditto runs)

    /// Parses `zipinfo -s` output. The header lines ("Archive:", "Zip file
    /// size:") and the closing totals line are skipped; any other line that
    /// does not parse makes the whole listing nil, because an unknown format is
    /// a rejection.
    static func parseZipListing(_ zipinfoShort: String) -> [ArchiveEntry]? {
        var entries: [ArchiveEntry] = []
        for line in zipinfoShort.split(separator: "\n", omittingEmptySubsequences: true) {
            let text = String(line)
            if text.hasPrefix("Archive:") || text.hasPrefix("Zip file size:") { continue }
            if text.range(of: #"^\d+ files?, "#, options: .regularExpression) != nil { continue }
            guard let entry = parseZipLine(text) else { return nil }
            entries.append(entry)
        }
        return entries
    }

    /// "-rw-r--r--  2.1 unx  1777 bX defN 26-Oct-30 11:16 FixDock.app/Contents/Info.plist":
    /// eight fields, then the name, which may contain spaces.
    private static func parseZipLine(_ line: String) -> ArchiveEntry? {
        var fields: [Substring] = []
        var rest = Substring(line)
        for _ in 0..<8 {
            rest = rest.drop { $0 == " " }
            guard let end = rest.firstIndex(of: " ") else { return nil }
            fields.append(rest[..<end])
            rest = rest[end...]
        }
        guard rest.first == " " else { return nil }
        let name = String(rest.dropFirst())
        guard fields[0].count == 10, let size = Int64(fields[3]), size >= 0, !name.isEmpty
        else { return nil }
        let kind: ArchiveEntry.Kind
        switch fields[0].first {
        case "-": kind = .file
        case "d": kind = .directory
        case "l": kind = .symlink
        default: kind = .other
        }
        return ArchiveEntry(path: name, uncompressedSize: size, kind: kind)
    }

    /// Exactly one top-level "FixDock.app/" tree holding Contents/Info.plist and
    /// Contents/MacOS/FixDock. No symlinks (the release has none, and this
    /// closes zip-slip through a link), no "..", ".", empty, absolute or
    /// backslash paths, bounded in count and expanded size. AppleDouble "._x"
    /// entries are fine: `ditto -x -k` folds them back into extended attributes.
    static func checkArchive(_ entries: [ArchiveEntry]) throws {
        guard !entries.isEmpty, entries.count <= maxArchiveEntries
        else { throw InstallFailure.archiveRejected("entry count") }
        var total: Int64 = 0
        var files = Set<String>()
        let root = releaseBundleName
        for entry in entries {
            switch entry.kind {
            case .file, .directory: break
            case .symlink, .other: throw InstallFailure.archiveRejected("link or special file")
            }
            let path = entry.path
            guard !path.hasPrefix("/"), !path.contains("\\")
            else { throw InstallFailure.archiveRejected("path") }
            var parts = path.split(separator: "/", omittingEmptySubsequences: false)
            if entry.kind == .directory, parts.last == "" { parts.removeLast() }
            guard parts.first.map(String.init) == root,
                  !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
            else { throw InstallFailure.archiveRejected("path") }
            total += entry.uncompressedSize
            guard total <= maxExpandedBytes else { throw InstallFailure.archiveRejected("size") }
            if entry.kind == .file { files.insert(path) }
        }
        guard files.contains("\(root)/Contents/Info.plist"),
              files.contains("\(root)/Contents/MacOS/\(releaseExecutableName)")
        else { throw InstallFailure.archiveRejected("missing executable") }
    }

    // MARK: The extracted bundle's own claims

    /// The signature check proves who signed it; this proves it is the release
    /// that was offered, never a downgrade or a sideways move.
    static func checkStaged(_ info: StagedBundleInfo, offer: UpdateOffer,
                            running: SemanticVersion, expectedBundleID: String) throws {
        guard info.bundleID == expectedBundleID else { throw InstallFailure.stagedMismatch("bundle id") }
        guard SemanticVersion(info.shortVersion) == offer.version, offer.version > running
        else { throw InstallFailure.stagedMismatch("version") }
        guard info.executable == releaseExecutableName else { throw InstallFailure.stagedMismatch("executable") }
    }

    // MARK: What the last attempt left behind

    /// Derived from which version is running and which files exist, not from
    /// a progress journal, so a helper killed at any point leaves a state this
    /// still reads correctly, and reading it twice gives the same answer.
    static func launchOutcome(record: HandoffRecord?, report: HelperReport?,
                              confirmed: Bool, running: SemanticVersion?,
                              now: Date) -> LaunchOutcome {
        guard let record else { return .nothingPending }
        // A report that says the update is not installed outranks whichever
        // version runs: a copy of `to` running now did not get there through
        // this attempt, so it is never confirmed as the update.
        if let report {
            switch report.ending {
            case .restoreFailed, .evictionFailed: return .finished(.restoreFailed(record.to))
            case .rolledBack: return .finished(.rolledBack(record.to))
            case .notSwapped: return .finished(.notApplied(record.to, report.reason))
            case .confirmed, .launchedUnconfirmed: break
            }
        }
        if running == record.to {
            return confirmed ? .finished(nil) : .confirm(record.token, record.to)
        }
        guard running == record.from, report == nil else { return .finished(nil) }
        return isFresh(record, now: now) ? .helperMayBeRunning : .finished(.notApplied(record.to, nil))
    }

    private static func isFresh(_ record: HandoffRecord, now: Date) -> Bool {
        let age = now.timeIntervalSince(record.createdAt)
        return age >= -attemptLifetime && age < attemptLifetime
    }

    /// The one rule for "this attempt is over", shared by every sweep. An
    /// attempt that never reached the handoff and is not the active one, or one
    /// whose outcome is finished. `.confirm` and `.helperMayBeRunning` keep it.
    static func attemptIsFinished(record: HandoffRecord?, report: HelperReport?,
                                  confirmed: Bool, running: SemanticVersion?,
                                  isActive: Bool, now: Date) -> Bool {
        guard !isActive else { return false }
        guard let record else { return true }
        if case .finished = launchOutcome(record: record, report: report, confirmed: confirmed,
                                          running: running, now: now) { return true }
        return false
    }

    /// The only paths a sweep may remove: a direct child of the workspace root
    /// named "attempt-<UUID>", compared as realpath(3) strings, that neither is
    /// nor contains a protected path. Protected means the bundle this process
    /// runs from now and the install target.
    static func mayRemove(_ realPath: String, workspaceRoot: String,
                          protected: [String]) -> Bool {
        let parent = (realPath as NSString).deletingLastPathComponent
        let name = (realPath as NSString).lastPathComponent
        let prefix = "attempt-"
        guard parent == workspaceRoot, name.hasPrefix(prefix),
              UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
        else { return false }
        return !protected.contains { $0 == realPath || $0.hasPrefix(realPath + "/") }
    }

    // MARK: Scheduling

    static func isStale(lastChecked: Date?, now: Date) -> Bool {
        guard let lastChecked else { return true }
        return now.timeIntervalSince(lastChecked) >= staleAfter
    }
}

// MARK: - Versions and digests

/// "X.Y.Z" in decimal and nothing else, no leading zeros ("0" alone is fine):
/// FixDock has no beta channel, and a tag that is not plain SemVer is never an
/// update.
struct SemanticVersion: Comparable, Hashable, Codable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ text: String?) {
        guard let text else { return nil }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard (1...6).contains(part.count), part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  part.count == 1 || part.first != "0", let number = Int(part)
            else { return nil }
            numbers.append(number)
        }
        major = numbers[0]
        minor = numbers[1]
        patch = numbers[2]
    }

    init?(tag: String) {
        guard tag.hasPrefix("v") else { return nil }
        self.init(String(tag.dropFirst()))
    }

    var tag: String { "v\(description)" }
    var description: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// SHA-256 of the release zip as GitHub reports it. A corruption check before
/// extraction, not authentication: the signature decides trust.
struct ArchiveDigest: Hashable {
    /// 64 lowercase hex characters.
    let hex: String

    init?(github value: String) {
        let prefix = "sha256:"
        guard value.hasPrefix(prefix) else { return nil }
        self.init(hex: String(value.dropFirst(prefix.count)))
    }

    init?(hex: String) {
        let lower = hex.lowercased()
        guard lower.count == 64, lower.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
        self.hex = lower
    }
}

// MARK: - Feed

/// Where releases live. A local-feed test build uses a file: folder laid out
/// the same way (latest.json, releases/download/v<X>/FixDock-<X>.zip).
struct ReleaseLocation: Equatable {
    let feed: URL
    let repository: URL

    func archiveURL(for version: SemanticVersion) -> URL {
        URL(string: base + "/releases/download/\(version.tag)/FixDock-\(version).zip")!
    }

    func isReleasePage(_ url: URL) -> Bool {
        url.absoluteString.hasPrefix(base + "/releases/")
    }

    private var base: String {
        var text = repository.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }
}

/// What the transport hands the policy.
struct FeedResponse: Equatable {
    let status: Int
    let body: Data
    /// X-RateLimit-Reset as a date.
    let retryAfter: Date?
}

/// A release that passed every check possible before downloading.
struct UpdateOffer: Equatable {
    let version: SemanticVersion
    let archiveURL: URL
    let archiveSize: Int64
    let archiveDigest: ArchiveDigest
    /// The release body (Markdown), capped.
    let notes: String
    let releasePage: URL
}

enum FeedOutcome: Equatable {
    case offer(UpdateOffer)
    case upToDate
    case failed(CheckFailure)
}

enum CheckFailure: Error, Equatable {
    case unreachable
    case rateLimited(until: Date?)
    case server(Int)
    case unreadable
    case releaseIncomplete(SemanticVersion)
}

// MARK: - Eligibility

struct ExpectedIdentity: Equatable {
    let bundleID: String
    let teamID: String
    let installFolder: String
}

/// Measured once at launch by `RunningCopy.inspect`.
struct BuildFacts: Equatable {
    let bundleID: String?
    /// nil for ad-hoc and unsigned code.
    let teamID: String?
    let isDeveloperIDApplication: Bool
    /// realpath(3) of the running bundle and of its folder.
    let bundlePath: String
    let parentPath: String
    let canWriteParent: Bool
    let canWriteBundle: Bool
    /// Same st_dev as the workspace, so the swap cannot hit EXDEV.
    let sharesVolumeWithWorkspace: Bool
}

enum UpdateMode: Equatable {
    /// No network at all.
    case inert(InertReason)
    /// Checks run; the button opens the release page.
    case notifyOnly(ManualReason)
    case inPlace
}

enum InertReason: Equatable { case developerBuild, notDeveloperIDSigned, foreignTeam }
enum ManualReason: Equatable { case translocated, outsideApplications, notWritable, otherVolume }

// MARK: - Install

struct ArchiveEntry: Equatable {
    enum Kind: Equatable { case file, directory, symlink, other }
    let path: String
    let uncompressedSize: Int64
    let kind: Kind
}

struct StagedBundleInfo: Equatable {
    let bundleID: String?
    let shortVersion: String?
    let executable: String?
}

enum BusyWork: Equatable { case recording, mediaJob, cleaningMode }

/// Every way an install can stop before the app quits. After the handoff the
/// app is gone, and later outcomes come back as `UpdateNotice`.
enum InstallFailure: Error, Equatable {
    case busy(BusyWork)
    case unreachable
    case http(Int)
    case insecureRedirect
    case sizeMismatch
    case digestMismatch
    case diskWrite(Int32)
    case archiveRejected(String)
    case extractFailed
    case stagedMismatch(String)
    /// OSStatus from SecStaticCodeCheckValidityWithErrors.
    case signatureRejected(Int32)
    case handoffFailed(Int32)
}

// MARK: - Handoff protocol (one writer per file)

/// Written by the old app, once, before it spawns the helper.
struct HandoffRecord: Codable, Equatable {
    let token: UUID
    let from: SemanticVersion
    let to: SemanticVersion
    let appPID: Int32
    /// realpath of the installed bundle, which must also be the helper's own.
    let targetPath: String
    /// realpath of attempt/stage/FixDock.app.
    let stagedPath: String
    let createdAt: Date
}

/// Written by the helper, once, before it opens any app.
struct HelperReport: Codable, Equatable {
    enum Ending: String, Codable {
        case confirmed, launchedUnconfirmed, rolledBack, notSwapped, restoreFailed, evictionFailed
    }
    enum Reason: String, Codable {
        case appDidNotQuit, recordRejected, stagedRejected, swapFailed, launchFailed, newVersionExited
    }
    let token: UUID
    let ending: Ending
    let reason: Reason?
    let at: Date
}

enum LaunchOutcome: Equatable {
    case nothingPending
    /// This process is the new version and has not confirmed yet.
    case confirm(UUID, SemanticVersion)
    case helperMayBeRunning
    /// The attempt is over: show this, if anything, and sweep it.
    case finished(UpdateNotice?)
}

// MARK: - Status (the one published value) and its derived phase

enum UpdateActivity: Equatable {
    case idle
    case checking(manual: Bool)
    case installing(InstallStep)
}

enum InstallStep: Equatable {
    case downloading(fraction: Double?)
    case verifying
    case restarting
}

enum UpdateProblem: Equatable {
    case check(CheckFailure)
    case install(InstallFailure)
}

enum UpdateNotice: Equatable {
    case updated(SemanticVersion)
    case rolledBack(SemanticVersion)
    case notApplied(SemanticVersion, HelperReport.Reason?)
    case restoreFailed(SemanticVersion)
}

enum InstallRoute: Equatable {
    case inPlace
    case releasePage(ManualReason)
}

/// What every update surface switches over. Derived, never stored.
enum UpdatePhase: Equatable {
    case inert(InertReason)
    case neverChecked
    case checking
    case upToDate
    case checkFailed(CheckFailure)
    case available(UpdateOffer, InstallRoute)
    case installing(UpdateOffer, InstallStep)
}

enum UpdateEvent: Equatable {
    case checkStarted(manual: Bool)
    case checkFinished(FeedOutcome, manual: Bool, at: Date)
    case installStarted
    case installProgressed(InstallStep)
    case installFailed(InstallFailure)
    case installCancelled
    case previousAttempt(UpdateNotice?)
    case quieted(SemanticVersion?)
}

/// The one value UpdateService publishes. Offer and activity are separate so a
/// re-check never hides an offer, and check and install problems are separate
/// cases so one never reads as the other.
struct UpdateStatus: Equatable {
    let mode: UpdateMode
    var offer: UpdateOffer?
    var activity: UpdateActivity = .idle
    /// The last check that reached GitHub and was understood.
    var lastChecked: Date?
    var problem: UpdateProblem?
    /// What the previous attempt ended in; lasts for this session.
    var notice: UpdateNotice?
    /// A version that already failed to start here: offered, never nagged.
    var quietVersion: SemanticVersion?

    init(mode: UpdateMode, lastChecked: Date?, quietVersion: SemanticVersion?) {
        self.mode = mode
        self.lastChecked = lastChecked
        self.quietVersion = quietVersion
    }

    mutating func apply(_ event: UpdateEvent) {
        switch event {
        case .checkStarted(let manual):
            guard canStartCheck else { return }
            activity = .checking(manual: manual)
        case .checkFinished(let outcome, let manual, let at):
            guard case .checking = activity else { return }
            activity = .idle
            switch outcome {
            case .offer(let found):
                offer = found
                lastChecked = at
                problem = nil
            case .upToDate:
                offer = nil
                lastChecked = at
                problem = nil
            case .failed(let failure):
                // Automatic failures are silent: the last good state stays.
                if manual { problem = .check(failure) }
            }
        case .installStarted:
            guard canInstall else { return }
            activity = .installing(.downloading(fraction: nil))
            problem = nil
        case .installProgressed(let step):
            guard case .installing = activity else { return }
            activity = .installing(step)
        case .installFailed(let failure):
            // The offer stays, so a retry is one click.
            activity = .idle
            problem = .install(failure)
        case .installCancelled:
            guard case .installing(.downloading) = activity else { return }
            activity = .idle
        case .previousAttempt(let previous):
            notice = previous
        case .quieted(let version):
            quietVersion = version
        }
    }

    var phase: UpdatePhase {
        if case .inert(let reason) = mode { return .inert(reason) }
        if case .installing(let step) = activity, let offer { return .installing(offer, step) }
        if let offer { return .available(offer, route) }
        if case .checking = activity { return .checking }
        if case .check(let failure)? = problem { return .checkFailed(failure) }
        return lastChecked == nil ? .neverChecked : .upToDate
    }

    var canStartCheck: Bool {
        if case .inert = mode { return false }
        return activity == .idle
    }

    var canInstall: Bool {
        mode == .inPlace && offer != nil && activity == .idle
    }

    var canCancel: Bool {
        if case .installing(.downloading) = activity { return true }
        return false
    }

    /// The panel banner: an offer or an install in progress, unless it is the
    /// quiet version.
    var showsBanner: Bool {
        switch phase {
        case .available(let offer, _): return offer.version != quietVersion
        case .installing: return true
        default: return false
        }
    }

    /// The status item dot: an offer that is not the quiet version, and every
    /// install step.
    var wantsAttention: Bool {
        switch phase {
        case .available(let offer, _): return offer.version != quietVersion
        case .installing: return true
        default: return false
        }
    }

    private var route: InstallRoute {
        if case .notifyOnly(let reason) = mode { return .releasePage(reason) }
        return .inPlace
    }
}

// MARK: - Wire format (private to this file)

private struct WireRelease: Decodable {
    let tag_name: String
    let draft: Bool
    let prerelease: Bool
    let html_url: String
    let body: String?
    let assets: [WireAsset]
}

private struct WireAsset: Decodable {
    let name: String
    let state: String
    let size: Int64
    let browser_download_url: String
    let digest: String?
}
