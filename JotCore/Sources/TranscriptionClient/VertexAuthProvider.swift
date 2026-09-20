// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation

/// Resolves and caches Google Cloud Application Default Credentials (ADC) OAuth2
/// Bearer tokens for Vertex AI (`aiplatform.googleapis.com`).
///
/// Primary path uses `URLSession` against `~/.config/gcloud/application_default_credentials.json`
/// (`authorized_user` refresh_token grant) so a macOS GUI app bundle never depends
/// on the shell `PATH` containing Homebrew or Cloud SDK binaries. Falls back to
/// `gcloud auth application-default print-access-token` when present.
public actor VertexAuthProvider {

    public static let shared = VertexAuthProvider()

    private struct CachedToken {
        let accessToken: String
        let expiresAt: Date
    }

    private var cached: CachedToken?
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 10
        self.session = URLSession(configuration: config)
    }

    /// Returns a valid OAuth2 access token, refreshing if missing or within 60s of expiry.
    public func accessToken() async throws -> String {
        if let cached, Date().addingTimeInterval(60) < cached.expiresAt {
            return cached.accessToken
        }
        if let refreshed = try? await refreshFromADCFile() {
            cached = refreshed
            return refreshed.accessToken
        }
        if let cliToken = Self.tokenFromGcloudCLI() {
            let token = CachedToken(accessToken: cliToken, expiresAt: Date().addingTimeInterval(1_800))
            cached = token
            return token.accessToken
        }
        throw TranscriptionError.auth
    }

    /// Builds the HTTP headers required by Vertex AI REST and `LlmBidiService` WebSocket.
    public func headers(projectID: String) async throws -> [String: String] {
        let token = try await accessToken()
        var result: [String: String] = ["Authorization": "Bearer \(token)"]
        let trimmed = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            result["x-goog-user-project"] = trimmed
        }
        return result
    }

    // MARK: - ADC File Refresh

    private static var adcFileURL: URL {
        if let custom = ProcessInfo.processInfo.environment["GOOGLE_APPLICATION_CREDENTIALS"],
           !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/gcloud/application_default_credentials.json")
    }

    /// Best-effort discovery of the user's default GCP project ID from local ADC or gcloud config.
    public static func detectedProjectID() -> String? {
        if let envProject = ProcessInfo.processInfo.environment["GOOGLE_CLOUD_PROJECT"],
           !envProject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return envProject.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let data = try? Data(contentsOf: adcFileURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let quotaProject = json["quota_project_id"] as? String,
           !quotaProject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return quotaProject.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let defaultConfig = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/gcloud/configurations/config_default")
        if let content = try? String(contentsOf: defaultConfig, encoding: .utf8) {
            for line in content.components(separatedBy: .newlines) {
                let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, parts[0] == "project", !parts[1].isEmpty {
                    return parts[1]
                }
            }
        }
        return nil
    }

    private func refreshFromADCFile() async throws -> CachedToken? {
        guard let data = try? Data(contentsOf: Self.adcFileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clientID = json["client_id"] as? String,
              let clientSecret = json["client_secret"] as? String,
              let refreshToken = json["refresh_token"] as? String
        else { return nil }

        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "client_secret", value: clientSecret),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (respData, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let token = body["access_token"] as? String,
              !token.isEmpty
        else { return nil }

        let expiresIn = (body["expires_in"] as? TimeInterval) ?? 3_600
        return CachedToken(accessToken: token, expiresAt: Date().addingTimeInterval(expiresIn))
    }

    private static func tokenFromGcloudCLI() -> String? {
        let candidates = [
            "/opt/homebrew/bin/gcloud",
            "/usr/local/bin/gcloud",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("google-cloud-sdk/bin/gcloud").path,
        ]
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = ["auth", "application-default", "print-access-token"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let out = pipe.fileHandleForReading.readDataToEndOfFile()
            let token = String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (token?.isEmpty == false) ? token : nil
        } catch {
            return nil
        }
    }
}
