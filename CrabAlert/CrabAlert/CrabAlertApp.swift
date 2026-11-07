//
//  CrabAlertApp.swift
//  CrabAlert
//
//  Created by Karl Roos on 2023-10-21.
//

import SwiftUI
import Combine
import UserNotifications

@main
struct CrabAlertApp: App {
    @NSApplicationDelegateAdaptor(WindowlessAppDelegate.self) private var appDelegate
    @StateObject private var crabAlert = CrabAlertModel()

    var body: some Scene {
        MenuBarExtra {
            CrabAlertMenu(crabAlert: crabAlert)
        } label: {
            Label("CrabAlert", systemImage: crabAlert.anyConnected ? "envelope.fill" : "envelope")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(store: crabAlert.store)
        }
    }
}

// MARK: - Menu
struct CrabAlertMenu: View {
    @ObservedObject var crabAlert: CrabAlertModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let connected = crabAlert.connections.filter(\.isConnected)

        if connected.isEmpty {
            WaitingRow(indicator: crabAlert.waitingIndicator)
        } else {
            ForEach(connected, id: \.endpoint.id) { connection in
                let endpoint = connection.endpoint
                Button {
                    crabAlert.openInbox(for: endpoint)
                } label: {
                    statusLabel(endpoint.isDefault ? "Connected to MailCrab" : "Connected to \(endpoint.name)",
                                color: .systemGreen)
                }
            }
        }

        Divider()

        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit CrabAlert", action: crabAlert.quitApp)
            .keyboardShortcut("q")
    }

    private func statusLabel(_ title: String, color: NSColor) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(nsImage: CrabAlertModel.statusIndicatorImage(color: color))
                .renderingMode(.original)
        }
    }
}

/// "Waiting for MailCrab..." row whose dot slowly pulses between grey and yellow.
/// Observes only the indicator so the pulse doesn't re-render the rest of the menu.
struct WaitingRow: View {
    @ObservedObject var indicator: WaitingIndicator

    var body: some View {
        Button(action: {}) {
            Label {
                Text("Waiting for MailCrab...")
            } icon: {
                Image(nsImage: CrabAlertModel.statusIndicatorImage(color: indicator.color))
                    .renderingMode(.original)
            }
        }
        .disabled(true)
    }
}

// MARK: - Waiting Indicator
final class WaitingIndicator: ObservableObject {
    static let period: TimeInterval = 2.0
    private static let grey = NSColor.systemGray.usingColorSpace(.sRGB) ?? .gray
    private static let yellow = NSColor.systemYellow.usingColorSpace(.sRGB) ?? .yellow

    @Published private(set) var color: NSColor = WaitingIndicator.grey

    private var timer: Timer?
    private var startDate = Date()

    func start() {
        guard timer == nil else { return }
        startDate = Date()

        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // .common so it keeps firing while the menu is open (event-tracking run loop mode).
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        color = Self.grey
    }

    private func tick() {
        let elapsed = Date().timeIntervalSince(startDate)
        // 0 → 1 → 0 over one period, eased.
        let fraction = (1 - cos(elapsed * 2 * .pi / Self.period)) / 2
        color = Self.grey.blended(withFraction: fraction, of: Self.yellow) ?? Self.grey
    }
}

// MARK: - Menu Item Image Visibility
/// From macOS 27, AppKit hides menu item images unless the item opts in, which would hide
/// the status dots. SwiftUI has no modifier for this, so opt in on the underlying
/// NSMenuItems as SwiftUI adds them or changes their image.
enum MenuItemImageVisibility {
    private static var observers: [NSObjectProtocol] = []

    static func install() {
        guard #available(macOS 27.0, *), observers.isEmpty else { return }

        let names: [Notification.Name] = [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let menu = note.object as? NSMenu,
                      let index = note.userInfo?["NSMenuItemIndex"] as? Int,
                      menu.items.indices.contains(index) else { return }

                let item = menu.items[index]
                if item.image != nil, item.preferredImageVisibility != .visible {
                    item.preferredImageVisibility = .visible
                }
            }
        }
    }
}

// MARK: - App Delegate
class WindowlessAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        MenuItemImageVisibility.install()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        return false
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }
}

// MARK: - CrabAlert Controller
final class CrabAlertModel: NSObject, ObservableObject {
    let store: EndpointStore
    let waitingIndicator = WaitingIndicator()

    @Published private(set) var connections: [EndpointConnection] = []

    private var reconnectTimer: Timer?
    private var storeSubscription: AnyCancellable?
    private var connectionSubscriptions: [UUID: AnyCancellable] = [:]

    var anyConnected: Bool { connections.contains(where: \.isConnected) }

    // MARK: - Lifecycle
    init(store: EndpointStore = EndpointStore()) {
        self.store = store
        super.init()
        setupNotifications()

        // $custom emits the current value immediately, which creates the initial connections.
        storeSubscription = store.$custom
            .receive(on: DispatchQueue.main)
            .sink { [weak self] custom in
                self?.syncConnections(with: [.default] + custom)
            }

        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.connections
                .filter { !$0.isConnected }
                .forEach { $0.connect() }
        }
    }

    deinit {
        reconnectTimer?.invalidate()
        connections.forEach { $0.disconnect() }
    }

    /// Reconciles live connections with the configured endpoints: keeps unchanged ones,
    /// disconnects removed ones and connects new ones.
    private func syncConnections(with endpoints: [Endpoint]) {
        let existing = Dictionary(uniqueKeysWithValues: connections.map { ($0.endpoint.id, $0) })

        let updated = endpoints.map { endpoint -> EndpointConnection in
            if let connection = existing[endpoint.id], connection.endpoint == endpoint {
                return connection
            }

            let connection = EndpointConnection(endpoint: endpoint)
            connection.onMessage = { [weak self] message, endpoint in
                self?.showNotification(with: message, from: endpoint)
            }
            connectionSubscriptions[endpoint.id] = connection.objectWillChange
                .sink { [weak self] _ in
                    self?.objectWillChange.send()
                    // objectWillChange fires before the value changes; read it afterwards.
                    DispatchQueue.main.async { self?.updateWaitingIndicator() }
                }
            connection.connect()
            return connection
        }

        let keptIDs = Set(updated.map { ObjectIdentifier($0) })
        for connection in connections where !keptIDs.contains(ObjectIdentifier(connection)) {
            connection.disconnect()
            if !endpoints.contains(where: { $0.id == connection.endpoint.id }) {
                connectionSubscriptions[connection.endpoint.id] = nil
            }
        }

        connections = updated
        updateWaitingIndicator()
    }

    private func updateWaitingIndicator() {
        if anyConnected {
            waitingIndicator.stop()
        } else {
            waitingIndicator.start()
        }
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

    func openInbox(for endpoint: Endpoint) {
        NSWorkspace.shared.open(endpoint.inboxURL)
    }

    func quitApp() {
        NSApplication.shared.terminate(self)
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

    func showNotification(with message: IncomingMessage, from endpoint: Endpoint) {
        let content = UNMutableNotificationContent()
        content.title = message.subject
        content.subtitle = store.custom.isEmpty
            ? "From: \(message.from.email)"
            : "\(endpoint.name) · From: \(message.from.email)"
        content.body = message.body ?? ""
        content.userInfo = ["url": endpoint.inboxURL.absoluteString]
        content.threadIdentifier = endpoint.id.uuidString
        content.sound = UNNotificationSound.default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Error showing notification: \(error.localizedDescription)")
            }
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
