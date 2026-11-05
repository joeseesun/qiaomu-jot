import AppKit
import SwiftUI
import KeyboardShortcuts
import Combine
import ServiceManagement

final class CapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    /// The panel never activates the app, and then AppKit skips the menu key-equivalent pass for whatever
    /// has focus (e.g. right after opening). Run it ourselves for every ⌘ chord first.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.modifierFlags.contains(.command), performKeyEquivalent(with: event) { return }
        super.sendEvent(event)
    }

    /// A menu bar app has no Edit menu, so ⌘V/⌘C/⌘X/⌘A/⌘Z would never reach the text view.
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: e) { return true }
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = e.charactersIgnoringModifiers?.lowercased() ?? ""
        if mods == .command && key == "q" { return true }               // never quit from the capture panel
        if mods == .command && key == "w" { onCancel?(); return true }
        // The panel never activates the app, so route ⌘, and friends through the main menu ourselves.
        if NSApp.mainMenu?.performKeyEquivalent(with: e) == true { return true }
        let action: Selector?
        switch (mods, key) {
        case (.command, "v"): action = #selector(NSText.paste(_:))
        case (.command, "c"): action = #selector(NSText.copy(_:))
        case (.command, "x"): action = #selector(NSText.cut(_:))
        case (.command, "a"): action = #selector(NSText.selectAll(_:))
        case (.command, "z"): action = Selector(("undo:"))
        case ([.command, .shift], "z"): action = Selector(("redo:"))
        default: action = nil
        }
        if let action { return NSApp.sendAction(action, to: nil, from: self) }
        return false
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var reopenPanelAfterSettings = false
    private let statusDrop = StatusItemDropTarget()

    /// Invisible for a menu bar app, but it gives the settings window and the panel ⌘, ⌘W and Edit shortcuts.
    private func installMainMenu() {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let holder = NSMenuItem()
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            holder.submenu = m
            main.addItem(holder)
        }
        func item(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command,
                  target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
            return i
        }
        submenu(AppInfo.name, [
            item("关于 \(AppInfo.name)", #selector(showAbout), "", target: self),
            item("检查更新…", #selector(Updater.checkForUpdates), "", target: Updater.shared),
            .separator(),
            item("设置…", #selector(showSettings), ",", target: self),
            .separator(),
            item("退出 \(AppInfo.name)", #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu("编辑", [
            item("撤销", Selector(("undo:")), "z"),
            item("重做", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("剪切", #selector(NSText.cut(_:)), "x"),
            item("拷贝", #selector(NSText.copy(_:)), "c"),
            item("粘贴", #selector(NSText.paste(_:)), "v"),
            item("全选", #selector(NSText.selectAll(_:)), "a"),
        ])
        submenu("窗口", [item("关闭", #selector(NSWindow.performClose(_:)), "w")])
        NSApp.mainMenu = main
    }
    private var statusItem: NSStatusItem!
    private var panel: CapturePanel?
    private var settingsWindow: NSWindow?
    private var model: CaptureModel?
    private var bag = Set<AnyCancellable>()
    private var host: NSHostingView<CaptureView>?

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Theme.registerFonts()
        installMainMenu()
        ClipboardWatcher.shared.start()
        Updater.shared.start()
        // Keep the login item pointing at this copy of the app (it may have been moved or renamed).
        if Prefs.shared.launchAtLogin, SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.statusImage
        statusItem.button?.toolTip = AppInfo.name
        let menu = NSMenu()
        menu.delegate = self            // rebuilt each time it opens (recent captures, permission state)
        statusItem.menu = menu
        if let button = statusItem.button {
            statusDrop.install(on: button)
            statusDrop.onDrop = { [weak self] pb in
                guard let self else { return false }
                if self.panel == nil { self.show() }
                return self.model?.dropHandler?.perform(pb) ?? false
            }
        }

        KeyboardShortcuts.onKeyUp(for: .capture) { [weak self] in self?.toggle() }
        KeyboardShortcuts.onKeyUp(for: .quickSave) { [weak self] in self?.quickSave() }
        registerRecipes()
        NotificationCenter.default.addObserver(forName: .recipesChanged, object: nil, queue: .main) { [weak self] _ in
            self?.registerRecipes()
        }

        if Prefs.shared.vaultPath.isEmpty {
            // No Obsidian vault: work as a plain Markdown notebook in ~/Documents/乔木闪记.
            if let vault = Prefs.discoverVaults().first {
                Prefs.shared.vaultPath = vault
            } else {
                let folder = FolderMode.defaultFolder
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                Prefs.shared.vaultPath = folder.path
                Prefs.shared.rememberFolder(folder.path)
            }
        }
        // A menu bar app has no window: on first launch (or without a vault) show settings so it's clearly running.
        if !Prefs.shared.didOnboard || Prefs.shared.vaultPath.isEmpty {
            Prefs.shared.didOnboard = true
            showSettings()
        }
    }

    /// Opening the app again from Finder / Launchpad / Spotlight shows its settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    @objc func showAbout() { openSettings(tab: "关于") }
    @objc func showScenes() { openSettings(tab: "场景") }

    private func openSettings(tab label: String) {
        showSettings()
        if let tabs = settingsWindow?.contentViewController as? NSTabViewController,
           let i = tabs.tabViewItems.firstIndex(where: { $0.label == label }) { tabs.selectedTabViewItemIndex = i }
    }

    // MARK: Scenes

    private var registeredRecipeIDs: [String] = []

    /// One global shortcut per scene; re-registered whenever scenes change.
    private func registerRecipes() {
        for id in registeredRecipeIDs { KeyboardShortcuts.removeHandler(for: .init("recipe-\(id)")) }
        let recipes = Prefs.shared.recipes
        registeredRecipeIDs = recipes.map(\.id)
        for r in recipes {
            KeyboardShortcuts.onKeyUp(for: r.shortcutName) { [weak self] in
                // Look the scene up again: it may have been edited since registration.
                guard let current = Prefs.shared.recipes.first(where: { $0.id == r.id }) else { return }
                self?.run(current)
            }
        }
    }

    func run(_ recipe: Recipe) {
        switch recipe.mode {
        case .panel: toggle(recipe: recipe)
        case .capture: quickSave(recipe: recipe)
        }
    }

    @objc func toggle() { toggle(recipe: nil) }

    /// ⌘⇧J (or a scene): open the panel; anything selected in the frontmost app comes along as a quote.
    func toggle(recipe: Recipe?) {
        if let p = panel, p.isVisible { close(); return }
        guard AXIsProcessTrusted(), let ctx = SourceContext.current(), !ctx.isPrivate, !AX.focusIsSecureField() else {
            show(); model?.apply(recipe); return
        }
        SelectionGrabber.grab(ctx, timeout: 0.3) { [weak self] g in
            let captured = g.isEmpty || g.concealed ? nil : CaptureFormatter.compose(g, ctx)
            // Nothing selected: offer the page / document as a source the user can attach with one click.
            var suggested: SourceInfo?
            if captured == nil, [.browser, .pdf, .book, .code].contains(ctx.kind) {
                let s = SourceInfo(ctx)
                if s.url != nil || s.detail != nil { suggested = s }
            }
            self?.show(prefill: captured, suggestedSource: suggested)
            self?.model?.apply(recipe)
            if captured == nil, let clip = ClipboardWatcher.shared.clip(within: 300),
               clip.grabbed.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let model = self?.model {
                model.clipOffer = CaptureModel.ClipOffer(label: "附上剪贴板里的\(clip.kindLabel)") { [weak model] in
                    model?.dropHandler?.perform(.general)
                    ClipboardWatcher.shared.consume()
                }
            }
        }
    }

    private func show(prefill: CaptureFormatter.Result? = nil, suggestedSource: SourceInfo? = nil,
                      amend: History.Entry? = nil) {
        if panel != nil { close() }
        let model = CaptureModel()
        model.onDone = { [weak self] in self?.close() }
        model.onCancel = { [weak self] in self?.close() }
        model.onPreview = { [weak model] i in
            guard let model else { return }
            Lightbox.show(urls: model.attachments, index: i,
                          onRemove: { u in model.attachments.removeAll { $0 == u } },
                          onClose: { model.focusEditor?() })
        }
        model.amend = amend
        if amend == nil {
            let draft = Prefs.shared.draft
            if let prefill {
                model.text = [prefill.markdown, draft].filter { !$0.isEmpty }.joined(separator: "\n\n") + "\n\n"
                model.attachments = prefill.files
                model.adoptTemp(prefill.tempDirs)
                model.source = prefill.source
                model.includeSource = prefill.source != nil
            } else {
                model.text = draft
                model.restoredDraft = !draft.isEmpty
                model.source = suggestedSource
                model.includeSource = false
            }
        }
        self.model = model
        let host = NSHostingView(rootView: CaptureView(model: model))
        self.host = host
        let size = host.fittingSize
        let p = CapturePanel(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        let fx = DropContainerView(frame: NSRect(origin: .zero, size: size))
        fx.handler = model.dropHandler
        fx.wantsLayer = true
        fx.layer?.cornerRadius = Theme.radius; fx.layer?.cornerCurve = .continuous; fx.layer?.masksToBounds = true
        host.frame = fx.bounds; host.autoresizingMask = [.width, .height]
        fx.addSubview(host)
        p.contentView = fx
        p.onCancel = { [weak self] in self?.close() }
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false

        let px = Prefs.shared.panelX, py = Prefs.shared.panelY
        let saved = NSPoint(x: px, y: py)
        if !px.isNaN, !py.isNaN, NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -size.width, dy: 0).contains(NSPoint(x: saved.x + 20, y: saved.y)) }) {
            p.setFrameTopLeftPoint(saved)
        } else {
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
            if let f = screen?.visibleFrame {
                p.setFrameTopLeftPoint(NSPoint(x: f.midX - size.width / 2, y: f.minY + f.height * 0.68))
            }
        }
        panel = p
        p.alphaValue = 0
        p.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; p.animator().alphaValue = 1 }

        // Remember where the user dragged the panel.
        NotificationCenter.default.publisher(for: NSWindow.didMoveNotification, object: p)
            .sink { _ in
                let tl = NSPoint(x: p.frame.minX, y: p.frame.maxY)
                Prefs.shared.panelX = tl.x; Prefs.shared.panelY = tl.y
            }.store(in: &bag)
        // Grow/shrink with content, keeping the top edge fixed.
        model.objectWillChange.receive(on: DispatchQueue.main).delay(for: .milliseconds(30), scheduler: DispatchQueue.main)
            .sink { [weak self, weak p] _ in
                guard let self, let p, let h = self.host else { return }
                let new = h.fittingSize
                guard abs(new.height - p.frame.height) > 1 else { return }
                var f = p.frame; let top = f.maxY
                f.size.height = new.height; f.origin.y = top - new.height
                p.setFrame(f, display: true, animate: true); p.invalidateShadow()
            }.store(in: &bag)
    }

    private func close() {
        Lightbox.dismiss()
        if let m = model, !m.saved {
            if m.amend == nil { Prefs.shared.draft = m.text }   // keep unsent text for next time
            m.discardTemp()
        }
        bag.removeAll()
        panel?.orderOut(nil)
        panel = nil; host = nil; model = nil
    }

    /// ⌘⇧K: save the selection straight away. Pressed again while the toast shows, it opens the
    /// panel to add a thought under the entry just saved.
    /// Shown when macOS blocks reading a file another app keeps in its private storage.
    static let protectedHint = "它在其他 App 的受保护位置，可在原 App 里拖进输入框或另存后再收录"

    @objc func quickSave() { quickSave(recipe: nil) }

    /// ⌘⇧K (or a "直接收录" scene): save the selection straight away. Pressed again while the toast shows,
    /// it opens the panel to add a thought under the entry just saved.
    func quickSave(recipe: Recipe?) {
        if Toast.isShowingCapture, let last = History.last { Toast.dismiss(); show(amend: last); return }
        guard let vault = Prefs.shared.vaultURL else { showSettings(); return }
        guard SelectionGrabber.ensureAccessibility() else {
            Toast.show("需要「辅助功能」权限才能读取选中内容", style: .warning, actions: [
                .init(title: "打开设置") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                },
            ], duration: 6)
            return
        }
        guard let ctx = SourceContext.current() else { show(); return }
        if ctx.isPrivate || AX.focusIsSecureField() {
            Toast.show("为保护隐私，不收录这里的内容", detail: ctx.appName, style: .warning); return
        }
        SelectionGrabber.grab(ctx, timeout: 0.6) { [weak self] g in
            guard let self else { return }
            if g.concealed { Toast.show("这是受保护的内容，未收录", detail: ctx.appName, style: .warning); return }
            var result = CaptureFormatter.Result(markdown: "", files: [], tempDirs: [], source: nil)
            var title = recipe.map { "已收录到「\($0.displayName)」" } ?? "已收录到今日日记"
            var toastSource: SourceInfo? = SourceInfo(ctx)
            var detail = ctx.kind == .browser ? ctx.pageTitle : nil
            var pageURL: URL?
            let prefs = Prefs.shared
            /// Writes the entry and shows the toast — shared by the sync and async paths above.
            func save() {
                if let recipe { title = "已收录到「\(recipe.displayName)」" }
                let finish = { [weak self] (ocr: [String: String]) in
                    let w = DailyNoteWriter(vault: vault, attachmentOverride: prefs.attachmentFolder)
                    defer { for d in result.tempDirs { try? FileManager.default.removeItem(at: d) } }
                    History.skipped = []
                    /// Everything after a successful write: skipped files, sound, page snapshot, toast.
                    func delivered(note: URL) {
                        let skipped = History.skipped
                        if !skipped.isEmpty, skipped.count == result.files.count,
                           result.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            try? History.undoLast()          // nothing usable was saved: don't leave an empty entry
                            Toast.show("这个文件读不到，没有收录", detail: Self.protectedHint, style: .warning, duration: 6)
                            return
                        }
                        prefs.didFirstCapture = true
                        if prefs.openAfterSave { CaptureModel.open(note: note, vault: vault) }
                        SaveSound.play(prefs.saveSound)
                        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                        // 打开: Obsidian vault → Obsidian; plain folder → the default Markdown app. Hidden when it already opened.
                        let open: [Toast.Action] = prefs.openAfterSave ? [] : [
                            .init(title: "打开") { CaptureModel.open(note: note, vault: vault) },
                        ]
                        if !skipped.isEmpty {
                            Toast.show("已收录，但有 \(skipped.count) 个文件读不到", detail: Self.protectedHint, style: .warning,
                                       actions: [.init(title: "撤销") { self?.undoLast() }] + open, duration: 6)
                            return
                        }
                        // A page link saved bare: its own description and a head snapshot tuck in on
                        // arrival (PDFs have no description to parse; the renderer has no browser
                        // login state, so login walls simply skip).
                        if let page = pageURL, result.files.isEmpty, let entry = History.last {
                            if prefs.pageDescription, page.pathExtension.lowercased() != "pdf" {
                                LinkTitle.description(page, timeout: 3) { d in
                                    guard let d, let current = History.last,
                                          current.note == entry.note, current.entry.hasPrefix(entry.entry) else { return }
                                    try? w.amend(current, text: "\n> " + d, attachments: [])
                                }
                            }
                            if prefs.pageSnapshot {
                                WebSnapshot.capture(page) { file in
                                    guard let file else { return }
                                    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
                                    guard let now = History.last, now.note == entry.note,
                                          now.entry.hasPrefix(entry.entry) else { return }
                                    if (try? w.amend(now, text: "", attachments: [file])) != nil {
                                        Toast.show("已补上网页快照", style: .success)
                                    }
                                }
                            }
                        }
                        Toast.show(title, detail: detail, source: toastSource, actions: [
                            .init(title: "撤销") { self?.undoLast() },
                            .init(title: "补充想法") { History.last.map { self?.show(amend: $0) } },
                        ] + open, duration: 3.6)
                    }
                    do {
                        let dest = recipe?.destination ?? .daily
                        switch dest.kind {
                        case .daily:
                            func dailyAppend() throws -> URL {
                                // Page entries read as outline sections: separate them from what came before.
                                var content = result.markdown
                                if pageURL != nil, result.files.isEmpty,
                                   let existing = try? String(contentsOf: w.noteURL(for: Date()), encoding: .utf8),
                                   !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    content = "---\n" + content
                                }
                                let note = try w.append(content: content, attachments: result.files, ocr: ocr,
                                                        source: result.source, asTask: recipe?.asTask ?? false, heading: prefs.insertHeading)
                                _ = prefs.dailyCount(1)
                                return note
                            }
                            // This page is already saved somewhere in the vault: add to its section instead.
                            if recipe == nil, ctx.kind == .browser, let url = ctx.url {
                                let query = url.absoluteString
                                    .replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\\", with: "")
                                ContentSearch().run(query, in: vault) { hits in
                                    do {
                                        // Spotlight lags behind a note written seconds ago: today's note is always a candidate.
                                        var paths = hits.map { $0.0.path }
                                        paths.append(w.noteURL(for: Date()).standardizedFileURL.path)
                                        if let target = MergeTarget.pick(paths: paths, url: url.absoluteString, in: vault) {
                                            // Never file the link twice: thoughts, selections and files join its section.
                                            let page = History.Entry(note: target.file, entry: target.entry, files: [], indent: "")
                                            self?.supplementPage(page, text: g.text, files: result.files,
                                                                 tempDirs: result.tempDirs, ocr: ocr, pageTitle: ctx.pageTitle, writer: w)
                                        } else {
                                            delivered(note: try dailyAppend())
                                        }
                                    } catch {
                                        Toast.show("保存失败", detail: error.localizedDescription, style: .warning)
                                    }
                                }
                            } else {
                                delivered(note: try dailyAppend())
                            }
                        case .note:
                            delivered(note: try w.append(content: result.markdown, attachments: result.files, ocr: ocr, source: result.source,
                                                         asTask: recipe?.asTask ?? false, to: vault.appendingPathComponent(dest.path)))
                        case .folder:
                            delivered(note: try w.createNote(folder: dest.path, title: NoteNaming.autoTitle(from: result.markdown),
                                                             content: result.markdown, attachments: result.files, ocr: ocr, source: result.source))
                        }
                    } catch {
                        Toast.show("保存失败", detail: error.localizedDescription, style: .warning)
                    }
                }
                if prefs.ocrImages { OCR.recognize(result.files, completion: finish) } else { finish([:]) }
            }
            if g.isEmpty {
                // Nothing selected: what was just copied or captured, newest first.
                // 「空选时收录剪贴板」off: skip the clipboard; the newest screenshot and the page link still work.
                let watcher = ClipboardWatcher.shared
                let recentClip = prefs.clipboardFallback ? watcher.clip(within: 300) : nil
                let shot = ScreenshotFinder.latest()
                func useClip(_ clip: ClipboardWatcher.Clip) {
                    result = CaptureFormatter.compose(clip.grabbed, clip.context)
                    let isText = clip.grabbed.files.isEmpty && clip.grabbed.media.isEmpty
                    if !isText { result.source = nil }
                    watcher.consume()
                    title = "已收录剪贴板里的\(clip.kindLabel)"
                    toastSource = isText ? clip.context.map(SourceInfo.init) : nil
                    detail = nil
                }
                if let clip = recentClip, shot == nil || (clip.date ?? .distantPast) >= shot!.date {
                    useClip(clip)
                } else if let shot {
                    ScreenshotFinder.consume(shot.url)
                    result = .init(markdown: "", files: [shot.url], tempDirs: [], source: nil)
                    title = MediaKind(shot.url) == .video ? "已收录刚才的录屏" : "已收录刚才的截图"
                    toastSource = nil
                    detail = shot.url.lastPathComponent
                } else if ctx.kind == .browser, let link = CaptureFormatter.pageLink(ctx), let url = ctx.url,
                          url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http" {
                    // Save right away as an outline heading; the description and snapshot tuck in afterwards (see delivered).
                    pageURL = url
                    result = .init(markdown: "# " + link, files: [], tempDirs: [], source: nil)
                    title = "已收录当前网页"
                } else if prefs.clipboardFallback, let clip = watcher.clip() {
                    useClip(clip)
                } else {
                    Toast.show(prefs.clipboardFallback ? "没有选中内容，剪贴板也是空的" : "没有选中内容",
                               detail: ctx.kind == .browser ? "当前浏览器页面没有内容" : "前台是 \(ctx.appName)", style: .warning, actions: [
                        .init(title: "打开输入框") { [weak self] in self?.show() },
                    ])
                    return
                }
            } else {
                result = CaptureFormatter.compose(g, ctx)
            }
            save()
        }
    }

    /// Menu bar glyph: the app icon's Lucide notebook-pen, as a template image.
    private static let statusImage: NSImage? = {
        let img = SourceIcons.image(named: "lucide/notebook-pen")?.copy() as? NSImage
        img?.size = NSSize(width: 17, height: 17)
        img?.isTemplate = true
        img?.accessibilityDescription = AppInfo.name
        return img ?? NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: AppInfo.name)
    }()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        @discardableResult
        func add(_ title: String, _ action: Selector, symbol: String? = nil, key: String = "") -> NSMenuItem {
            let i = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            i.target = self
            if let symbol { i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            return i
        }
        if !AXIsProcessTrusted() {
            let warn = add("开启辅助功能权限以收录选中内容…", #selector(showSettings), symbol: "exclamationmark.triangle")
            warn.attributedTitle = NSAttributedString(string: warn.title, attributes: [.foregroundColor: NSColor.systemOrange])
            menu.addItem(.separator())
        }
        add("打开输入框", #selector(toggle as () -> Void), symbol: "square.and.pencil").setShortcut(for: .capture)
        add("收录选中内容", #selector(quickSave as () -> Void), symbol: "text.badge.plus").setShortcut(for: .quickSave)
        let scenes = Prefs.shared.recipes
        if !scenes.isEmpty {
            menu.addItem(.separator())
            for r in scenes {
                let item = MenuAction.item(r.displayName) { [weak self] in self?.run(r) }
                item.image = NSImage(systemSymbolName: r.symbol, accessibilityDescription: nil)
                item.toolTip = (r.mode == .panel ? "打开输入框 → " : "直接收录 → ") + r.destinationLabel
                item.setShortcut(for: r.shortcutName)
                menu.addItem(item)
            }
        }
        add(scenes.isEmpty ? "添加场景…" : "管理场景…", #selector(showScenes), symbol: scenes.isEmpty ? "plus.rectangle.on.rectangle" : "rectangle.stack")
        menu.addItem(.separator())

        let recents = RecentCaptures.items
        let recentItem = NSMenuItem(title: "最近收录", action: nil, keyEquivalent: "")
        recentItem.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
        let sub = NSMenu()
        if recents.isEmpty {
            sub.addItem(withTitle: "还没有记录", action: nil, keyEquivalent: "").isEnabled = false
        }
        let rel = RelativeDateTimeFormatter(); rel.unitsStyle = .short
        for r in recents {
            let item = MenuAction.item(r.summary) { [weak self] in self?.openNote(path: r.notePath) }
            item.toolTip = (r.notePath as NSString).lastPathComponent + " · " + rel.localizedString(for: r.date, relativeTo: Date())
            sub.addItem(item)
        }
        recentItem.submenu = sub
        menu.addItem(recentItem)
        add(Prefs.shared.isObsidianVault && FolderMode.obsidianInstalled ? "在 Obsidian 中打开今日日记" : "打开今日日记",
            #selector(openToday), symbol: "calendar")
        let undo = add(History.last.map { "撤销「\($0.summary)」" } ?? "撤销上一条记录", #selector(undoLast),
                       symbol: "arrow.uturn.backward")
        undo.isEnabled = History.last != nil
        menu.addItem(.separator())
        add("设置…", #selector(showSettings), symbol: "gearshape", key: ",")
        add("关于 \(AppInfo.name)", #selector(showAbout), symbol: "info.circle")
        let upd = menu.addItem(withTitle: "检查更新…", action: #selector(Updater.checkForUpdates), keyEquivalent: "")
        upd.target = Updater.shared
        upd.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "退出 \(AppInfo.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
    }

    private func openNote(path: String) {
        guard let vault = Prefs.shared.vaultURL, path.hasPrefix(vault.path) else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path)); return
        }
        CaptureModel.open(note: URL(fileURLWithPath: path), vault: vault)
    }

    /// The page is already recorded somewhere in the vault: never file its link twice — a
    /// thought, a selection or files all land at the end of that page's section.
    private func supplementPage(_ page: History.Entry, text: String, files: [URL], tempDirs: [URL],
                                ocr: [String: String], pageTitle: String?, writer w: DailyNoteWriter) {
        let anchor = MergeTarget.sectionEnd(page)
        if text.isEmpty, files.isEmpty {
            Toast.show("这个网页已经存过", detail: pageTitle ?? "", style: .success, actions: [
                .init(title: "补充想法") { [weak self] in self?.show(amend: anchor) },
            ], duration: 4)
            return
        }
        defer { for d in tempDirs { try? FileManager.default.removeItem(at: d) } }
        do {
            // A selection keeps its full text: a short heading for the outline, a quote below.
            var added: [String] = []
            if let heading = CaptureFormatter.sectionHeading(from: text) { added.append(heading) }
            if text.count > 40 { added.append(CaptureFormatter.quote(text)) }
            try w.amend(anchor, text: added.joined(separator: "\n"), attachments: files, ocr: ocr)
            Toast.show("已补充到「\(pageTitle ?? "")」", detail: page.note.deletingPathExtension().lastPathComponent,
                       style: .success, actions: [
                .init(title: "补充想法") { [weak self] in History.last.map { self?.show(amend: $0) } },
                .init(title: "撤销") { [weak self] in self?.undoLast() },
            ], duration: 4)
        } catch {
            Toast.show("保存失败", detail: error.localizedDescription, style: .warning)
        }
    }

    @objc func undoLast() {
        let wasToday = History.last?.note == CaptureModel.todayNote
        do {
            try History.undoLast()
            if wasToday { _ = Prefs.shared.dailyCount(-1) }
            Toast.show("已撤销", duration: 1.6)
        }
        catch { Toast.show("撤销失败", detail: error.localizedDescription, style: .warning) }
    }

    @objc func openToday() {
        guard let vault = Prefs.shared.vaultURL else { showSettings(); return }
        let w = DailyNoteWriter(vault: vault, attachmentOverride: "")
        let note = w.noteURL(for: Date())
        if FileManager.default.fileExists(atPath: note.path) {
            CaptureModel.open(note: note, vault: vault)
        } else if FolderMode.isObsidianVault(vault), FolderMode.obsidianInstalled {
            var c = URLComponents(string: "obsidian://daily")!
            c.queryItems = [.init(name: "vault", value: vault.lastPathComponent)]
            if let u = c.url { NSWorkspace.shared.open(u) }
        } else {
            Toast.show("今天还没有记录", detail: note.lastPathComponent, style: .warning)
        }
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindow.make()
            settingsWindow?.delegate = self
        }
        // The capture panel steps aside (draft kept) and comes back when settings closes,
        // so key presses can't fall through to it.
        if panel?.isVisible == true { reopenPanelAfterSettings = true; close() }
        // A menu bar app can't reliably take keyboard focus; act as a regular app while settings is open.
        NSApp.setActivationPolicy(.regular)
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        settingsWindow?.makeKeyAndOrderFront(nil)
        // Nothing focused: a shortcut recorder only starts recording when clicked.
        settingsWindow?.makeFirstResponder(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        NSApp.setActivationPolicy(.accessory)
        if reopenPanelAfterSettings {
            reopenPanelAfterSettings = false
            DispatchQueue.main.async { self.show() }
        }
    }
}

/// `Jot --snapshot out.png [text]` renders the capture panel offscreen (design review).
func snapshot(_ path: String, text: String, dark: Bool) {
    let p = Prefs.shared
    let keep = (p.showFormatBar, p.timestamp, p.timeFormat)
    let keepRecipes = UserDefaults.standard.data(forKey: "recipes")
    defer {
        (p.showFormatBar, p.timestamp, p.timeFormat) = keep
        UserDefaults.standard.set(keepRecipes, forKey: "recipes")
    }
    if CommandLine.arguments.contains("--scenes-demo") {
        var a = Recipe.presets[0], b = Recipe.presets[2]
        a.id = "demo-a"; b.id = "demo-b"
        p.recipes = [a, b]
    }   // design snapshots must not change the user's prefs
    if CommandLine.arguments.contains("--time-custom") { p.timestamp = true; p.timeFormat = "[记于] HH:mm" }
    let m = CaptureModel(); m.text = text
    let args = CommandLine.arguments
    m.showFormatBar = args.contains("--format")
    if args.contains("--picker") {
        m.vaultIndex = (["", "Inbox", "读书", "工作", "10 Daily", "读书/经济"].map { Destination(kind: .folder, path: $0) }
            + ["读书/置身事内.md", "读书/经济/置身事内 笔记.md", "工作/周报.md"].map { Destination(kind: .note, path: $0) })
            .map { VaultIndex.entry($0) }
        m.indexLoaded = true
        m.picking = true
        if let q = args.firstIndex(of: "--query").map({ args[$0 + 1] }) {
            m.pickerQuery = q
            m.contentHits = [(Destination(kind: .note, path: "10 Daily/2026-11-02.md"), "看完第三章：地方政府与置身事内的逻辑…"),
                             (Destination(kind: .note, path: "Clippings/兰小欢访谈.md"), "…为什么写《置身事内》这本书")]
        }
    }
    if args.contains("--recents") {
        m.previewRecents = [
            RecentDestination(destination: Destination(kind: .note, path: "读书/置身事内.md"), date: Date().addingTimeInterval(-180)),
            RecentDestination(destination: Destination(kind: .folder, path: "Inbox"), date: Date().addingTimeInterval(-3600 * 3)),
            RecentDestination(destination: Destination(kind: .note, path: "工作/周报.md"), date: Date().addingTimeInterval(-86400 * 2)),
        ]
    }
    if args.contains("--folder") { m.destination = Destination(kind: .folder, path: "Inbox") }
    if args.contains("--source") {
        m.source = Prefs.sampleSource
        m.includeSource = !args.contains("--suggested")
    }
    if args.contains("--amend") {
        m.amend = History.Entry(note: URL(fileURLWithPath: "/tmp/x.md"), entry: "- 14:32\n  > 土地财政是地方政府的关键机制\n", files: [])
    }
    if args.contains("--draft") { m.restoredDraft = true }
    if let i = args.firstIndex(of: "--attach") { m.attachments = args[i + 1].split(separator: ",").map { URL(fileURLWithPath: String($0)) } }
    if args.contains("--clip") { m.clipOffer = CaptureModel.ClipOffer(label: "附上剪贴板里的图片") {} }
    let settingsTab = args.firstIndex(of: "--settings").map { args[$0 + 1] }
    let host: NSView = settingsTab != nil
        ? (settingsTab == "about" ? NSHostingView(rootView: AnyView(AboutSettings()))
           : settingsTab == "scenes" ? NSHostingView(rootView: AnyView(RecipeSettings()))
           : settingsTab == "record" ? NSHostingView(rootView: AnyView(RecordSettings()))
           : settingsTab == "save" ? NSHostingView(rootView: AnyView(SaveSettings()))
           : NSHostingView(rootView: AnyView(GeneralSettings())))
        : args.contains("--toast")
        ? NSHostingView(rootView: ToastView(title: "已收录到今日日记", detail: "置身事内 - 读书笔记", source: Prefs.sampleSource, style: .success,
                                            actions: [.init(title: "撤销") {}, .init(title: "补充想法") {}, .init(title: "打开") {}], onHover: { _ in }))
        : NSHostingView(rootView: CaptureView(model: m))
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))   // let async layout (auto-grow) settle
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    host.layoutSubtreeIfNeeded()
    let bg = NSView(frame: host.frame.insetBy(dx: -30, dy: -30))
    bg.wantsLayer = true
    bg.layer?.backgroundColor = args.contains("--transparent") ? NSColor.clear.cgColor
        : (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.93, alpha: 1)).cgColor
    host.frame.origin = NSPoint(x: 30, y: 30)
    host.wantsLayer = true
    if !args.contains("--toast") { host.layer?.cornerRadius = Theme.radius; host.layer?.masksToBounds = true }
    bg.addSubview(host)
    let rep = bg.bitmapImageRepForCachingDisplay(in: bg.bounds)!
    bg.cacheDisplay(in: bg.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

/// `Jot --selftest` exercises the Markdown editing commands on a real NSTextView.
func selftest() -> Int32 {
    RecentCaptures.enabled = false
    var failures = 0
    func run(_ name: String, _ text: String, _ sel: NSRange, _ step: (NSTextView) -> Void, _ expect: String) {
        let tv = NSTextView(); tv.isRichText = false; tv.allowsUndo = true
        tv.string = text; tv.setSelectedRange(sel)
        step(tv)
        let ok = tv.string == expect
        if !ok { failures += 1 }
        print(ok ? "✓" : "✗", name, ok ? "" : "→ got \(tv.string.debugDescription), want \(expect.debugDescription)")
    }
    run("bold empty", "", NSRange(location: 0, length: 0), { $0.perform(.bold) }, "****")
    run("bold selection", "hi 你好", NSRange(location: 3, length: 2), { $0.perform(.bold) }, "hi **你好**")
    run("bold toggle off", "hi **你好**", NSRange(location: 5, length: 2), { $0.perform(.bold) }, "hi 你好")
    run("bullet two lines", "a\nb", NSRange(location: 0, length: 3), { $0.perform(.bullet) }, "- a\n- b")
    run("bullet off", "- a\n- b", NSRange(location: 0, length: 7), { $0.perform(.bullet) }, "a\nb")
    run("numbered", "a\nb", NSRange(location: 0, length: 3), { $0.perform(.numbered) }, "1. a\n2. b")
    run("bullet → task", "- a", NSRange(location: 3, length: 0), { $0.perform(.task) }, "- [ ] a")
    run("heading cycle", "## t", NSRange(location: 4, length: 0), { $0.perform(.heading(nil)) }, "### t")
    run("heading ⌘1", "t", NSRange(location: 1, length: 0), { $0.perform(.heading(1)) }, "# t")
    run("link empty", "", NSRange(location: 0, length: 0), { $0.perform(.link) }, "[]()")
    run("code block", "x", NSRange(location: 1, length: 0), { $0.perform(.codeBlock) }, "```\nx\n```")
    run("enter continues bullet", "- a", NSRange(location: 3, length: 0), { _ = $0.continueList() }, "- a\n- ")
    run("enter continues number", "1. a", NSRange(location: 4, length: 0), { _ = $0.continueList() }, "1. a\n2. ")
    run("enter continues task", "- [x] a", NSRange(location: 7, length: 0), { _ = $0.continueList() }, "- [x] a\n- [ ] ")
    run("enter on empty item ends list", "- a\n- ", NSRange(location: 6, length: 0), { _ = $0.continueList() }, "- a\n")
    run("tab nests item", "- a", NSRange(location: 3, length: 0), { _ = $0.indentListItem(false) }, "\t- a")
    let m = CaptureModel()
    for (t, task) in [("[] 买牛奶", true), ("【】买牛奶", true), ("- [ ] a\n- [ ] b", false), ("普通", false)] {
        m.text = t
        let ok = m.isTask == task
        if !ok { failures += 1 }
        print(ok ? "✓" : "✗", "isTask \(t.debugDescription) = \(m.isTask)")
    }
    func check(_ name: String, _ got: String, _ want: String) {
        let ok = got == want
        if !ok { failures += 1 }
        print(ok ? "✓" : "✗", name, ok ? "" : "\n   got:  \(got.debugDescription)\n   want: \(want.debugDescription)")
    }
    let base = URL(string: "https://example.com/post/1")
    check("html: emphasis + link", HTMLToMarkdown.convert("<p>Hello <b>world</b>, see <a href=\"/docs\">文档</a>.</p>", base: base),
          "Hello **world**, see [文档](https://example.com/docs).")
    check("html: list + heading", HTMLToMarkdown.convert("<h2>要点</h2><ul><li>一</li><li>二 <i>斜</i></li></ul>", base: base),
          "## 要点\n\n- 一\n- 二 *斜*")
    check("html: ordered + code", HTMLToMarkdown.convert("<ol><li>run <code>make</code></li><li>done</li></ol><pre><code>let x = 1\nlet y = 2</code></pre>", base: base),
          "1. run `make`\n2. done\n\n```\nlet x = 1\nlet y = 2\n```")
    check("html: blockquote", HTMLToMarkdown.convert("<blockquote><p>a</p><p>b</p></blockquote>", base: base), "> a\n>\n> b")
    check("html: table", HTMLToMarkdown.convert("<table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table>", base: base),
          "| A | B |\n| --- | --- |\n| 1 | 2 |")
    check("pdf: join english + hyphen", CaptureFormatter.cleanPDF("The quick brown fox jumps over the\nlazy dog and keeps run-\nning far away."),
          "The quick brown fox jumps over the lazy dog and keeps running far away.")
    check("pdf: join chinese", CaptureFormatter.cleanPDF("地方政府在经济发展中扮演了\n重要角色，这一点很关键。"), "地方政府在经济发展中扮演了重要角色，这一点很关键。")
    check("pdf: ligature", CaptureFormatter.cleanPDF("ﬁnal ﬂow"), "final flow")
    let books = CaptureFormatter.parseBookCitation("“土地财政是关键。”\n\n摘录来自\n置身事内\n兰小欢\n此材料可能受版权保护。")
    check("books: text", books.text, "土地财政是关键。")
    check("books: citation", books.citation ?? "", "《置身事内》 兰小欢")
    check("title: file in VS Code title", SourceContext.fileName(inTitle: "● main.swift — qiaomu-ob-helper") ?? "", "main.swift")
    check("title: preview page", String(SourceContext.pageNumber(inTitle: "report.pdf – Page 12 of 30") ?? 0), "12")
    check("title: chrome suffix", SourceContext.cleanBrowserTitle("Hello - Google Chrome", app: "Google Chrome"), "Hello")
    func ctx(_ kind: SourceKind, app: String = "App") -> SourceContext {
        SourceContext(appName: app, bundleID: "x", kind: kind, pid: 0)
    }
    var web = ctx(.browser, app: "Safari"); web.url = URL(string: "https://a.com/x"); web.pageTitle = "标题 [1]"
    let webCapture = CaptureFormatter.compose(Grabbed(text: "一段话\n\n第二段", html: nil), web)
    check("compose: web text verbatim", webCapture.markdown, "一段话\n\n第二段")
    check("compose: web source", webCapture.source?.markdown ?? "", "[标题 \\[1\\]](https://a.com/x)")
    check("compose: web page link", CaptureFormatter.pageLink(web) ?? "", "[标题 \\[1\\]](https://a.com/x)")
    var code = ctx(.code, app: "Cursor"); code.fileName = "app.py"
    let codeCapture = CaptureFormatter.compose(Grabbed(text: "    def f():\n        return 1\n"), code)
    check("compose: code block", codeCapture.markdown, "```python\ndef f():\n    return 1\n```")
    check("compose: code source", codeCapture.source?.markdown ?? "", "`app.py` · Cursor")
    check("compose: inline code", CaptureFormatter.compose(Grabbed(text: "make build"), code).markdown, "`make build`")
    var pdf = ctx(.pdf, app: "预览"); pdf.fileName = "论文.pdf"; pdf.pdfPage = 3
    let pdfCapture = CaptureFormatter.compose(Grabbed(text: "第一行\n第二行"), pdf)
    check("compose: pdf", pdfCapture.markdown + " | " + (pdfCapture.source?.markdown ?? ""), "第一行第二行 | 《论文》 p.3")
    let chat = CaptureFormatter.compose(Grabbed(text: "明天见"), ctx(.other, app: "微信"))
    check("compose: chat", chat.markdown + " | " + (chat.source?.markdown ?? ""), "明天见 | 微信")

    // Entry format presets and toggles.
    let at = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 14, minute: 32))!
    let src = SourceInfo(app: "Claude", bundleID: "com.anthropic.claudefordesktop", kind: .other)
    func fmt(_ style: EntryStyle, time: Bool = true, source: Bool = true) -> EntryFormat {
        EntryFormat(template: style.template, showTime: time, timeFormat: "HH:mm", showSource: source)
    }
    check("format: plain", fmt(.plain).render(content: "第一行\n第二行", attachments: [], source: src, date: at),
          "第一行\n第二行\n> 14:32 · Claude\n")
    check("format: plain, no time", fmt(.plain, time: false).render(content: "a", attachments: [], source: src, date: at), "a\n> Claude\n")
    check("format: plain, nothing", fmt(.plain, time: false, source: false).render(content: "a", attachments: ["![[x.png]]"], source: src, date: at),
          "a\n![[x.png]]\n")
    check("format: time first", fmt(.timeFirst).render(content: "a", attachments: [], source: src, date: at), "**14:32** · Claude\na\n")
    check("format: time first, no time", fmt(.timeFirst, time: false).render(content: "a", attachments: [], source: src, date: at), "Claude\na\n")
    check("format: list", fmt(.list).render(content: "a\nb", attachments: ["![[x.png]]"], source: src, date: at),
          "- 14:32 a\n  b\n  ![[x.png]]\n  > Claude\n")
    check("format: list task", fmt(.list, source: false).render(content: "买牛奶", attachments: [], source: nil, task: true, date: at),
          "- [ ] 14:32 买牛奶\n")
    check("format: plain task", fmt(.plain, source: false).render(content: "买牛奶", attachments: [], source: nil, task: true, date: at),
          "- [ ] 买牛奶\n> 14:32\n")
    check("format: quote", fmt(.quote).render(content: "a\nb", attachments: [], source: src, date: at), "> a\n> b\n>\n> 14:32 · Claude\n")
    check("format: quote, no meta", fmt(.quote, time: false, source: false).render(content: "a", attachments: [], source: src, date: at), "> a\n")
    check("format: callout", fmt(.callout, time: false).render(content: "a", attachments: [], source: src, date: at), "> [!quote] Claude\n> a\n")
    let custom = EntryFormat(template: "### {{time:HH时mm分}} {{app}}\n{{content}}", showTime: true, timeFormat: "HH:mm", showSource: true)
    check("format: custom", custom.render(content: "a", attachments: [], source: src, date: at), "### 14时32分 Claude\na\n")

    check("name: sanitize", NoteNaming.sanitize("a/b:c#d [x]"), "a b c d x")
    check("name: auto title from heading", NoteNaming.autoTitle(from: "## 读书笔记\n内容"), "读书笔记")
    check("name: auto title skips embeds", NoteNaming.autoTitle(from: "![[a.png]]\n> **重点**来了"), "重点来了")
    check("name: fallback", String(NoteNaming.autoTitle(from: "").prefix(3)), "随记 ")
    let idx = [Destination(kind: .note, path: "Inbox/置身事内 笔记.md"), Destination(kind: .folder, path: "读书"),
               Destination(kind: .note, path: "读书/置身事内.md"), Destination(kind: .note, path: "工作/周报.md")]
    check("search: name prefix first", VaultIndex.search(idx.map { VaultIndex.entry($0) }, "置身").map(\.path).joined(separator: ","),
          "读书/置身事内.md,Inbox/置身事内 笔记.md")
    let ix = idx.map { VaultIndex.entry($0) } + [VaultIndex.entry(Destination(kind: .note, path: "资料/Large Language Models.md"), aliases: ["LLM 入门"])]
    check("search: multi-word", VaultIndex.search(ix, "读书 置身").map(\.path).joined(separator: ","), "读书/置身事内.md")
    check("search: pinyin initials", VaultIndex.search(ix, "zssn").first?.path ?? "", "读书/置身事内.md")
    check("search: full pinyin", VaultIndex.search(ix, "zhoubao").first?.path ?? "", "工作/周报.md")
    check("search: fuzzy typo-tolerant order", VaultIndex.search(ix, "lgmdl").first?.path ?? "", "资料/Large Language Models.md")
    check("search: alias", VaultIndex.search(ix, "llm").first?.path ?? "", "资料/Large Language Models.md")
    let ix2 = ix + [VaultIndex.entry(Destination(kind: .note, path: "活动/一技半解·圆桌｜Personal Agent.md")),
                    VaultIndex.entry(Destination(kind: .note, path: "读书/三国演义 (罗贯中) (z-library.sk, 1lib.sk).md"))]
    for q in ["yiji", "yi'ji", "yi ji", "yjbj"] {
        check("search: pinyin \(q) ranks best match first", VaultIndex.search(ix2, q).first?.path ?? "", "活动/一技半解·圆桌｜Personal Agent.md")
    }
    let fm = FileManager.default.temporaryDirectory.appendingPathComponent("qob-fm-\(UUID().uuidString).md")
    defer { try? FileManager.default.removeItem(at: fm) }
    try? "---\ntitle: x\naliases:\n  - 置身\n  - \"Inside\"\n---\n正文".write(to: fm, atomically: true, encoding: .utf8)
    check("aliases: block list", VaultIndex.aliases(of: fm).joined(separator: ","), "置身,Inside")
    try? "---\naliases: [甲, 乙]\n---".write(to: fm, atomically: true, encoding: .utf8)
    check("aliases: inline list", VaultIndex.aliases(of: fm).joined(separator: ","), "甲,乙")
    try? "开头\n## 第二章 土地财政是关键机制，后面还有很长很长很长很长很长很长的内容".write(to: fm, atomically: true, encoding: .utf8)
    check("content snippet", ContentSearch.snippet(in: fm, for: "土地财政") ?? "", "第二章 土地财政是关键机制，后面还有很长很长很长很长很长很长的内容")

    // Drops arrive through real pasteboards.
    let dm = CaptureModel()
    let pb = NSPasteboard.withUniqueName()
    let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("qob-drop-\(UUID().uuidString).txt")
    try? "x".write(to: tmpFile, atomically: true, encoding: .utf8)
    pb.clearContents(); pb.writeObjects([tmpFile as NSURL])
    dm.dropHandler?.perform(pb)
    check("drop: file url → attachment", dm.attachments.map(\.lastPathComponent).joined(), tmpFile.lastPathComponent)
    pb.clearContents(); pb.setData(Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]), forType: NSPasteboard.PasteboardType("com.compuserve.gif"))
    dm.dropHandler?.perform(pb)
    check("drop: gif data keeps .gif", dm.attachments.last?.pathExtension ?? "", "gif")
    pb.clearContents()
    let item = NSPasteboardItem()
    item.setString("https://example.com/a", forType: .URL)
    item.setString("示例页面", forType: NSPasteboard.PasteboardType("public.url-name"))
    pb.writeObjects([item])
    dm.dropHandler?.perform(pb)
    check("drop: link → markdown", dm.text, "[示例页面](https://example.com/a)")
    check("drop: text is not media", String(MediaDropHandler.isMedia(pb)), "false")
    dm.discardTemp()
    try? FileManager.default.removeItem(at: tmpFile)
    pb.releaseGlobally()

    // Writer: append in place (blank line between paragraph entries), amend, undo.
    let vault = FileManager.default.temporaryDirectory.appendingPathComponent("qob-selftest-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: vault) }
    let w = DailyNoteWriter(vault: vault, attachmentOverride: "", format: fmt(.plain, time: false))
    let note = w.noteURL(for: Date())
    try? FileManager.default.createDirectory(at: note.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? "# 今天".write(to: note, atomically: true, encoding: .utf8)          // no trailing newline
    _ = try? w.append(content: "第一条", attachments: [], source: src)
    _ = try? w.append(content: "第二条", attachments: [], source: nil)
    if let last = History.last { try? w.amend(last, text: "我的想法", attachments: []) }
    check("writer: append + amend", (try? String(contentsOf: note, encoding: .utf8)) ?? "",
          "# 今天\n\n第一条\n> Claude\n\n第二条\n\n我的想法\n")
    try? History.undoLast()
    check("writer: undo", (try? String(contentsOf: note, encoding: .utf8)) ?? "", "# 今天\n\n第一条\n> Claude\n")
    let lw = DailyNoteWriter(vault: vault, attachmentOverride: "", format: fmt(.list, time: false, source: false))
    _ = try? lw.append(content: "列表一", attachments: [], source: nil)
    _ = try? lw.append(content: "列表二", attachments: [], source: nil)
    check("writer: list entries stay tight", (try? String(contentsOf: note, encoding: .utf8)) ?? "",
          "# 今天\n\n第一条\n> Claude\n- 列表一\n- 列表二\n")

    let created = try? w.createNote(folder: "Inbox/新", title: "读书: 置身事内", content: "第一段", attachments: [], source: src)
    check("new note: path", created.map { String($0.path.dropFirst(vault.path.count + 1)) } ?? "", "Inbox/新/读书 置身事内.md")
    if let last = History.last { try? w.amend(last, text: "补充", attachments: []) }
    check("new note: amend", created.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "", "第一段\n\n> Claude\n\n补充\n")
    let second = try? w.createNote(folder: "Inbox/新", title: "读书: 置身事内", content: "另一篇", attachments: [])
    check("new note: unique name", second?.lastPathComponent ?? "", "读书 置身事内 1.md")
    try? History.undoLast()
    check("new note: undo removes file", String(second.map { FileManager.default.fileExists(atPath: $0.path) } ?? true), "false")
    if let created { _ = try? w.append(content: "追加一条", attachments: [], to: created) }
    check("append to note", created.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "",
          "第一段\n\n> Claude\n\n补充\n\n追加一条\n")

    // Plain folder vs Obsidian vault conventions, OCR blocks, link titles.
    let png = FileManager.default.temporaryDirectory.appendingPathComponent("qob-ocr-\(UUID().uuidString)/截图 1.png")
    try? FileManager.default.createDirectory(at: png.deletingLastPathComponent(), withIntermediateDirectories: true)
    let canvas = NSImage(size: NSSize(width: 900, height: 220))
    canvas.lockFocus()
    NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 900, height: 220).fill()
    ("Hello 乔木闪记\n截图文字识别测试" as NSString).draw(at: NSPoint(x: 30, y: 60), withAttributes: [.font: NSFont.systemFont(ofSize: 48)])
    canvas.unlockFocus()
    if let tiff = canvas.tiffRepresentation, let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
        try? data.write(to: png)
    }
    let recognized = OCR.text(in: png) ?? ""
    check("ocr: english + chinese", String(recognized.contains("Hello") && recognized.contains("乔木闪记")), "true")

    let plainVault = vault.appendingPathComponent("plain")
    let pw = DailyNoteWriter(vault: plainVault, attachmentOverride: "", format: fmt(.plain, time: false, source: false))
    let plainNote = try? pw.append(content: "看图", attachments: [png], ocr: [png.path: "第一行\n第二行"])
    check("plain: standard image link + details", plainNote.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "",
          "看图\n![截图 1](../%E9%99%84%E4%BB%B6/%E6%88%AA%E5%9B%BE%201.png)\n<details><summary>图中文字</summary>\n\n第一行  \n第二行\n\n</details>\n")
    check("plain: attachment in 附件/", String(FileManager.default.fileExists(atPath: plainVault.appendingPathComponent("附件/截图 1.png").path)), "true")
    let obsVault = vault.appendingPathComponent("obs")
    try? FileManager.default.createDirectory(at: obsVault.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
    let ow = DailyNoteWriter(vault: obsVault, attachmentOverride: "", format: fmt(.plain, time: false, source: false))
    let obsNote = try? ow.append(content: "看图", attachments: [png], ocr: [png.path: "第一行"])
    check("obsidian: wikilink embed + folded callout", obsNote.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "",
          "看图\n![[截图 1.png]]\n> [!note]- 图中文字\n> 第一行\n")
    try? FileManager.default.removeItem(at: png.deletingLastPathComponent())

    // Clipboard fallback (on a private pasteboard) and the screenshot finder (on a temp folder).
    let cpb = NSPasteboard.withUniqueName()
    cpb.clearContents(); cpb.setString("旧内容", forType: .string)
    let watcher = ClipboardWatcher(pasteboard: cpb)
    check("clip: older copy not recent", String(watcher.clip(within: 300) == nil), "true")
    check("clip: older copy still usable", watcher.clip()?.kindLabel ?? "", "文字")
    cpb.clearContents(); cpb.setString("刚复制的文字", forType: .string)
    check("clip: fresh text", watcher.clip(within: 300)?.grabbed.text ?? "", "刚复制的文字")
    watcher.consume()
    check("clip: saved only once", String(watcher.clip() == nil), "true")
    cpb.clearContents(); cpb.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
    check("clip: image", watcher.clip(within: 300)?.kindLabel ?? "", "图片")
    cpb.clearContents()
    let concealed = NSPasteboardItem()
    concealed.setString("secret", forType: .string)
    concealed.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    cpb.writeObjects([concealed])
    check("clip: password manager copy ignored", String(watcher.clip() == nil), "true")
    cpb.clearContents(); cpb.writeObjects([vault as NSURL])
    check("clip: folders skipped", String(watcher.clip() == nil), "true")
    cpb.releaseGlobally()
    let shots = vault.appendingPathComponent("shots")
    try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
    for n in ["截屏2026-11-04 下午2.32.10.png", "notes.png", "Screen Recording 2026-11-04.mov"] {
        FileManager.default.createFile(atPath: shots.appendingPathComponent(n).path, contents: Data([0]))
    }
    let newest = ScreenshotFinder.latest(in: shots)?.url
    check("screenshot: finds a capture", String(newest.map { ["截屏2026-11-04 下午2.32.10.png", "Screen Recording 2026-11-04.mov"].contains($0.lastPathComponent) } ?? false), "true")
    newest.map(ScreenshotFinder.consume)
    let nextShot = ScreenshotFinder.latest(in: shots)?.url
    check("screenshot: each used once", String(nextShot != nil && nextShot != newest), "true")
    nextShot.map(ScreenshotFinder.consume)
    check("screenshot: ignores other files", String(ScreenshotFinder.latest(in: shots) == nil), "true")

    // Scenes
    check("scene parse: note", Recipe.parse("Inbox/灵感").map { "\($0.kind.rawValue):\($0.path)" } ?? "", "note:Inbox/灵感.md")
    check("scene parse: note .md", Recipe.parse("待办.md").map { "\($0.kind.rawValue):\($0.path)" } ?? "", "note:待办.md")
    check("scene parse: folder", Recipe.parse("读书/").map { "\($0.kind.rawValue):\($0.path)" } ?? "", "folder:读书")
    check("scene parse: label roundtrip", Recipe.parse(Recipe.label(Destination(kind: .folder, path: "读书"))).map(\.path) ?? "", "读书")
    check("scene parse: daily", Recipe.parse("今日日记")?.kind.rawValue ?? "", "daily")
    let encoded = try? JSONEncoder().encode(Recipe.presets)
    check("scene presets roundtrip", (encoded.flatMap { try? JSONDecoder().decode([Recipe].self, from: $0) })?.map(\.name).joined(separator: ",") ?? "",
          "灵感,待办,读书摘录,稍后读,工作日志")

    // WeChat-style copy: a link into another app's container plus the image data → use the data.
    let wpb = NSPasteboard.withUniqueName()
    let item2 = NSPasteboardItem()
    item2.setString("file:///Users/x/Library/Containers/com.tencent.xinWeChat/Data/tmp/ae980d29.attachments", forType: .fileURL)
    item2.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
    wpb.writeObjects([item2])
    let wg = SelectionGrabber.read(wpb)
    check("container link with image data → data", "\(wg.files.count) files, \(wg.media.count) media", "0 files, 1 media")
    wpb.releaseGlobally()
    // An unreadable attachment is skipped, the rest of the capture is kept.
    let sv = FileManager.default.temporaryDirectory.appendingPathComponent("qob-skip-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: sv) }
    History.skipped = []
    let sw = DailyNoteWriter(vault: sv, attachmentOverride: "", format: fmt(.plain, time: false, source: false))
    let sn = try? sw.append(content: "文字还在", attachments: [URL(fileURLWithPath: "/nonexistent/protected.png")])
    check("unreadable attachment skipped", (sn.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "") + "|" + History.skipped.joined(), "文字还在\n|protected.png")

    check("link title: og:title", LinkTitle.parse("<head><meta property=\"og:title\" content=\"置身事内 &amp; 读书\"><title>x</title>") ?? "", "置身事内 & 读书")
    check("link title: <title>", LinkTitle.parse("<title>\n  Hello &#x4E16;&#30028; \n</title>") ?? "", "Hello 世界")

    // Page description (og:description first, <meta name=description> fallback), entities and truncation.
    check("desc: og:description + entity", LinkTitle.parseDescription(#"<meta property="og:description" content="一篇讲 JEPA 的长文 &amp; 备注"><meta name="description" content="fallback">"#) ?? "",
          "一篇讲 JEPA 的长文 & 备注")
    check("desc: name=description fallback", LinkTitle.parseDescription(#"<meta content="后备" name="description">"#) ?? "", "后备")
    let long = String(repeating: "长", count: 200)
    check("desc: truncates to 160", String(LinkTitle.parseDescription("<meta property=\"og:description\" content=\"\(long)\">")?.count ?? 0), "161")
    check("desc: missing", LinkTitle.parseDescription("<p>没写描述</p>") ?? "nil", "nil")

    // Merge target: the latest modified candidate that really contains the URL.
    let mv = FileManager.default.temporaryDirectory.appendingPathComponent("qob-merge-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: mv, withIntermediateDirectories: true)
    let oldNote = mv.appendingPathComponent("旧.md"), newNote = mv.appendingPathComponent("新.md")
    try? "看[链接](https://a.com/x) 的笔记".write(to: oldNote, atomically: true, encoding: .utf8)
    try? "又提到了 https://a.com/x 第二次".write(to: newNote, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: oldNote.path)
    check("merge: latest containing file wins", MergeTarget.pick(paths: ["旧.md", "新.md"], url: "https://a.com/x", in: mv)?.file.lastPathComponent ?? "", "新.md")
    try? "没有这个网址".write(to: newNote, atomically: true, encoding: .utf8)
    check("merge: files without the url are ignored", MergeTarget.pick(paths: ["旧.md", "新.md"], url: "https://a.com/x", in: mv)?.file.lastPathComponent ?? "", "旧.md")
    check("merge: the matched line comes back for amend", MergeTarget.pick(paths: ["旧.md", "新.md"], url: "https://a.com/x", in: mv)?.entry ?? "", "看[链接](https://a.com/x) 的笔记")
    check("merge: no candidates", String(MergeTarget.pick(paths: [], url: "https://a.com/x", in: mv) == nil), "true")
    try? FileManager.default.removeItem(at: mv)

    // Selected text of a recorded page becomes a capped one-line H2 under its entry.
    check("heading: collapse + H2", CaptureFormatter.sectionHeading(from: "  a\n\nb  ") ?? "", "## a b")
    check("heading: marks stripped", CaptureFormatter.sectionHeading(from: "### 标题 ##") ?? "", "## 标题")
    check("heading: capped", String(CaptureFormatter.sectionHeading(from: String(repeating: "字", count: 200))?.count ?? 0), "44")
    check("heading: whitespace only is nil", String(CaptureFormatter.sectionHeading(from: "   ") == nil), "true")
    check("adblock: bundled host list ships with the app", String(WebSnapshot.adHosts.count > 3000), "true")

    print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
    return failures == 0 ? 0 : 1
}

/// `Jot --search <vault> <query>`: run the picker's search (names + Spotlight contents) from the shell.
if let i = CommandLine.arguments.firstIndex(of: "--search"), i + 2 < CommandLine.arguments.count {
    let vault = URL(fileURLWithPath: CommandLine.arguments[i + 1]), q = CommandLine.arguments[i + 2]
    let t0 = Date()
    let idx = VaultIndex.scan(vault)
    print("indexed \(idx.count) items in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
    for d in VaultIndex.search(idx, q).prefix(8) { print("  name   ", d.path) }
    var done = false
    let cs = ContentSearch()
    let t1 = Date()
    cs.run(q, in: vault) { hits in
        print("content (\(Int(Date().timeIntervalSince(t1) * 1000)) ms):")
        for (d, snip) in hits.prefix(8) { print("  ", d.path, "—", snip) }
        done = true
    }
    while !done && Date().timeIntervalSince(t1) < 10 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    exit(0)
}

/// `Jot --context`: print what SourceContext currently sees (debugging capture sources).
if CommandLine.arguments.contains("--context") {
    _ = NSApplication.shared
    if let ctx = SourceContext.current() {
        print("app:   \(ctx.appName) (\(ctx.bundleID))")
        print("kind:  \(String(describing: ctx.kind))")
        print("url:   \(ctx.url?.absoluteString ?? "nil")")
        print("title: \(ctx.pageTitle ?? "nil")")
        if let note = ctx.scriptNote { print("note:  \(note)") }
    } else {
        print("nil")
    }
    exit(0)
}

/// `Jot --websnapshot <url> <out.png>`: render a page offscreen and save its top viewport (CI smoke).
if let i = CommandLine.arguments.firstIndex(of: "--websnapshot"), i + 2 < CommandLine.arguments.count {
    _ = NSApplication.shared
    let url = URL(string: CommandLine.arguments[i + 1])!
    let out = URL(fileURLWithPath: CommandLine.arguments[i + 2])
    print("snapshotting \(url) …")
    WebSnapshot.capture(url) { file in
        if let file {
            try? FileManager.default.removeItem(at: out)
            try? FileManager.default.copyItem(at: file, to: out)
            print("saved \(out.path)")
        } else {
            print("snapshot failed")
        }
        exit(file == nil ? 1 : 0)
    }
    RunLoop.main.run()
}

if CommandLine.arguments.contains("--selftest") {
    _ = NSApplication.shared
    exit(selftest())
}

if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    Theme.registerFonts()
    let a = CommandLine.arguments
    snapshot(a[i + 1], text: i + 2 < a.count ? a[i + 2] : "", dark: a.contains("--dark"))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
