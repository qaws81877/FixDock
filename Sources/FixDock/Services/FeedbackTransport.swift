// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Foundation

/// Posts one feedback report to the relay, which forwards it to Discord.
/// Runs only when the person presses Send. Ephemeral session, User-Agent
/// "FixDock", no version header: the report itself says what it says.
enum FeedbackTransport {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpAdditionalHeaders = ["User-Agent": "FixDock"]
        return URLSession(configuration: configuration)
    }()

    /// Completion on the main queue with whether the relay accepted it.
    static func send(_ kind: FeedbackSheet.Kind, note: String, report: String,
                     completion: @escaping (Bool) -> Void) {
        let path = kind == .bug ? "bug" : "idea"
        var request = URLRequest(url: AppInfo.feedbackRelayURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["note": note, "report": report])
        session.dataTask(with: request) { _, response, error in
            let accepted = error == nil && (response as? HTTPURLResponse)?.statusCode == 204
            DispatchQueue.main.async { completion(accepted) }
        }.resume()
    }
}
