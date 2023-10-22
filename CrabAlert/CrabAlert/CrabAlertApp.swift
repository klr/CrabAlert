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
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var socket: WebSocket!
    var statusItem: NSStatusItem?
    var statusMenu: NSMenu!
    var statusMenuItem: NSMenuItem!
    var isConnected: Bool = false {
        didSet {
            updateMenuIcon()
        }
    }

    // MARK: - Lifecycle
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        setupMenuIcon()
        setupNotifications()
        connect()

        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { timer in
            if !self.isConnected {
                self.connect()
            }
        }
    }
    
    // MARK: - Menu Bar Handling
    func setupMenuIcon() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "envelope.fill", accessibilityDescription: "CrabAlert")
        }
        
        statusMenu = NSMenu(title: "Status Menu")
        
        // Menu item for displaying the connection status
        statusMenuItem = NSMenuItem(title: isConnected ? "Connected to MailCrab" : "Waiting for MailCrab...", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false  // Make it unclickable
        statusMenu.addItem(statusMenuItem)
        
        // Separator
        statusMenu.addItem(NSMenuItem.separator())
        
        // Quit menu item
        let quitMenuItem = NSMenuItem(title: "Quit CrabAlert", action: #selector(quitApp), keyEquivalent: "q")
        statusMenu.addItem(quitMenuItem)
        
        statusItem?.menu = statusMenu
    }
    
    func updateMenuIcon() {
        if isConnected {
            statusItem?.button?.image = NSImage(systemSymbolName: "envelope.fill", accessibilityDescription: "CrabAlert")
            statusMenuItem.title = "Connected to MailCrab"
        } else {
            statusItem?.button?.image = NSImage(systemSymbolName: "envelope", accessibilityDescription: "CrabAlert")
            statusMenuItem.title = "Waiting for MailCrab..."
        }
    }
    
    @objc func quitApp() {
        NSApplication.shared.terminate(self)
    }
    
    // MARK: - Web Socket Interaction
    func connect() {
        let request = URLRequest(url: URL(string: "ws://localhost:1080/ws")!)
        socket = WebSocket(request: request)
        socket.delegate = self
        socket.connect()
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
        content.userInfo = ["url": "http://localhost:1080/"]
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
        
        return attributedString.string
    }
}

// MARK: - WebSocketDelegate
extension AppDelegate: WebSocketDelegate {
    func didReceive(event: Starscream.WebSocketEvent, client: Starscream.WebSocketClient) {
        switch event {
        case .connected(let headers):
            print("websocket is connected: \(headers)")

            isConnected = true
        case .disconnected(let reason, let code):
            print("websocket is disconnected: \(reason) with code: \(code)")

            isConnected = false
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

            isConnected = false
        case .error(let error):
            print("Error: \(error?.localizedDescription ?? "Unknown error")")

            isConnected = false
        case .peerClosed:
            print("Peer closed")
            
            isConnected = false
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate
extension AppDelegate: UNUserNotificationCenterDelegate {
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
