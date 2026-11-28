//
//  SourcesViewModel.swift
//  AshteMobile
//
import Foundation
import AltSourceKit
import SwiftUI
import CryptoKit

// XSIGN_CATALOG_LOADING_V1
@MainActor
final class SourcesViewModel: ObservableObject {
    static let shared = SourcesViewModel()
    typealias RepositoryDataHandler = Result<ASRepository, Error>
    private(set) var isFinished = true
    @Published var sources: [AltSource: ASRepository] = [:]
    @Published private(set) var errors: [AltSource: String] = [:]
    private var fingerprints: [AltSource: Data] = [:]
    private var running: Task<Void, Never>?

    func fingerprint(for source: AltSource) -> Data? { fingerprints[source] }

    func seed(_ record: XSignRepositoryRecord, for source: AltSource) {
        guard !ProtectedSourcesVault.isRetiredSource(source.sourceURL, identifier: source.identifier) else { return }
        guard fingerprints[source] != record.fingerprint else { return }
        fingerprints[source] = record.fingerprint
        sources[source] = record.repository
        errors[source] = nil
    }

    func fetchSources<S: Collection>(_ requested: S, refresh: Bool = false, batchSize _: Int = 1) async where S.Element == AltSource {
        while let running { await running.value }
        let targets = requested.filter { !ProtectedSourcesVault.isRetiredSource($0.sourceURL, identifier: $0.identifier) }
        let allowed = Set(targets)
        sources = sources.filter { allowed.contains($0.key) }
        fingerprints = fingerprints.filter { allowed.contains($0.key) }
        errors = errors.filter { allowed.contains($0.key) }
        let pending = targets.filter { refresh || sources[$0] == nil }
        guard !pending.isEmpty else { return }
        let task = Task { @MainActor in
            self.isFinished = false
            defer { self.isFinished = true; self.running = nil }
            // Each successful source becomes visible immediately, independently of the others.
            for source in pending {
                guard let url = source.sourceURL else { continue }
                if self.sources[source] == nil, let cached = await XSignCatalogIO.shared.cached(url) {
                    self.seed(cached, for: source)
                }
                do {
                    let result = try await XSignCatalogIO.shared.fetch(url)
                    self.seed(result, for: source)
                    self.errors[source] = nil
                } catch {
                    self.errors[source] = error.localizedDescription
                }
            }
        }
        running = task
        await task.value
    }
}

// MARK: - Shared catalog transport; disk and decoding never run on the main actor
struct XSignRepositoryRecord: Sendable {
    let repository: ASRepository
    let fingerprint: Data
}

enum XSignCatalogError: LocalizedError {
    case invalidURL, invalidResponse, http(Int), tooLarge, invalidJSON
    var errorDescription: String? {
        switch self {
        case .invalidURL: return AshteL10n.t("رابط السورس غير صالح.")
        case .invalidResponse: return AshteL10n.t("الخادم لم يُرجع بيانات سورس JSON.")
        case .http(let status): return AshteL10n.t("تعذّر جلب السورس (HTTP %ld).", status)
        case .tooLarge: return AshteL10n.t("حجم السورس يتجاوز الحد المسموح.")
        case .invalidJSON: return AshteL10n.t("بيانات السورس ليست بصيغة AltStore صالحة.")
        }
    }
}

