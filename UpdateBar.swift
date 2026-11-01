import SwiftUI
import AppKit
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

}

// MARK: - Aggiornamenti di UpdateBar stesso (GitHub Releases)

@MainActor
final class SelfUpdater: ObservableObject {
    static let shared = SelfUpdater()
    static let repo = "AndreaPolazzo/UpdateBar"
    static let dmgURL = URL(string: "https://github.com/\(repo)/releases/latest/download/UpdateBar.dmg")!

    @Published private(set) var latestVersion: String?

    var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Controlla l'ultima Release e, se è più nuova, chiede se scaricarla
    func checkOnLaunch() async {
        guard let latest = await fetchLatest(), Self.isNewer(latest, than: current) else { return }
        latestVersion = latest
        askToUpdate(latest)
    }

    func askToUpdate(_ version: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(format: T.appUpdateTitle, version)
        alert.informativeText = String(format: T.appUpdateBody, current)
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: T.download)
        alert.addButton(withTitle: T.later)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(Self.dmgURL)
        }
    }

    private func fetchLatest() async -> String? {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { return nil }
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// Confronto numerico: 1.10 > 1.9
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

// MARK: - Localizzazione

/// Testi dell'app nella lingua del Mac (inglese se la lingua non è supportata)
enum T {
    private static let keys = ["checking", "error", "upToDate", "restartRequired", "openSoftwareUpdate", "lastCheck", "checkNow", "launchAtLogin", "quit", "updates", "appUpdateTitle", "appUpdateBody", "download", "later", "appUpdateMenu"]
    private static let table: [String: [String]] = [
        "en": ["Checking…", "Error", "macOS is up to date ✓", "restart required", "Open Software Update…", "Last check", "Check Now", "Launch at Login", "Quit", "Updates", "UpdateBar %@ is available", "You have version %@. Download the new version?", "Download", "Later", "Update UpdateBar to %@…"],
        "it": ["Controllo in corso…", "Errore", "macOS è aggiornato ✓", "richiede riavvio", "Apri Aggiornamento Software…", "Ultimo controllo", "Controlla ora", "Avvia al login", "Esci", "Aggiornamenti", "È disponibile UpdateBar %@", "Hai la versione %@. Vuoi scaricare la nuova versione?", "Scarica", "Più tardi", "Aggiorna UpdateBar alla %@…"],
        "es": ["Comprobando…", "Error", "macOS está actualizado ✓", "requiere reinicio", "Abrir Actualización de software…", "Última comprobación", "Comprobar ahora", "Abrir al iniciar sesión", "Salir", "Actualizaciones", "UpdateBar %@ está disponible", "Tienes la versión %@. ¿Descargar la nueva versión?", "Descargar", "Más tarde", "Actualizar UpdateBar a %@…"],
        "fr": ["Vérification…", "Erreur", "macOS est à jour ✓", "redémarrage requis", "Ouvrir Mise à jour de logiciels…", "Dernière vérification", "Vérifier maintenant", "Ouvrir à l’ouverture de session", "Quitter", "Mises à jour", "UpdateBar %@ est disponible", "Vous avez la version %@. Télécharger la nouvelle version ?", "Télécharger", "Plus tard", "Mettre à jour UpdateBar vers %@…"],
        "de": ["Wird geprüft …", "Fehler", "macOS ist aktuell ✓", "Neustart erforderlich", "Softwareupdate öffnen …", "Zuletzt geprüft", "Jetzt prüfen", "Bei Anmeldung öffnen", "Beenden", "Updates", "UpdateBar %@ ist verfügbar", "Du hast Version %@. Neue Version laden?", "Laden", "Später", "UpdateBar auf %@ aktualisieren …"],
        "pt": ["A verificar…", "Erro", "O macOS está atualizado ✓", "requer reinício", "Abrir Atualização de Software…", "Última verificação", "Verificar agora", "Abrir ao iniciar sessão", "Sair", "Atualizações", "O UpdateBar %@ está disponível", "Tem a versão %@. Descarregar a nova versão?", "Descarregar", "Mais tarde", "Atualizar o UpdateBar para %@…"],
        "nl": ["Controleren…", "Fout", "macOS is bijgewerkt ✓", "herstart vereist", "Open Software-update…", "Laatst gecontroleerd", "Controleer nu", "Open bij inloggen", "Stop", "Updates", "UpdateBar %@ is beschikbaar", "Je hebt versie %@. Nieuwe versie downloaden?", "Download", "Later", "Werk UpdateBar bij naar %@…"],
        "sv": ["Söker…", "Fel", "macOS är uppdaterat ✓", "omstart krävs", "Öppna Programuppdatering…", "Senast kontrollerat", "Sök nu", "Öppna vid inloggning", "Avsluta", "Uppdateringar", "UpdateBar %@ finns tillgänglig", "Du har version %@. Hämta den nya versionen?", "Hämta", "Senare", "Uppdatera UpdateBar till %@…"],
        "da": ["Søger…", "Fejl", "macOS er opdateret ✓", "genstart påkrævet", "Åbn Softwareopdatering…", "Sidst tjekket", "Tjek nu", "Åbn ved login", "Slut", "Opdateringer", "UpdateBar %@ er tilgængelig", "Du har version %@. Hent den nye version?", "Hent", "Senere", "Opdater UpdateBar til %@…"],
        "nb": ["Søker …", "Feil", "macOS er oppdatert ✓", "omstart kreves", "Åpne Programvareoppdatering …", "Sist sjekket", "Sjekk nå", "Åpne ved pålogging", "Avslutt", "Oppdateringer", "UpdateBar %@ er tilgjengelig", "Du har versjon %@. Last ned den nye versjonen?", "Last ned", "Senere", "Oppdater UpdateBar til %@ …"],
        "fi": ["Tarkistetaan…", "Virhe", "macOS on ajan tasalla ✓", "vaatii uudelleenkäynnistyksen", "Avaa Ohjelmistopäivitys…", "Viimeksi tarkistettu", "Tarkista nyt", "Avaa sisäänkirjautuessa", "Lopeta", "Päivitykset", "UpdateBar %@ on saatavilla", "Sinulla on versio %@. Ladataanko uusi versio?", "Lataa", "Myöhemmin", "Päivitä UpdateBar versioon %@…"],
        "pl": ["Sprawdzanie…", "Błąd", "macOS jest aktualny ✓", "wymaga ponownego uruchomienia", "Otwórz Uaktualnienia oprogramowania…", "Ostatnio sprawdzono", "Sprawdź teraz", "Otwieraj przy logowaniu", "Zakończ", "Uaktualnienia", "Dostępny jest UpdateBar %@", "Masz wersję %@. Pobrać nową wersję?", "Pobierz", "Później", "Uaktualnij UpdateBar do %@…"],
        "cs": ["Kontroluje se…", "Chyba", "macOS je aktuální ✓", "vyžaduje restart", "Otevřít Aktualizace softwaru…", "Poslední kontrola", "Zkontrolovat nyní", "Otevřít po přihlášení", "Ukončit", "Aktualizace", "Je k dispozici UpdateBar %@", "Máte verzi %@. Stáhnout novou verzi?", "Stáhnout", "Později", "Aktualizovat UpdateBar na %@…"],
        "hu": ["Ellenőrzés…", "Hiba", "A macOS naprakész ✓", "újraindítás szükséges", "Szoftverfrissítés megnyitása…", "Utolsó ellenőrzés", "Ellenőrzés most", "Megnyitás bejelentkezéskor", "Kilépés", "Frissítések", "Elérhető az UpdateBar %@", "A(z) %@ verzió van telepítve. Letöltöd az új verziót?", "Letöltés", "Később", "UpdateBar frissítése erre: %@…"],
        "ru": ["Проверка…", "Ошибка", "macOS обновлена ✓", "требуется перезагрузка", "Открыть «Обновление ПО»…", "Последняя проверка", "Проверить сейчас", "Открывать при входе", "Завершить", "Обновления", "Доступен UpdateBar %@", "У вас версия %@. Загрузить новую версию?", "Загрузить", "Позже", "Обновить UpdateBar до %@…"],
        "uk": ["Перевірка…", "Помилка", "macOS оновлено ✓", "потрібен перезапуск", "Відкрити «Оновлення ПЗ»…", "Остання перевірка", "Перевірити зараз", "Відкривати під час входу", "Вийти", "Оновлення", "Доступний UpdateBar %@", "У вас версія %@. Завантажити нову версію?", "Завантажити", "Пізніше", "Оновити UpdateBar до %@…"],
        "tr": ["Denetleniyor…", "Hata", "macOS güncel ✓", "yeniden başlatma gerekir", "Yazılım Güncelleme’yi Aç…", "Son denetim", "Şimdi Denetle", "Girişte Aç", "Çık", "Güncellemeler", "UpdateBar %@ kullanılabilir", "%@ sürümüne sahipsiniz. Yeni sürüm indirilsin mi?", "İndir", "Daha Sonra", "UpdateBar’ı %@ sürümüne güncelle…"],
        "el": ["Έλεγχος…", "Σφάλμα", "Το macOS είναι ενημερωμένο ✓", "απαιτείται επανεκκίνηση", "Άνοιγμα Ενημέρωσης λογισμικού…", "Τελευταίος έλεγχος", "Έλεγχος τώρα", "Άνοιγμα κατά τη σύνδεση", "Τερματισμός", "Ενημερώσεις", "Το UpdateBar %@ είναι διαθέσιμο", "Έχετε την έκδοση %@. Λήψη της νέας έκδοσης;", "Λήψη", "Αργότερα", "Ενημέρωση του UpdateBar σε %@…"],
        "ja": ["確認中…", "エラー", "macOSは最新です ✓", "再起動が必要", "ソフトウェアアップデートを開く…", "最終確認", "今すぐ確認", "ログイン時に開く", "終了", "アップデート", "UpdateBar %@ が利用可能です", "現在のバージョンは %@ です。新しいバージョンをダウンロードしますか？", "ダウンロード", "あとで", "UpdateBar を %@ にアップデート…"],
        "ko": ["확인 중…", "오류", "macOS가 최신 상태입니다 ✓", "재시동 필요", "소프트웨어 업데이트 열기…", "마지막 확인", "지금 확인", "로그인 시 열기", "종료", "업데이트", "UpdateBar %@ 사용 가능", "현재 버전은 %@입니다. 새 버전을 다운로드하겠습니까?", "다운로드", "나중에", "UpdateBar를 %@(으)로 업데이트…"],
        "zh-Hans": ["正在检查…", "错误", "macOS 已是最新版本 ✓", "需要重新启动", "打开“软件更新”…", "上次检查", "立即检查", "登录时打开", "退出", "更新", "UpdateBar %@ 现已推出", "你的版本为 %@。要下载新版本吗？", "下载", "以后", "将 UpdateBar 更新到 %@…"],
        "zh-Hant": ["正在檢查⋯", "錯誤", "macOS 已是最新版本 ✓", "需要重新啟動", "打開「軟體更新」⋯", "上次檢查", "立即檢查", "登入時打開", "結束", "更新項目", "UpdateBar %@ 現已推出", "你的版本為 %@。要下載新版本嗎？", "下載", "稍後", "將 UpdateBar 更新至 %@⋯"],
        "ar": ["جارٍ التحقق…", "خطأ", "macOS محدّث ✓", "يتطلب إعادة التشغيل", "فتح تحديث البرامج…", "آخر تحقق", "تحقق الآن", "فتح عند تسجيل الدخول", "إنهاء", "التحديثات", "يتوفر UpdateBar ‏%@", "لديك الإصدار %@. هل تريد تنزيل الإصدار الجديد؟", "تنزيل", "لاحقًا", "تحديث UpdateBar إلى %@…"],
    ]

    private static let strings: [String: String] = {
        let lang = Locale.preferredLanguages.first ?? "en"
        let code: String
        if lang.hasPrefix("zh") {
            code = (lang.contains("Hant") || lang.hasSuffix("TW") || lang.hasSuffix("HK") || lang.hasSuffix("MO")) ? "zh-Hant" : "zh-Hans"
        } else if lang.hasPrefix("no") || lang.hasPrefix("nn") {
            code = "nb"
        } else {
            code = String(lang.prefix(2))
        }
        let values = table[code] ?? table["en"]!
        return Dictionary(uniqueKeysWithValues: zip(keys, values))
    }()

    static var checking: String { strings["checking"]! }
    static var error: String { strings["error"]! }
    static var upToDate: String { strings["upToDate"]! }
    static var restartRequired: String { strings["restartRequired"]! }
    static var openSoftwareUpdate: String { strings["openSoftwareUpdate"]! }
    static var lastCheck: String { strings["lastCheck"]! }
    static var checkNow: String { strings["checkNow"]! }
    static var launchAtLogin: String { strings["launchAtLogin"]! }
    static var quit: String { strings["quit"]! }
    static var updates: String { strings["updates"]! }
    static var appUpdateTitle: String { strings["appUpdateTitle"]! }
    static var appUpdateBody: String { strings["appUpdateBody"]! }
    static var download: String { strings["download"]! }
    static var later: String { strings["later"]! }
    static var appUpdateMenu: String { strings["appUpdateMenu"]! }
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

/// Icona stile Windows Update: due frecce spesse (stessa forma dell'icona dell'app) + puntino colorato
enum StatusIcon {
    // Geometria dell'icona dell'app (spazio 1024×1024, y verso il basso)
    private static let c: CGFloat = 512, r: CGFloat = 232, stroke: CGFloat = 78
    private static let arcs: [(CGFloat, CGFloat)] = [(165, 32), (345, 212)]
    private static let heads: [[CGPoint]] = [
        [CGPoint(x: 756.4, y: 465.4), CGPoint(x: 781.9, y: 308.0), CGPoint(x: 603.8, y: 419.3)],
        [CGPoint(x: 267.6, y: 558.6), CGPoint(x: 242.1, y: 716.0), CGPoint(x: 420.2, y: 604.7)],
    ]

    static func make(_ state: BadgeState, dimmed: Bool) -> NSImage {
        let size = NSSize(width: 20, height: 17)

        let image = NSImage(size: size, flipped: true) { rect in
            // 1024 → punti, centrato
            let s: CGFloat = 16.5 / 560
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: rect.midX + (x - c) * s, y: rect.midY + (y - c) * s)
            }

            NSColor.labelColor.withAlphaComponent(dimmed ? 0.45 : 1).set()

            // archi
            for (a0, a1) in arcs {
                let path = NSBezierPath()
                path.lineWidth = stroke * s
                path.lineCapStyle = .round
                let steps = 32
                for i in 0...steps {
                    let deg = a0 + (a1 - a0) * CGFloat(i) / CGFloat(steps)
                    let rad = deg * .pi / 180
                    let pt = p(c + r * cos(rad), c - r * sin(rad))
                    i == 0 ? path.move(to: pt) : path.line(to: pt)
                }
                path.stroke()
            }

            // punte
            for tri in heads {
                let path = NSBezierPath()
                path.move(to: p(tri[0].x, tri[0].y))
                path.line(to: p(tri[1].x, tri[1].y))
                path.line(to: p(tri[2].x, tri[2].y))
                path.close()
                path.lineWidth = 18 * s
                path.lineJoinStyle = .round
                path.fill()
                path.stroke()
            }

            // puntino in basso a destra, con bordo trasparente
            guard let color = state.color else { return true }
            let d: CGFloat = 7
            let center = p(742, 742)
            let dot = NSRect(x: min(center.x - d / 2, rect.maxX - d - 0.5),
                             y: min(center.y - d / 2, rect.maxY - d - 0.5),
                             width: d, height: d)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            color.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = T.updates
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
    @ObservedObject var selfUpdater: SelfUpdater

    var body: some View {
        if let v = selfUpdater.latestVersion {
            Button(String(format: T.appUpdateMenu, v)) { NSWorkspace.shared.open(SelfUpdater.dmgURL) }
            Divider()
        }

        if checker.isChecking {
            Text(T.checking)
        } else if let err = checker.lastError {
            Text("\(T.error): \(err)")
        } else if checker.updates.isEmpty {
            Text(T.upToDate)
        } else {
            ForEach(checker.updates) { u in
                Button(u.needsRestart ? "\(u.title) — \(T.restartRequired)" : u.title) {
                    checker.openSoftwareUpdate()
                }
            }
            Divider()
            Button(T.openSoftwareUpdate) { checker.openSoftwareUpdate() }
        }

        if let last = checker.lastCheck {
            Text("\(T.lastCheck): \(last.formatted(date: .omitted, time: .shortened))")
        }

        Divider()

        Button(T.checkNow) { Task { await checker.check() } }
            .keyboardShortcut("r")
            .disabled(checker.isChecking)

        Toggle(T.launchAtLogin, isOn: $checker.launchAtLogin)

        Divider()

        Button(T.quit) { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

// MARK: - App

@main
struct UpdateBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var checker = UpdateChecker()
    @ObservedObject private var selfUpdater = SelfUpdater.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(checker: checker, selfUpdater: selfUpdater)
        } label: {
            MenuBarLabel(checker: checker)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // All'avvio: c'è una nuova versione di UpdateBar?
        Task { @MainActor in await SelfUpdater.shared.checkOnLaunch() }
    }
}
