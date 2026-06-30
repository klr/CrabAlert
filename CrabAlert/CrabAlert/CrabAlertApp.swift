//
//  CrabAlertApp.swift
//  CrabAlert
//
//  Created by Karl Roos on 2023-10-21.
//

import SwiftUI
import Starscream
import UserNotifications

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

@main
struct CrabAlertApp: App {
    @NSApplicationDelegateAdaptor(WindowlessAppDelegate.self) private var appDelegate
    @StateObject private var crabAlert = CrabAlertModel()

    var body: some Scene {
        MenuBarExtra {
            if crabAlert.isConnected {
                Button(action: crabAlert.openMailCrabInbox) {
                    Label {
                        Text("Connected to MailCrab")
                    } icon: {
                        Image(nsImage: CrabAlertModel.statusIndicatorImage(color: .systemGreen))
                            .renderingMode(.original)
                    }
                }
            } else {
                Button(action: {}) {
                    Label {
                        Text("Waiting for MailCrab...")
                    } icon: {
                        Image(nsImage: CrabAlertModel.statusIndicatorImage(color: .systemGray))
                            .renderingMode(.original)
                    }
                }
                .disabled(true)
            }

            Divider()

            Button("Quit CrabAlert", action: crabAlert.quitApp)
                .keyboardShortcut("q")
        } label: {
            Label("CrabAlert", systemImage: crabAlert.isConnected ? "envelope.fill" : "envelope")
        }
        .menuBarExtraStyle(.menu)
    }
}

// MARK: - App Delegate
class WindowlessAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        return false
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }
}

// MARK: - CrabAlert Controller
class CrabAlertModel: NSObject, ObservableObject {
    private let mailCrabInboxURL = URL(string: "http://localhost:1080/")!
    private var socket: WebSocket?
    private var reconnectTimer: Timer?

    @Published var isConnected = false

    // MARK: - Lifecycle
    override init() {
        super.init()
        setupNotifications()
        connect()

        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self else { return }

            if !self.isConnected {
                self.connect()
            }
        }
    }

    deinit {
        reconnectTimer?.invalidate()
        socket?.disconnect()
    }

    // MARK: - Menu Bar Handling
    static func statusIndicatorImage(color: NSColor) -> NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size, flipped: false) { rect in
            let dotRect = NSRect(x: rect.midX - 4, y: rect.midY - 4, width: 8, height: 8)
            color.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    func openMailCrabInbox() {
        NSWorkspace.shared.open(mailCrabInboxURL)
    }

    func quitApp() {
        NSApplication.shared.terminate(self)
    }
    
    // MARK: - Web Socket Interaction
    func connect() {
        let request = URLRequest(url: URL(string: "ws://localhost:1080/ws")!)
        let socket = WebSocket(request: request)
        socket.delegate = self
        self.socket = socket
        socket.connect()
    }

    func setConnectionState(_ connected: Bool) {
        DispatchQueue.main.async {
            self.isConnected = connected
        }
    }
    
    // MARK: - Notifications
    func setupNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("Error requesting notification permissions: \(error.localizedDescription)")
            }
        }
        
        // Delegate notification actions to self
        UNUserNotificationCenter.current().delegate = self
    }
    
    func showNotification(with message: IncomingMessage) {
        let content = UNMutableNotificationContent()
        content.title = message.subject
        content.subtitle = "From: \(message.from.email)"
        content.body = message.body ?? ""
        content.userInfo = ["url": mailCrabInboxURL.absoluteString]
        content.sound = UNNotificationSound.default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Error showing notification: \(error.localizedDescription)")
            }
        }
    }
    
    func parseIncomingMessage(data: Data) -> IncomingMessage? {
        let decoder = JSONDecoder()
        do {
            let message = try decoder.decode(IncomingMessage.self, from: data)
            return message
        } catch {
            print("Error parsing JSON: \(error)")
            return nil
        }
    }
    
    func fetchMessageBody(for id: String, completion: @escaping (String?, Error?) -> Void) {
        let baseURL = "http://localhost:1080/api/message"
        let url = URL(string: "\(baseURL)/\(id)/body")!
        
        let task = URLSession.shared.dataTask(with: url) { (data, response, error) in
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
    
    func convertHTMLToPlainText(html: String) -> String? {
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

// MARK: - WebSocketDelegate
extension CrabAlertModel: WebSocketDelegate {
    func didReceive(event: Starscream.WebSocketEvent, client: Starscream.WebSocketClient) {
        switch event {
        case .connected(let headers):
            print("websocket is connected: \(headers)")

            setConnectionState(true)
        case .disconnected(let reason, let code):
            print("websocket is disconnected: \(reason) with code: \(code)")

            setConnectionState(false)
        case .text(let text):
            print("Received text: \(text)")
            
            if let data = text.data(using: .utf8), var message = parseIncomingMessage(data: data) {
                fetchMessageBody(for: message.id) { (body, error) in
                    if let error = error {
                        print("Error fetching body: \(error)")
                    } else if let body = body {
                        if let plainText = self.convertHTMLToPlainText(html: body) {
                            message.body = plainText
                            self.showNotification(with: message)
                        }
                    }
                }
            }
        case .binary(let data):
            print("Received data: \(data.count)")
        case .ping:
            break
        case .pong:
            break
        case .viabilityChanged(let isViable):
            print("Network viability changed: \(isViable)")
        case .reconnectSuggested(let shouldReconnect):
            print("Reconnect suggested: \(shouldReconnect)")
        case .cancelled:
            print("Websocket was cancelled")

            setConnectionState(false)
        case .error(let error):
            print("Error: \(error?.localizedDescription ?? "Unknown error")")

            setConnectionState(false)
        case .peerClosed:
            print("Peer closed")
            
            setConnectionState(false)
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate
extension CrabAlertModel: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let urlString = response.notification.request.content.userInfo["url"] as? String,
           let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
        completionHandler()
    }
}
