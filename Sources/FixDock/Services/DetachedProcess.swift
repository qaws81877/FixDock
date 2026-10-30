// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Darwin
import Foundation

/// Starts a process that has to outlive this app: `Relauncher`'s helper, which
/// waits for this process to go away before it opens the bundle again.
///
/// `nohup` is not enough: it only makes the child ignore SIGHUP. The child
/// stays in this app's session, so whatever tears that session down takes the
/// helper with it. `setsid(2)` is what leaves the session. Adapted from the
/// upstream helper used for the same relaunch.
enum DetachedProcess {
    /// POSIX_SPAWN_SETSID: the kernel makes the child its own session leader
    /// before it execs. CLOEXEC_DEFAULT keeps this app's other descriptors
    /// out of a child that outlives it.
    @discardableResult
    static func spawn(_ executablePath: String, _ arguments: [String]) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes,
                                 Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, 2, "/dev/null", O_WRONLY, 0)

        let argv: [UnsafeMutablePointer<CChar>?] =
            ([executablePath] + arguments).map { strdup($0) } + [nil]
        defer { for argument in argv { free(argument) } }

        var pid: pid_t = 0
        let status = posix_spawn(&pid, executablePath, &fileActions, &attributes, argv, environ)
        guard status == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(status))])
        }
        return pid
    }
}
