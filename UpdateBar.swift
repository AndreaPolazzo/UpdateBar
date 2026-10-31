import SwiftUI
import AppKit
import UserNotifications
import ServiceManagement

// MARK: - Modello

struct SystemUpdate: Identifiable, Hashable {
    let id: String          // Label di softwareupdate
    let title: String
    let version: String
    let needsRestart: Bool

    var isMacOS: Bool { title.lowercased().hasPrefix("macos") }

    /// Versione principale (es. 27 da "27.2"), se è un update di macOS
    var macOSMajor: Int? {
        guard isMacOS else { return nil }
        let source = version.isEmpty ? title : version
        let digits = source.split(whereSeparator: { !$0.isNumber })
        return digits.compactMap { Int($0) }.first(where: { $0 >= 10 })
    }

    var kind: BadgeState {
        guard isMacOS else { return .other }
        let current = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        if let major = macOSMajor, major > current { return .major }
        return .minor
    }
}

// MARK: - Checker

@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var updates: [SystemUpdate] = []
    @Published private(set) var isChecking = false
    @Published private(set) var lastCheck: Date?
    @Published private(set) var lastError: String?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            guard launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    var badge: BadgeState {
        updates.map(\.kind).max() ?? .none
    }

    /// Ogni quanto controllare (secondi)
    private let interval: TimeInterval = 4 * 60 * 60
    private var timer: Timer?
    private var alreadyNotified: Set<String> = []

    init() {
        Task { await check() }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
    }

    func check() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        do {
            let output = try await Self.runSoftwareUpdate()
            let found = Self.parse(output)
            updates = found
            lastError = nil
            lastCheck = Date()
            notifyIfNew(found)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func openSoftwareUpdate() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: softwareupdate

    nonisolated static func runSoftwareUpdate() async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/softwareupdate")
            process.arguments = ["--list"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe   // "No new software available." finisce su stderr
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                cont.resume(returning: String(decoding: data, as: UTF8.self))
            }
            do {
                try process.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    /// Esempio di output:
    /// * Label: macOS Sequoia 15.2-24C101
    ///     Title: macOS Sequoia 15.2, Version: 15.2, Size: 3045632KiB, Recommended: YES, Action: restart,
    nonisolated static func parse(_ output: String) -> [SystemUpdate] {
        var result: [SystemUpdate] = []
        var currentLabel: String?

        for raw in output.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("* Label:") {
                currentLabel = String(line.dropFirst("* Label:".count))
                    .trimmingCharacters(in: .whitespaces)
            } else if let label = currentLabel, line.hasPrefix("Title:") {
                let f = fields(line)
                result.append(SystemUpdate(
                    id: label,
                    title: f["Title"] ?? label,
                    version: f["Version"] ?? "",
                    needsRestart: f["Action"]?.lowercased() == "restart"
                ))
                currentLabel = nil
            }
        }
        return result
    }

    nonisolated static func fields(_ line: String) -> [String: String] {
        var dict: [String: String] = [:]
        for part in line.split(separator: ",") {
            let kv = part.split(separator: ":", maxSplits: 1)
            guard kv.count == 2 else { continue }
            dict[kv[0].trimmingCharacters(in: .whitespaces)] = kv[1].trimmingCharacters(in: .whitespaces)
        }
        return dict
    }

    // MARK: Notifiche

    private func notifyIfNew(_ found: [SystemUpdate]) {
        let new = found.filter { !alreadyNotified.contains($0.id) }
        guard !new.isEmpty else { return }
        alreadyNotified.formUnion(new.map(\.id))

        let content = UNMutableNotificationContent()
        content.title = new.count == 1
            ? "Aggiornamento macOS disponibile"
            : "\(new.count) aggiornamenti macOS disponibili"
        content.body = new.map(\.title).joined(separator: "\n")
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - UI

/// Ordinate per importanza: vince la più alta
enum BadgeState: Int, Comparable {
    case none, other, minor, major
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    var color: NSColor? {
        switch self {
        case .none:  return nil
        case .other: return NSColor(red: 0.0, green: 0.55, blue: 1.0, alpha: 1)   // blu
        case .minor: return NSColor(red: 1.0, green: 0.78, blue: 0.0, alpha: 1)   // giallo
        case .major: return NSColor.systemRed                                     // rosso
        }
    }
}

/// Icona stile Windows Update: due frecce + puntino colorato
enum StatusIcon {
    static func make(_ state: BadgeState, dimmed: Bool) -> NSImage {
        let size = NSSize(width: 20, height: 16)
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let symbol = NSImage(systemSymbolName: "arrow.triangle.2.circlepath",
                             accessibilityDescription: "Aggiornamenti")!
            .withSymbolConfiguration(config)!

        let image = NSImage(size: size, flipped: false) { rect in
            // frecce, colorate col colore del testo della menu bar (chiaro/scuro)
            let s = symbol.size
            let r = NSRect(x: (rect.width - s.width) / 2, y: (rect.height - s.height) / 2,
                           width: s.width, height: s.height)
            symbol.draw(in: r)
            NSColor.labelColor.withAlphaComponent(dimmed ? 0.45 : 1).setFill()
            rect.fill(using: .sourceAtop)

            guard let color = state.color else { return true }
            let d: CGFloat = 7
            let dot = NSRect(x: rect.maxX - d - 0.5, y: 0.5, width: d, height: d)
            // bordo trasparente attorno al puntino, come su Windows
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            color.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

struct MenuBarLabel: View {
    @ObservedObject var checker: UpdateChecker

    var body: some View {
        Image(nsImage: StatusIcon.make(checker.badge, dimmed: checker.isChecking))
    }
}

struct MenuContent: View {
    @ObservedObject var checker: UpdateChecker

    var body: some View {
        if checker.isChecking {
            Text("Controllo in corso…")
        } else if let err = checker.lastError {
            Text("Errore: \(err)")
        } else if checker.updates.isEmpty {
            Text("macOS è aggiornato ✓")
        } else {
            ForEach(checker.updates) { u in
                Button(u.needsRestart ? "\(u.title) — richiede riavvio" : u.title) {
                    checker.openSoftwareUpdate()
                }
            }
            Divider()
            Button("Apri Aggiornamento Software…") { checker.openSoftwareUpdate() }
        }

        if let last = checker.lastCheck {
            Text("Ultimo controllo: \(last.formatted(date: .omitted, time: .shortened))")
        }

        Divider()

        Button("Controlla ora") { Task { await checker.check() } }
            .keyboardShortcut("r")
            .disabled(checker.isChecking)

        Toggle("Avvia al login", isOn: $checker.launchAtLogin)

        Divider()

        Button("Esci") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

// MARK: - App

@main
struct UpdateBarApp: App {
    @StateObject private var checker = UpdateChecker()

    init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(checker: checker)
        } label: {
            MenuBarLabel(checker: checker)
        }
    }
}
