import AppKit
import ApplicationServices

enum SourceKind { case browser, mail, notes, pdf, book, code, terminal, finder, other }

/// Where a capture comes from: the frontmost app plus whatever it can tell us
/// (page URL and title, PDF file and page, source file name, mail message link).
struct SourceContext {
    var appName: String
    var bundleID: String
    var kind: SourceKind
    var pid: pid_t
    var windowTitle: String?
    var url: URL?
    var pageTitle: String?
    var fileName: String?
    var pdfPage: Int?
    var mailLink: URL?
    var mailSubject: String?
    /// Why the browser AppleScript fallback failed, for the `--context` debug output.
    var scriptNote: String?

    /// Never capture from password managers.
    static let privateApps: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.apple.keychainaccess", "com.apple.Passwords", "com.bitwarden.desktop",
        "com.lastpass.LastPass", "com.dashlane.Dashlane", "in.sinew.Enpass-Desktop",
    ]
    private static let browsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.google.Chrome.canary",
        "company.thebrowser.Browser", "company.thebrowser.dia", "com.microsoft.edgemac", "com.brave.Browser",
        "org.mozilla.firefox", "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "app.zen-browser.zen",
        "com.kagi.kagimacOS", "ai.perplexity.comet", "com.openai.atlas", "org.chromium.Chromium",
    ]
    /// Browsers that answer `URL of active tab of front window` over AppleScript.
    private static let chromiumScriptable: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "company.thebrowser.Browser", "com.microsoft.edgemac",
        "com.brave.Browser", "com.vivaldi.Vivaldi", "org.chromium.Chromium",
    ]
    private static let notes: Set<String> = ["com.apple.Notes", "com.evernote.Evernote", "notion.id", "md.obsidian"]
    private static let pdfApps: Set<String> = [
        "com.apple.Preview", "com.readdle.PDFExpert-Mac", "net.sourceforge.skim-app.skim",
        "com.adobe.Acrobat.Pro", "com.adobe.Reader", "com.adobe.Acrobat", "com.highlightsapp.Highlights",
    ]
    private static let books: Set<String> = ["com.apple.iBooksX", "com.amazon.Lassen", "com.amazon.Kindle"]
    private static let code: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf", "dev.zed.Zed", "dev.zed.Zed-Preview", "com.apple.dt.Xcode",
        "com.sublimetext.4", "com.sublimetext.3", "com.panic.Nova", "com.google.android.studio", "com.vscodium",
    ]
    private static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "io.alacritty", "com.github.wez.wezterm",
    ]

    var isPrivate: Bool { Self.privateApps.contains(bundleID) }

    static func kind(for id: String) -> SourceKind {
        if browsers.contains(id) { return .browser }
        if id == "com.apple.mail" { return .mail }
        if notes.contains(id) { return .notes }
        if pdfApps.contains(id) { return .pdf }
        if books.contains(id) { return .book }
        if code.contains(id) || id.hasPrefix("com.jetbrains.") { return .code }
        if terminals.contains(id) { return .terminal }
        if id == "com.apple.finder" { return .finder }
        return .other
    }

    /// Snapshot of the frontmost app. Call before anything of ours takes focus.
    static func current() -> SourceContext? {
        guard let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier,
              id != Bundle.main.bundleIdentifier else { return nil }
        var ctx = SourceContext(appName: app.localizedName ?? id, bundleID: id, kind: kind(for: id),
                                pid: app.processIdentifier)
        guard AXIsProcessTrusted() else { return ctx }
        if ctx.kind == .browser || ctx.kind == .code || AX.isElectron(app) { AX.enableWebAccessibility(pid: ctx.pid) }

        let window = AX.focusedWindow(pid: ctx.pid)
        ctx.windowTitle = window.flatMap { AX.string($0, kAXTitleAttribute) }
        let documentURL = window.flatMap { AX.string($0, kAXDocumentAttribute) }.flatMap(URL.init(string:))

        switch ctx.kind {
        case .browser:
            // Chromium's accessibility tree often reports a background new-tab page,
            // so scriptable browsers answer for themselves; the tree is only a fallback.
            if Self.chromiumScriptable.contains(ctx.bundleID) { ctx.fillFromAppleScript() }
            if ctx.url == nil {
                let area = AX.focusedElement().flatMap(AX.webArea(containing:)) ?? window.flatMap(AX.findWebArea(in:))
                ctx.url = area.flatMap(AX.url)
                ctx.pageTitle = area.flatMap { AX.string($0, kAXTitleAttribute) }.flatMap(nonEmpty)
                    ?? ctx.windowTitle.map { cleanBrowserTitle($0, app: ctx.appName) }
            }
            if ctx.url?.pathExtension.lowercased() == "pdf" { ctx.fileName = ctx.url?.lastPathComponent }
        case .pdf, .book:
            ctx.fileName = documentURL?.lastPathComponent ?? ctx.windowTitle.flatMap(fileName(inTitle:))
            ctx.pdfPage = ctx.windowTitle.flatMap(pageNumber(inTitle:))
        case .code:
            ctx.fileName = documentURL?.lastPathComponent ?? ctx.windowTitle.flatMap(fileName(inTitle:))
        case .mail:
            ctx.fillMailFromAppleScript()
        default:
            break
        }
        return ctx
    }

    private static func nonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Two titles disagree only when both are non-empty and neither contains the other — the
    /// same tab read twice titles the window a little differently ("X" vs "X - Google Chrome").
    static func titlesMatch(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased(), y = b.lowercased()
        return x.isEmpty || y.isEmpty || x.contains(y) || y.contains(x)
    }

    static func cleanBrowserTitle(_ title: String, app: String) -> String {
        var t = title
        for sep in [" - ", " — ", " – "] where t.hasSuffix(sep + app) { t = String(t.dropLast((sep + app).count)) }
        if let r = t.range(of: #" [-—–] (Google Chrome|Microsoft Edge|Mozilla Firefox|Brave|Vivaldi|Opera)( [-—–] .*)?$"#,
                           options: .regularExpression) { t.removeSubrange(r) }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// "report.pdf – Page 3 of 20", "● main.swift — Project" → "report.pdf", "main.swift"
    static func fileName(inTitle title: String) -> String? {
        let first = title.components(separatedBy: CharacterSet(charactersIn: "—–")).first ?? title
        let cleaned = first.replacingOccurrences(of: "●", with: "").trimmingCharacters(in: .whitespaces)
        for candidate in [cleaned] + cleaned.components(separatedBy: " - ") {
            let c = candidate.trimmingCharacters(in: .whitespaces)
            if c.range(of: #"^[^/\\]+\.[A-Za-z0-9]{1,10}$"#, options: .regularExpression) != nil { return c }
        }
        return nil
    }

    static func pageNumber(inTitle title: String) -> Int? {
        for p in [#"(?i)page\s*(\d+)"#, #"第\s*(\d+)\s*页"#] {
            if let r = title.range(of: p, options: .regularExpression),
               let n = title[r].components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap({ Int($0) }).first {
                return n
            }
        }
        return nil
    }

    // MARK: AppleScript fallbacks (ask for Automation permission once per app)

    private mutating func fillFromAppleScript() {
        let script: String
        if bundleID.hasPrefix("com.apple.Safari") {
            script = "tell application id \"\(bundleID)\" to return {URL, name} of front document"
        } else if Self.chromiumScriptable.contains(bundleID) {
            script = "tell application id \"\(bundleID)\" to return {URL, title} of active tab of front window"
        } else { return }
        guard let list = Self.runScript(script, note: &scriptNote), list.numberOfItems >= 2 else { return }
        // Apple Events land on whichever copy of the browser owns the scripting registration —
        // with an automation copy of Chrome running that can be a different one. The title of the
        // real frontmost app's window (read over AX, which is pid-bound) is the check.
        let t = list.atIndex(2)?.stringValue ?? ""
        if let mine = windowTitle, !t.isEmpty, !Self.titlesMatch(t, mine) {
            scriptNote = "ignored: answer came from another browser instance"
            return
        }
        url = list.atIndex(1)?.stringValue.flatMap(URL.init(string:))
        if !t.isEmpty { pageTitle = t }
    }

    private mutating func fillMailFromAppleScript() {
        let script = """
        tell application "Mail"
            set s to selection
            if s is {} then return {"", ""}
            set m to item 1 of s
            return {message id of m, subject of m}
        end tell
        """
        guard let list = Self.runScript(script, note: &scriptNote), list.numberOfItems >= 2,
              let id = list.atIndex(1)?.stringValue, !id.isEmpty else { return }
        let encoded = "<\(id)>".addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
        mailLink = URL(string: "message://\(encoded)")
        mailSubject = list.atIndex(2)?.stringValue
    }

    private static func runScript(_ source: String, note: inout String?) -> NSAppleEventDescriptor? {
        var err: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&err)
        if let n = err?["NSAppleScriptErrorNumber"] as? Int { note = "AppleScript error \(n)" }
        return err == nil ? result : nil
    }
}

