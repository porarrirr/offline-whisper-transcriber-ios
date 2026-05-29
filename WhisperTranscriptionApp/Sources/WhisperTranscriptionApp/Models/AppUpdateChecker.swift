import Foundation

struct AppUpdateInfo: Identifiable {
    let currentVersion: String
    let remoteVersion: String
    let appStoreURL: URL

    var id: String {
        "\(currentVersion)-\(remoteVersion)"
    }
}

final class AppUpdateChecker {
    static let shared = AppUpdateChecker()

    private let session: URLSession
    private let bundle: Bundle
    private let defaults: UserDefaults
    private static let lastCheckDateKey = "AppUpdateChecker.lastCheckDate"
    private static let minimumCheckInterval: TimeInterval = 24 * 60 * 60

    init(session: URLSession = .shared, bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        self.session = session
        self.bundle = bundle
        self.defaults = defaults
    }

    func availableUpdate() async throws -> AppUpdateInfo? {
        guard shouldCheckNow() else { return nil }
        defer { recordCheckAttempt() }

        let bundleID = try currentBundleID()
        let currentVersion = try currentAppVersion()
        let appStoreApp = try await fetchAppStoreApp(bundleID: bundleID)

        guard isVersion(appStoreApp.version, newerThan: currentVersion) else {
            return nil
        }

        return AppUpdateInfo(
            currentVersion: currentVersion,
            remoteVersion: appStoreApp.version,
            appStoreURL: appStoreApp.trackViewURL
        )
    }

    private func fetchAppStoreApp(bundleID: String) async throws -> AppStoreApp {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")
        components?.queryItems = [
            URLQueryItem(name: "bundleId", value: bundleID),
            URLQueryItem(name: "media", value: "software"),
            URLQueryItem(name: "entity", value: "software"),
        ]

        if let regionCode = Locale.current.region?.identifier {
            components?.queryItems?.append(URLQueryItem(name: "country", value: regionCode))
        }

        guard let url = components?.url else {
            throw AppUpdateCheckError.invalidLookupURL
        }

        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw AppUpdateCheckError.invalidLookupResponse
        }

        let lookupResponse = try JSONDecoder().decode(AppStoreLookupResponse.self, from: data)
        guard let app = lookupResponse.results.first(where: { $0.bundleID == bundleID }) else {
            throw AppUpdateCheckError.appNotFoundInStorefront
        }

        return app
    }

    private func currentBundleID() throws -> String {
        guard let bundleID = bundle.bundleIdentifier, !bundleID.isEmpty else {
            throw AppUpdateCheckError.missingBundleID
        }

        return bundleID
    }

    private func currentAppVersion() throws -> String {
        guard let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
              !version.isEmpty else {
            throw AppUpdateCheckError.missingCurrentVersion
        }

        return version
    }

    private func isVersion(_ remoteVersion: String, newerThan currentVersion: String) -> Bool {
        guard let remoteComponents = numericComponents(from: remoteVersion),
              let currentComponents = numericComponents(from: currentVersion) else {
            return remoteVersion.compare(currentVersion, options: .numeric) == .orderedDescending
        }

        let componentCount = max(remoteComponents.count, currentComponents.count)
        for index in 0..<componentCount {
            let remote = index < remoteComponents.count ? remoteComponents[index] : 0
            let current = index < currentComponents.count ? currentComponents[index] : 0

            if remote != current {
                return remote > current
            }
        }

        return false
    }

    private func numericComponents(from version: String) -> [Int]? {
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return nil }

        var numericComponents: [Int] = []
        for component in components {
            guard let numericComponent = Int(component) else {
                return nil
            }

            numericComponents.append(numericComponent)
        }

        return numericComponents
    }

    private func shouldCheckNow() -> Bool {
        guard let lastCheckDate = defaults.object(forKey: Self.lastCheckDateKey) as? Date else {
            return true
        }
        return Date().timeIntervalSince(lastCheckDate) >= Self.minimumCheckInterval
    }

    private func recordCheckAttempt() {
        defaults.set(Date(), forKey: Self.lastCheckDateKey)
    }
}

private struct AppStoreLookupResponse: Decodable {
    let results: [AppStoreApp]
}

private struct AppStoreApp: Decodable {
    let bundleID: String
    let version: String
    let trackViewURL: URL

    enum CodingKeys: String, CodingKey {
        case bundleID = "bundleId"
        case version
        case trackViewURL = "trackViewUrl"
    }
}

enum AppUpdateCheckError: LocalizedError {
    case missingBundleID
    case missingCurrentVersion
    case invalidLookupURL
    case invalidLookupResponse
    case appNotFoundInStorefront

    var errorDescription: String? {
        switch self {
        case .missingBundleID:
            return "Bundle ID is missing."
        case .missingCurrentVersion:
            return "Current app version is missing."
        case .invalidLookupURL:
            return "App Store lookup URL is invalid."
        case .invalidLookupResponse:
            return "App Store lookup response is invalid."
        case .appNotFoundInStorefront:
            return "App was not found in the current App Store storefront."
        }
    }
}
