// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Foundation

/// Zips with the Mac's own tools: `ditto` writes and extracts, `zipinfo`
/// reads back. Shared by the Media tool, AirDrop auto-zip and self-update.
enum ZipArchive {
    enum Failure: Error { case archiveFailed, verifyFailed, extractFailed }

    /// Zips the contents of `directory` (not the folder itself) into `zip`,
    /// then checks the archive lists exactly `expectedNames`.
    static func archive(contentsOf directory: URL, to zip: URL, expectedNames: [String]) throws {
        guard run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", directory.path, zip.path]) != nil
        else { throw Failure.archiveFailed }
        guard let listing = run("/usr/bin/zipinfo", ["-1", zip.path]) else { throw Failure.verifyFailed }
        let names = listing.split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/") }
        guard names.sorted() == expectedNames.sorted() else { throw Failure.verifyFailed }
    }

    /// `zipinfo -s`: one line per entry with its mode, size and name.
    static func shortListing(of zip: URL) -> String? {
        run("/usr/bin/zipinfo", ["-s", zip.path])
    }

    /// `ditto -x -k`, not unzip: a release zip carries AppleDouble "._" entries
    /// that ditto folds back into extended attributes. `directory` must exist.
    static func extract(_ zip: URL, into directory: URL) throws {
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, directory.path]) != nil
        else { throw Failure.extractFailed }
    }

    /// Standard output on exit status 0, nil otherwise.
    private static func run(_ tool: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
