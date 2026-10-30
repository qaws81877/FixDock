// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Darwin
import Foundation
import Security

/// The code signature of a bundle, read with Security.framework.
struct SigningIdentity: Equatable {
    /// nil for ad-hoc and unsigned code.
    let teamID: String?
    let isDeveloperIDApplication: Bool
    /// The designated requirement as text. TCC grants are keyed on it, so a
    /// replacement that satisfies it keeps them. An ad-hoc build's DR is a bare
    /// cdhash that no other bundle satisfies.
    let designatedRequirement: String

    /// Apple's Developer ID Application chain, without a team.
    static let developerIDApplicationShape =
        "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]"

    static func ofRunningApp() -> SigningIdentity? {
        var me: SecCode?
        var code: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &code) == errSecSuccess, let code
        else { return nil }
        return read(code)
    }

    /// The same read for a bundle on disk. A harness binary is ad-hoc, so it
    /// pins the published release's identity this way.
    static func ofBundle(at url: URL) -> SigningIdentity? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code
        else { return nil }
        return read(code)
    }

    /// This copy's own DR, so TCC grants carry over, and Apple's notarization,
    /// satisfied by the stapled ticket. This stands in for the first-launch
    /// Gatekeeper check the swapped copy never gets: nothing downloaded here is
    /// quarantined, and a quarantined bundle moved by rename(2) would be
    /// translocated on launch.
    var replacementRequirement: String { "(\(designatedRequirement)) and notarized" }

    private static func read(_ code: SecStaticCode) -> SigningIdentity? {
        var requirement: SecRequirement?
        var text: CFString?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text
        else { return nil }
        var info: CFDictionary?
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
        var shape: SecRequirement?
        let isDeveloperID = SecRequirementCreateWithString(developerIDApplicationShape as CFString, [], &shape) == errSecSuccess
            && shape.map {
                SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSDoNotValidateResources
                                                            | kSecCSDoNotValidateExecutable), $0) == errSecSuccess
            } == true
        return SigningIdentity(teamID: team, isDeveloperIDApplication: isDeveloperID,
                               designatedRequirement: text as String)
    }
}

/// What this copy is and may do, measured once at launch.
struct RunningCopy {
    let version: SemanticVersion?
    /// realpath of the running bundle.
    let bundleURL: URL
    let signing: SigningIdentity?
    let mode: UpdateMode

    /// The team constant only gates; the pin a replacement must meet is the
    /// derived DR.
    static func inspect(workspace: UpdateWorkspace?) -> RunningCopy {
        let signing = SigningIdentity.ofRunningApp()
        let bundle = UpdateWorkspace.realPath(Bundle.main.bundlePath) ?? Bundle.main.bundlePath
        let parent = (bundle as NSString).deletingLastPathComponent
        let facts = BuildFacts(
            bundleID: Bundle.main.bundleIdentifier,
            teamID: signing?.teamID,
            isDeveloperIDApplication: signing?.isDeveloperIDApplication ?? false,
            bundlePath: bundle,
            parentPath: parent,
            canWriteParent: access(parent, W_OK) == 0,
            canWriteBundle: access(bundle, W_OK) == 0,
            sharesVolumeWithWorkspace: workspace.map { sameVolume(parent, $0.root.path) } ?? false)
        let mode = UpdatePolicy.mode(for: facts, expected: ExpectedIdentity(
            bundleID: AppInfo.bundleID, teamID: AppInfo.signingTeamID, installFolder: "/Applications"))
        return RunningCopy(version: SemanticVersion(AppInfo.version),
                           bundleURL: URL(fileURLWithPath: bundle, isDirectory: true),
                           signing: signing, mode: mode)
    }

    /// The workspace may not exist yet, so its nearest existing ancestor decides.
    private static func sameVolume(_ a: String, _ b: String) -> Bool {
        var first = stat()
        guard stat(a, &first) == 0 else { return false }
        var path = b
        var second = stat()
        while stat(path, &second) != 0 {
            let parent = (path as NSString).deletingLastPathComponent
            guard parent != path, !parent.isEmpty else { return false }
            path = parent
        }
        return first.st_dev == second.st_dev
    }
}

/// Proof that a staged bundle passed every check. Only `UpdateVerifier` can
/// make one, so `Relauncher.replaceAndRelaunch(with:)` cannot be handed
/// anything else.
struct VerifiedUpdate {
    let offer: UpdateOffer
    let attempt: UpdateWorkspace.Attempt
    let running: RunningCopy

    fileprivate init(offer: UpdateOffer, attempt: UpdateWorkspace.Attempt, running: RunningCopy) {
        self.offer = offer
        self.attempt = attempt
        self.running = running
    }
}

enum UpdateVerifier {
    /// Off the main thread. `archive` is already size- and digest-checked.
    /// Cheapest and most structural first, so nothing parses what an earlier
    /// step rejected. A failure leaves the attempt for the sweep to remove.
    static func extractAndVerify(archive: URL, offer: UpdateOffer,
                                 attempt: UpdateWorkspace.Attempt,
                                 running: RunningCopy) throws -> VerifiedUpdate {
        guard running.mode == .inPlace, let signing = running.signing, let current = running.version
        else { throw InstallFailure.stagedMismatch("running identity") }

        guard let listing = ZipArchive.shortListing(of: archive),
              let entries = UpdatePolicy.parseZipListing(listing)
        else { throw InstallFailure.archiveRejected("listing") }
        try UpdatePolicy.checkArchive(entries)

        // A fresh, empty stage: the listing above is what ditto may write.
        guard mkdir(attempt.stageDirectory.path, 0o700) == 0 else { throw InstallFailure.diskWrite(errno) }
        do { try ZipArchive.extract(archive, into: attempt.stageDirectory) } catch {
            throw InstallFailure.extractFailed
        }
        var info = stat()
        guard (try? FileManager.default.contentsOfDirectory(atPath: attempt.stageDirectory.path))
                == [UpdatePolicy.releaseBundleName],
              lstat(attempt.stagedApp.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR
        else { throw InstallFailure.archiveRejected("top-level item") }

        let plist = NSDictionary(contentsOf: attempt.stagedApp.appendingPathComponent("Contents/Info.plist"))
        try UpdatePolicy.checkStaged(
            StagedBundleInfo(bundleID: plist?["CFBundleIdentifier"] as? String,
                             shortVersion: plist?["CFBundleShortVersionString"] as? String,
                             executable: plist?["CFBundleExecutable"] as? String),
            offer: offer, running: current, expectedBundleID: AppInfo.bundleID)

        var code: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(attempt.stagedApp as CFURL, [], &code)
        guard created == errSecSuccess, let code else { throw InstallFailure.signatureRejected(created) }
        var requirement: SecRequirement?
        let parsed = SecRequirementCreateWithString(signing.replacementRequirement as CFString, [], &requirement)
        guard parsed == errSecSuccess, let requirement else { throw InstallFailure.signatureRejected(parsed) }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode
                               | kSecCSStrictValidate | kSecCSRestrictSymlinks)
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, requirement, nil)
        guard status == errSecSuccess else { throw InstallFailure.signatureRejected(status) }

        return VerifiedUpdate(offer: offer, attempt: attempt, running: running)
    }
}