actor XSignCatalogIO {
    static let shared = XSignCatalogIO()
    nonisolated static let maximumBytes = 33_554_432
    private let directory: URL
    private let bundledResources: URL?
    private let session: URLSession
    private var requests: [String: Task<XSignRepositoryRecord, Error>] = [:]

    init(directory: URL? = nil, session: URLSession? = nil, bundledResources: URL? = nil) {
        self.bundledResources = bundledResources
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("XSignCatalogs_v3", isDirectory: true)
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.httpMaximumConnectionsPerHost = 2
            config.timeoutIntervalForRequest = 20
            config.timeoutIntervalForResource = 90
            config.urlCache = nil
            config.waitsForConnectivity = false
            self.session = URLSession(configuration: NetworkShield.protect(config))
        }
    }

    nonisolated static func canonicalURL(_ input: URL) -> URL {
        guard var parts = URLComponents(url: input, resolvingAgainstBaseURL: false) else { return input }
        let host = parts.host?.lowercased()
        var path = parts.percentEncodedPath
        if host == "github.com" {
            let segments = path.split(separator: "/", omittingEmptySubsequences: true)
            if segments.count >= 5, segments[2] == "blob" || segments[2] == "raw" {
                parts.host = "raw.githubusercontent.com"
                path = "/" + ([String(segments[0]), String(segments[1])] + segments.dropFirst(3).map(String.init)).joined(separator: "/")
                parts.queryItems = parts.queryItems?.filter { $0.name != "raw" }
            }
        }
        if parts.host?.lowercased() == "raw.githubusercontent.com" {
            path = path.replacingOccurrences(of: "/refs/heads/", with: "/")
        }
        parts.percentEncodedPath = path
        return parts.url ?? input
    }

    /// raw.githubusercontent.com keeps every URL in its CDN for ~5 minutes, so a new source JSON
    /// looked "old" for minutes. A unique query value makes the CDN fetch the file again.
    /// Only the network request changes; the cache file name still uses the clean URL.
    nonisolated static func freshURL(_ input: URL) -> URL {
        guard let host = input.host?.lowercased(),
              host == "raw.githubusercontent.com" || host == "github.com" || host.hasSuffix(".githubusercontent.com"),
              var parts = URLComponents(url: input, resolvingAgainstBaseURL: false) else { return input }
        var items = (parts.queryItems ?? []).filter { $0.name != "_ts" }
        items.append(URLQueryItem(name: "_ts", value: String(Int(Date().timeIntervalSince1970))))
        parts.queryItems = items
        return parts.url ?? input
    }

    private func file(_ url: URL) -> URL {
        let key = SHA256.hash(data: Data(Self.canonicalURL(url).absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key + ".json")
    }

    nonisolated static func decode(_ data: Data) throws -> XSignRepositoryRecord {
        guard data.count <= maximumBytes else { throw XSignCatalogError.tooLarge }
        let repository: ASRepository
        do {
            repository = try JSONDecoder().decode(ASRepository.self, from: data)
        } catch {
            // Some otherwise valid sources contain blank optional URL fields.
            guard let object = try? JSONSerialization.jsonObject(with: data), object is [String: Any] else {
                throw XSignCatalogError.invalidJSON
            }
            func clean(_ value: Any) -> Any {
                if let dict = value as? [String: Any] {
                    let optionalURLs: Set<String> = ["iconURL", "website", "headerURL", "imageURL", "url", "date", "versionDate"]
                    return dict.reduce(into: [String: Any]()) { result, pair in
                        if optionalURLs.contains(pair.key), let text = pair.value as? String,
                           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
                        result[pair.key] = clean(pair.value)
                    }
                }
                if let list = value as? [Any] { return list.map(clean) }
                return value
            }
            var normalized = object as! [String: Any]
            if let news = normalized["news"] as? [[String: Any]] {
                normalized["news"] = news.compactMap { row -> [String: Any]? in
                    guard let id = row["identifier"] as? String, !id.isEmpty,
                          let title = row["title"] as? String, !title.isEmpty else { return nil }
                    var item = row
                    item["caption"] = row["caption"] as? String ?? ""
                    return item
                }
            }
            // The live Soon feed uses value/label and a separate gameCategories list.
            // Convert only category metadata; app and version/download pairs stay intact.
            if normalized["categories"] is [[String: Any]] || normalized["gameCategories"] is [[String: Any]] {
                var categories: [[String: Any]] = []
                var indices: [String: Int] = [:]
                for key in ["categories", "gameCategories"] {
                    for row in normalized[key] as? [[String: Any]] ?? [] {
                        guard let rawID = row["id"] as? String ?? row["value"] as? String,
                              let rawName = row["name"] as? String ?? row["label"] as? String else { continue }
                        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
                        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !id.isEmpty, !name.isEmpty else { continue }
                        let isGame = key == "gameCategories" || row["isGame"] as? Bool == true
                        if let index = indices[id] {
                            if isGame { categories[index]["isGame"] = true }
                        } else {
                            indices[id] = categories.count
                            categories.append(["id": id, "name": name, "isGame": isGame])
                        }
                    }
                }
                normalized["categories"] = categories
            }
            guard let sanitized = try? JSONSerialization.data(withJSONObject: clean(normalized)),
                  let parsed = try? JSONDecoder().decode(ASRepository.self, from: sanitized) else {
                throw XSignCatalogError.invalidJSON
            }
            repository = parsed
        }
        return XSignRepositoryRecord(repository: repository, fingerprint: Data(SHA256.hash(data: data)))
    }

    private func read(_ path: URL) -> XSignRepositoryRecord? {
        guard let size = (try? path.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size <= Self.maximumBytes,
              let data = try? Data(contentsOf: path, options: .mappedIfSafe) else { return nil }
        return try? Self.decode(data)
    }

    func cached(_ input: URL, includeBundled: Bool = true) -> XSignRepositoryRecord? {
        let url = Self.canonicalURL(input)
        guard !ProtectedSourcesVault.isRetiredSource(url) else { return nil }
        if let result = read(file(url)) { return result }
        guard includeBundled else { return nil }
        guard ProtectedSourcesVault.isPrimarySource(url) else { return nil }
        let legacy = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("XSignInstantStoreCache_v2", isDirectory: true).appendingPathComponent("ashtemobile_cache.json")
        if let result = read(legacy) { return result }
        let seed = "XSignLaunchAshteMobile"
        guard let bundled = bundledResources?.appendingPathComponent(seed + ".json") ?? Bundle.main.url(forResource: seed, withExtension: "json") else { return nil }
        return read(bundled)
    }

    func fetch(_ input: URL) async throws -> XSignRepositoryRecord {
        let url = Self.canonicalURL(input)
        guard !ProtectedSourcesVault.isRetiredSource(url) else { throw XSignCatalogError.invalidURL }
        guard let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme), url.host != nil else {
            throw XSignCatalogError.invalidURL
        }
        let key = url.absoluteString
        if let running = requests[key] { return try await running.value }
        let task = Task { try await self.download(url) }
        requests[key] = task
        defer { requests.removeValue(forKey: key) }
        return try await task.value
    }

    private func download(_ url: URL) async throws -> XSignRepositoryRecord {
        let destination = file(url)
        let tagFile = destination.appendingPathExtension("etag")
        for attempt in 0..<2 {
            var request = URLRequest(url: Self.freshURL(url))
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("AshteMobile/2.0", forHTTPHeaderField: "User-Agent")
            if attempt == 0, FileManager.default.fileExists(atPath: destination.path),
               let tag = try? String(contentsOf: tagFile, encoding: .utf8), !tag.isEmpty {
                request.setValue(tag, forHTTPHeaderField: "If-None-Match")
            }
            let (temporary, response) = try await session.download(for: request)
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard let http = response as? HTTPURLResponse else { throw XSignCatalogError.invalidResponse }
            if http.statusCode == 304 {
                if let result = cached(url, includeBundled: false) { return result }
                continue // A purged/corrupt cache must never make a 304 look like an empty catalog.
            }
            guard (200..<300).contains(http.statusCode) else { throw XSignCatalogError.http(http.statusCode) }
            let length = (try temporary.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            guard length > 0 else { throw XSignCatalogError.invalidResponse }
            guard length <= Self.maximumBytes else { throw XSignCatalogError.tooLarge }
            let data = try Data(contentsOf: temporary, options: .mappedIfSafe)
            let result = try Self.decode(data)
            // Write only a validated source. Network/JSON failures retain the last good file.
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: destination, options: .atomic)
                if let tag = http.value(forHTTPHeaderField: "ETag") {
                    try tag.write(to: tagFile, atomically: true, encoding: .utf8)
                } else {
                    try? FileManager.default.removeItem(at: tagFile)
                }
            } catch {
                // A temporary disk-write failure must not discard a valid in-memory response.
            }
            return result
        }
        throw XSignCatalogError.invalidResponse
    }
}
