import AppKit
import Foundation

// VPN-dispatcher — menubar-приложение.
// Данные нод/панелей берутся из ~/.config/vpn-dispatcher/config.json;
// если его нет — используются placeholder-серверы (example.com) из этого файла.
// Сетевые пробы: только через реальный NIC (ipconfig getifaddr en*), не через
// route default — при VPN TUN ответы подделываются (ping 0.3 мс фальш).

struct Server {
    let name: String
    let host: String
    let role: String
    init(name: String, host: String, role: String) { self.name = name; self.host = host; self.role = role }
}

struct AppConfig {
    var servers: [Server] = [
        Server(name: "example", host: "example.com", role: "пример")
    ]
    var panels: [(String, String)] = [("Example", "https://example.com/")]
    var paths: (log: String, problems: String, checker: String) = (
        NSHomeDirectory() + "/automation/logs/health.log",
        NSHomeDirectory() + "/automation/logs/health-last-problem.txt",
        NSHomeDirectory() + "/automation/server_health.py"
    )

    static func load() -> AppConfig {
        var c = AppConfig()
        let cfgPath = NSHomeDirectory() + "/.config/vpn-dispatcher/config.json"
        guard let data = FileManager.default.contents(atPath: cfgPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return c }
        if let list = obj["servers"] as? [[String: String]] {
            c.servers = list.filter { $0["host"] != nil }.map {
                Server(name: $0["name"] ?? "?", host: $0["host"]!, role: $0["role"] ?? "")
            }
        }
        if let panels = obj["panels"] as? [[String: String]] {
            c.panels = panels.compactMap { p in
                guard let t = p["title"], let u = p["url"] else { return nil }
                return (t, u)
            }
        }
        if let paths = obj["paths"] as? [String: String] {
            c.paths.log = paths["log"] ?? c.paths.log
            c.paths.problems = paths["problems"] ?? c.paths.problems
            c.paths.checker = paths["checker"] ?? c.paths.checker
        }
        return c
    }
}

