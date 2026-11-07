//
//  Endpoint.swift
//  CrabAlert
//

import Foundation
import Combine

// MARK: - Endpoint
struct Endpoint: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var baseURL: URL

    static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let `default` = Endpoint(id: defaultID, name: "Default", baseURL: URL(string: "http://localhost:1080")!)

    init(id: UUID = UUID(), name: String, baseURL: URL) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
    }

    var isDefault: Bool { id == Endpoint.defaultID }

    /// Host and port (plus any base path) without the scheme, e.g. `localhost:1080`.
    var displayAddress: String {
        let absolute = baseURL.absoluteString
        if let range = absolute.range(of: "://") {
            return String(absolute[range.upperBound...])
        }
        return absolute
    }

    var inboxURL: URL {
        appending(path: "/")
    }

    var webSocketURL: URL {
        var components = URLComponents(url: appending(path: "/ws"), resolvingAgainstBaseURL: false)!
        components.scheme = baseURL.scheme?.lowercased() == "https" ? "wss" : "ws"
        return components.url!
    }

    func bodyURL(for messageID: String) -> URL {
        appending(path: "/api/message/\(messageID)/body")
    }

    private func appending(path: String) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = components.path + path
        return components.url!
    }

    /// Parses user input into a normalized base URL. Accepts `host:port` (assumes http),
    /// requires an http/https scheme and a host, and strips trailing slashes.
    static func parse(_ input: String) -> URL? {
        var string = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !string.isEmpty else { return nil }

        if !string.contains("://") {
            string = "http://" + string
        }

        guard var components = URLComponents(string: string),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else {
            return nil
        }

        components.scheme = scheme
        components.query = nil
        components.fragment = nil
        while components.path.hasSuffix("/") {
            components.path.removeLast()
        }

        return components.url
    }
}

// MARK: - Endpoint Store
final class EndpointStore: ObservableObject {
    static let storageKey = "customEndpoints"

    private let defaults: UserDefaults

    @Published private(set) var custom: [Endpoint] {
        didSet { save() }
    }

    var all: [Endpoint] { [.default] + custom }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([Endpoint].self, from: data) {
            custom = decoded.filter { !$0.isDefault }
        } else {
            custom = []
        }
    }

    /// Adds an endpoint. Returns a user-facing error message if the input is invalid.
    @discardableResult
    func add(name: String, urlString: String) -> String? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return "Please enter a name."
        }
        guard let url = Endpoint.parse(urlString) else {
            return "Please enter a valid http:// or https:// URL."
        }
        if let existing = all.first(where: { $0.baseURL == url }) {
            return "\(existing.displayAddress) is already added as “\(existing.name)”."
        }

        custom.append(Endpoint(name: trimmedName, baseURL: url))
        return nil
    }

    func remove(ids: Set<Endpoint.ID>) {
        custom.removeAll { ids.contains($0.id) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(custom) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}