/// Thin Accessibility helpers.
enum AX {
    static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }
    static func string(_ el: AXUIElement, _ name: String) -> String? { attr(el, name) as? String }
    static func element(_ v: CFTypeRef?) -> AXUIElement? {
        guard let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
    static func url(_ el: AXUIElement) -> URL? {
        if let u = attr(el, kAXURLAttribute) as? URL { return u }
        return (attr(el, kAXURLAttribute) as? String).flatMap(URL.init(string:))
    }

    static func focusedElement() -> AXUIElement? {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.4)
        return element(attr(sys, kAXFocusedUIElementAttribute))
    }

    static func focusedWindow(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        return element(attr(app, kAXFocusedWindowAttribute))
    }

    /// Chromium and Electron only build their accessibility tree when asked.
    static func enableWebAccessibility(pid: pid_t) {
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    static func isElectron(_ app: NSRunningApplication) -> Bool {
        guard let url = app.bundleURL else { return false }
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
    }

    static func webArea(containing el: AXUIElement) -> AXUIElement? {
        var cur: AXUIElement? = el
        for _ in 0..<60 {
            guard let c = cur else { return nil }
            if string(c, kAXRoleAttribute) == "AXWebArea" { return c }
            cur = element(attr(c, kAXParentAttribute))
        }
        return nil
    }

    static func findWebArea(in root: AXUIElement) -> AXUIElement? {
        var queue = [root], visited = 0
        while !queue.isEmpty, visited < 600 {
            let el = queue.removeFirst(); visited += 1
            if string(el, kAXRoleAttribute) == "AXWebArea" { return el }
            if let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: kids) }
        }
        return nil
    }

    /// Selected text of the focused element. `nil` = the element can't tell us (fall back to ⌘C).
    static func selectedText() -> String? {
        guard let el = focusedElement() else { return nil }
        guard let v = attr(el, kAXSelectedTextAttribute) else { return nil }
        return (v as? String) ?? ""
    }

    static func focusIsSecureField() -> Bool {
        guard let el = focusedElement() else { return false }
        return string(el, kAXSubroleAttribute) == "AXSecureTextField"
    }
}
