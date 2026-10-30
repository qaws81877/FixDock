// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import CryptoKit
import Darwin
import Foundation

/// FixDock's only network code: two exchanges with GitHub. Ephemeral sessions
/// (no cookies, no cache), User-Agent "FixDock" with no version, no
/// If-None-Match (a 304 costs the same share of the hourly limit). The archive
/// URL redirects to GitHub's asset host, which is not named anywhere: trust
/// comes from the digest and the signature, not from the host.
final class UpdateTransport {
    static let shared = UpdateTransport()

    private let feedSession = URLSession(configuration: UpdateTransport.configuration())
    /// The download in flight, touched on the main thread only.
    private var activeDownload: (token: UUID, task: URLSessionTask)?

    /// GitHub in every build except a local-feed test build, where build.sh
    /// adds the compile flag and an Info.plist key naming a folder laid out
    /// like GitHub.
    var location: ReleaseLocation {
        #if FIXDOCK_LOCAL_FEED
        let folder = Bundle.main.object(forInfoDictionaryKey: "FixDockLocalFeedFolder") as? String ?? "/var/empty"
        let repository = URL(fileURLWithPath: folder, isDirectory: true)
        return ReleaseLocation(feed: repository.appendingPathComponent("latest.json"), repository: repository)
        #else
        return ReleaseLocation(feed: AppInfo.releaseFeedURL, repository: AppInfo.repositoryURL)
        #endif
    }

    /// Completion on the main queue. Transport errors are `.unreachable`;
    /// everything HTTP-level goes to `UpdatePolicy.evaluateFeed`.
    func fetchFeed(completion: @escaping (Result<FeedResponse, CheckFailure>) -> Void) {
        var request = URLRequest(url: location.feed)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        feedSession.dataTask(with: request) { data, response, error in
            let result: Result<FeedResponse, CheckFailure>
            if error != nil {
                result = .failure(.unreachable)
            } else if let status = Self.status(of: response) {
                let reset = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-RateLimit-Reset")
                    .flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
                result = .success(FeedResponse(status: status, body: data ?? Data(), retryAfter: reset))
            } else {
                result = .failure(.unreadable)
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    /// Streams the archive into attempt.partialArchive (O_EXCL, 0600) while
    /// hashing it, then renames it to attempt.archive with RENAME_EXCL. Any
    /// failure unlinks only the partial file it created. `progress` gets
    /// whole-percent steps; both callbacks arrive on the main queue. Main
    /// thread only.
    func download(_ offer: UpdateOffer, into attempt: UpdateWorkspace.Attempt,
                  progress: @escaping (Double?) -> Void,
                  completion: @escaping (Result<URL, InstallFailure>) -> Void) {
        let descriptor = open(attempt.partialArchive.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            let code = errno
            DispatchQueue.main.async { completion(.failure(.diskWrite(code))) }
            return
        }
        let delegate = BoundedDownload(offer: offer, attempt: attempt, descriptor: descriptor,
                                       progress: progress, completion: { [weak self] result in
            if self?.activeDownload?.token == attempt.token { self?.activeDownload = nil }
            completion(result)
        })
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: Self.configuration(), delegate: delegate, delegateQueue: queue)
        let task = session.dataTask(with: URLRequest(url: offer.archiveURL))
        activeDownload = (attempt.token, task)
        task.resume()
        session.finishTasksAndInvalidate()
    }

    /// The download's completion still arrives, as a failure.
    func cancelDownload() {
        activeDownload?.task.cancel()
    }

    private static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        configuration.httpAdditionalHeaders = ["User-Agent": "FixDock"]
        return configuration
    }

    /// The HTTP status. A non-HTTP response has none in a release build; a
    /// local-feed build reads its folder through file: URLs and counts that as 200.
    fileprivate static func status(of response: URLResponse?) -> Int? {
        if let http = response as? HTTPURLResponse { return http.statusCode }
        #if FIXDOCK_LOCAL_FEED
        if response?.url?.isFileURL == true { return 200 }
        #endif
        return nil
    }
}

/// One archive download. Every method runs on the session's serial queue.
private final class BoundedDownload: NSObject, URLSessionDataDelegate {
    private let offer: UpdateOffer
    private let attempt: UpdateWorkspace.Attempt
    private var descriptor: Int32
    private let progress: (Double?) -> Void
    private let completion: (Result<URL, InstallFailure>) -> Void
    private var hasher = SHA256()
    private var received: Int64 = 0
    private var lastPercent = -1
    private var failure: InstallFailure?

    init(offer: UpdateOffer, attempt: UpdateWorkspace.Attempt, descriptor: Int32,
         progress: @escaping (Double?) -> Void,
         completion: @escaping (Result<URL, InstallFailure>) -> Void) {
        self.offer = offer
        self.attempt = attempt
        self.descriptor = descriptor
        self.progress = progress
        self.completion = completion
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme == "https" else {
            failure = .insecureRedirect
            task.cancel()
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard failure == nil else { return completionHandler(.cancel) }
        guard let status = UpdateTransport.status(of: response), status == 200 else {
            failure = .http((response as? HTTPURLResponse)?.statusCode ?? 0)
            return completionHandler(.cancel)
        }
        let length = response.expectedContentLength
        guard length == -1 || length == offer.archiveSize else {
            failure = .sizeMismatch
            return completionHandler(.cancel)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        received += Int64(data.count)
        guard received <= offer.archiveSize else {
            failure = .sizeMismatch
            dataTask.cancel()
            return
        }
        hasher.update(data: data)
        let written = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let count = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if count < 0 { if errno == EINTR { continue }; return false }
                offset += count
            }
            return true
        }
        guard written else {
            failure = .diskWrite(errno)
            dataTask.cancel()
            return
        }
        let percent = Int(received * 100 / offer.archiveSize)
        if percent != lastPercent {
            lastPercent = percent
            let fraction = Double(received) / Double(offer.archiveSize)
            DispatchQueue.main.async { [progress] in progress(fraction) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result = finish(error: error)
        if case .failure = result { unlink(attempt.partialArchive.path) }
        DispatchQueue.main.async { [completion] in completion(result) }
    }

    private func finish(error: Error?) -> Result<URL, InstallFailure> {
        let closed = close(descriptor) == 0
        descriptor = -1
        if let failure { return .failure(failure) }
        if error != nil { return .failure(.unreachable) }
        guard closed else { return .failure(.diskWrite(errno)) }
        guard received == offer.archiveSize else { return .failure(.sizeMismatch) }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard hex == offer.archiveDigest.hex else { return .failure(.digestMismatch) }
        guard renamex_np(attempt.partialArchive.path, attempt.archive.path, UInt32(RENAME_EXCL)) == 0
        else { return .failure(.diskWrite(errno)) }
        return .success(attempt.archive)
    }
}
