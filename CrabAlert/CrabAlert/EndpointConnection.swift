//
//  EndpointConnection.swift
//  CrabAlert
//

import AppKit

// MARK: - Incoming Message Struct
struct IncomingMessage: Codable {
    let id: String
    let from: Contact
    let to: [Contact]
    let subject: String
    let time: Int
    let date: String
    let size: String
    let opened: Bool
    let has_html: Bool
    let has_plain: Bool
    let attachments: [String]
    var body: String?

    struct Contact: Codable {
        let name: String?
        let email: String
    }
}

// MARK: - Endpoint Connection
/// Maintains the WebSocket connection to a single MailCrab endpoint.
final class EndpointConnection: NSObject, ObservableObject {
    let endpoint: Endpoint
    var onMessage: ((IncomingMessage, Endpoint) -> Void)?

    @Published private(set) var isConnected = false

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?

    init(endpoint: Endpoint) {
        self.endpoint = endpoint
        super.init()
    }

    deinit {
        tearDown()
    }

    func connect() {
        // Tear down any previous attempt so stale sockets don't pile up or report state.
        tearDown()

        // The session retains its delegate until invalidated, which tearDown() does.
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        let task = session.webSocketTask(with: endpoint.webSocketURL)
        self.session = session
        self.task = task
        task.resume()
        receive(on: task)
    }

    func disconnect() {
        tearDown()
        setConnectionState(false)
    }

    private func tearDown() {
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
    }

    /// URLSessionWebSocketTask delivers one message per receive call, so re-arm after each one.
    /// A failure here is how a dropped connection surfaces.
    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self, task === self.task else { return }

            switch result {
            case .success(.string(let text)):
                print("[\(self.endpoint.name)] Received text: \(text)")
                self.handle(text: text)
            case .success(.data(let data)):
                print("[\(self.endpoint.name)] Received data: \(data.count)")
            case .success:
                break
            case .failure(let error):
                print("[\(self.endpoint.name)] Receive failed: \(error.localizedDescription)")
                self.setConnectionState(false)
                return
            }

            self.receive(on: task)
        }
    }

    private func setConnectionState(_ connected: Bool) {
        DispatchQueue.main.async {
            if self.isConnected != connected {
                self.isConnected = connected
            }
        }
    }

    // MARK: - Message Handling
    private func handle(text: String) {
        guard let data = text.data(using: .utf8),
              var message = Self.parseIncomingMessage(data: data) else { return }

        fetchMessageBody(for: message.id) { body, error in
            if let error = error {
                print("[\(self.endpoint.name)] Error fetching body: \(error)")
            } else if let body = body, let plainText = Self.convertHTMLToPlainText(html: body) {
                message.body = plainText
                self.onMessage?(message, self.endpoint)
            }
        }
    }

    static func parseIncomingMessage(data: Data) -> IncomingMessage? {
        do {
            return try JSONDecoder().decode(IncomingMessage.self, from: data)
        } catch {
            print("Error parsing JSON: \(error)")
            return nil
        }
    }

    private func fetchMessageBody(for id: String, completion: @escaping (String?, Error?) -> Void) {
        let task = URLSession.shared.dataTask(with: endpoint.bodyURL(for: id)) { data, _, error in
            guard error == nil else {
                completion(nil, error)
                return
            }

            guard let data = data,
                  let body = String(data: data, encoding: .utf8) else {
                completion(nil, NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch body"]))
                return
            }

            completion(body, nil)
        }

        task.resume()
    }

    static func convertHTMLToPlainText(html: String) -> String? {
        guard let data = html.data(using: .utf8) else {
            return nil
        }

        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]

        guard let attributedString = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else {
            return nil
        }

        // Replace newlines with spaces and trim whitespace
        let plainText = attributedString.string
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Limit to 200 characters
        return plainText.count > 200 ? String(plainText.prefix(200)) : plainText
    }
}

// MARK: - URLSessionWebSocketDelegate
extension EndpointConnection: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        // Ignore events from sockets we've already replaced.
        guard webSocketTask === task else { return }
        print("[\(endpoint.name)] websocket is connected")
        setConnectionState(true)
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        guard webSocketTask === task else { return }
        print("[\(endpoint.name)] websocket is disconnected with code: \(closeCode.rawValue)")
        setConnectionState(false)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === self.task else { return }
        if let error {
            print("[\(endpoint.name)] Error: \(error.localizedDescription)")
        }
        setConnectionState(false)
    }
}