let config = AppConfig.load()

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    let queue = DispatchQueue.global(qos: .utility)
    // host -> ("12,3 мс" | "нет ответа" | "проверяется…")
    var results:[String: String] = [:]
    var serverItems: [NSMenuItem] = []
    var headerItem: NSMenuItem!
    var statusItemTitle = ""
    var problemsItem: NSMenuItem!

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🛰 …"
        statusItem.menu = makeMenu()
        statusItem.menu?.delegate = self
        refreshAll()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshAll()
        }
    }

    // MARK: построение меню

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "VPN-dispatcher", action: nil, keyEquivalent: ""))
        headerItem = NSMenuItem(title: "Обновляется…", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(.separator())

        for s in config.servers {
            let item = NSMenuItem(title: "\(s.name) — проверяется…", action: #selector(openServer(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = s.host
            item.toolTip = "\(s.role) · \(s.host)"
            serverItems.append(item)
            menu.addItem(item)
        }
        menu.addItem(.separator())

        problemsItem = NSMenuItem(title: "Проблемы: проверяются…", action: nil, keyEquivalent: "")
        problemsItem.isEnabled = false
        menu.addItem(problemsItem)

        let run = NSMenuItem(title: "Проверить серверы сейчас (health-check)", action: #selector(runChecker(_:)), keyEquivalent: "r")
        run.target = self
        menu.addItem(run)

        menu.addItem(.separator())
        for (title, url) in config.panels {
            let it = NSMenuItem(title: "Открыть: \(title)", action: #selector(openURL(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = url
            menu.addItem(it)
        }
        let logIt = NSMenuItem(title: "Открыть лог health-check", action: #selector(openLog(_:)), keyEquivalent: "")
        logIt.target = self
        menu.addItem(logIt)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Закрыть диспетчер", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    // при открытии меню — не тормозим: читаем файлы проблемы
    func menuWillOpen(_ menu: NSMenu) {
        refreshProblemsOnly()
    }

    // MARK: actions

    @objc func openURL(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? String {
            NSWorkspace.shared.open(URL(string: url)!)
        }
    }
    @objc func openLog(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(URL(fileURLWithPath: config.paths.log))
    }
    @objc func openServer(_ sender: NSMenuItem) {
        if let host = sender.representedObject as? String { pingOnce(host) }
    }
    @objc func runChecker(_ sender: NSMenuItem) {
        statusItem.button?.title = "🛰 ⏳"
        queue.async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = [config.paths.checker]
            try? p.run()
            p.waitUntilExit()
            DispatchQueue.main.async { self?.refreshAll(forceOwnFlag: true) }
        }
    }

    // MARK: сеть

    /// Реальный интерфейс (enX) с IPv4 — не TUN VPN (Karing подделывает ответы).
    func realNIC() -> (iface: String, ip: String)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        p.arguments = ["-l"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        guard let _ = try? p.run() else { return ("en0", ipconfigGetIf("en0") ?? "") }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let all = String(data: data, encoding: .utf8)?.split(separator: " ").map(String.init) ?? []
        let candidates = all.filter { $0.hasPrefix("en") }
        var best: (String, String)?
        for name in candidates {
            guard let ip = ipconfigGetIf(name), !ip.isEmpty else { continue }
            if name == "en0" { return (name, ip) }
            if best == nil { best = (name, ip) }
        }
        return best
    }

    func ipconfigGetIf(_ name: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/ipconfig")
        p.arguments = ["getifaddr", name]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        guard let _ = try? p.run() else { return nil }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? nil : s
    }

    /// Проба хоста: ICMP через enX; при отсутствии ответа — TCP-22 (ssh): обратная привязка к реальному интерфейсу.
    /// Возвращает "12,3 мс" | "ssh ok" | "нет ответа".
    func probe(_ host: String) -> String {
        let nic = realNIC()
        if let nic = nic {
            // 1) ICMP
            if let data = runCmd("/sbin/ping", ["-c", "1", "-W", "3000", "-b", nic.iface, host]) {
                var ms: String?
                for line in data.split(separator: "\n") where line.contains("time=") {
                    if let r = line.range(of: "time=[0-9.]+", options: .regularExpression) {
                        ms = String(line[r].dropFirst(5))
                    }
                }
                if let ms { return "\(ms) мс" }
            }
            // 2) TCP 22 c привязкой источника к en0 (боевой запас)
            if let data = runCmd("/usr/bin/nc", ["-s", nic.ip, "-G", "3", "-z", host, "22"]) {
                if data.contains("succeeded") { return "ssh ok" }
            }
        }
        return "нет ответа"
    }

    func runCmd(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? nil
    }

    func pingOnce(_ host: String) {
        results[host] = "проверяется…"
        updateItems()
        queue.async { [weak self] in
            let val = self?.probe(host) ?? "нет ответа"
            DispatchQueue.main.async {
                self?.results[host] = val
                self?.updateItems()
            }
        }
    }

    func refreshAll(forceOwnFlag: Bool = false) {
        let group = DispatchGroup()
        queue.async { [weak self] in
            guard let self else { return }
            for s in config.servers {
                group.enter()
                self.queue.async {
                    let val = self.probe(s.host)
                    DispatchQueue.main.async {
                        self.results[s.host] = val
                        group.leave()
                    }
                }
            }
            group.notify(queue: .main) {
                self.updateItems()
                self.headerItem.title = "Проверка: \(Self.now())"
            }
        }
        refreshProblemsOnly()
    }

    func refreshProblemsOnly() {
        var text = "Проблем нет ✔️"
        if let s = try? String(contentsOfFile: config.paths.problems, encoding: .utf8), !s.isEmpty {
            let lines = s.split(separator: "\n")
            text = "Проблемы: \(lines.count) — " + (lines.first.map(String.init) ?? "")
        }
        problemsItem.title = text
    }

    func menubarTitle() -> String {
        let vals = results.values
        if vals.isEmpty { return "🛰 …" }
        let isOk = { (v: String) in v.hasSuffix("мс") || v.hasPrefix("ssh") }
        let ok = vals.filter(isOk).count
        if ok == vals.count { return "🛰 🟢" }
        if ok == 0 { return "🛰 🔴" }
        return "🛰 🟠"
    }

    static func now() -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: Date())
    }

    func updateItems() {
        for (i, s) in config.servers.enumerated() {
            let val = results[s.host] ?? "проверяется…"
            let dot = val.hasSuffix("мс") ? "🟢" : (val == "нет ответа" ? "🔴" : "⏳")
            serverItems[i].title = "\(dot) \(s.name) — \(val) · \(s.role)"
        }
        statusItem.button?.title = menubarTitle()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
