import SwiftUI
import AppKit
import KeyboardShortcuts
import ServiceManagement
import ApplicationServices

// MARK: - Save sounds

/// Save feedback sounds: Kenney Interface Sounds (CC0, bundled) and the macOS system sounds.
enum SaveSound {
    static let none = "none"
    static let bundled: [(id: String, name: String)] = [
        ("kenney:confirmation_001", "确认 1"), ("kenney:confirmation_002", "确认 2"),
        ("kenney:confirmation_003", "确认 3"), ("kenney:confirmation_004", "确认 4"),
        ("kenney:glass_001", "玻璃"), ("kenney:glass_004", "玻璃 · 长"), ("kenney:pluck_002", "拨弦"),
        ("kenney:drop_002", "水滴"), ("kenney:bong_001", "轻敲"), ("kenney:maximize_006", "展开"),
    ]
    static let system: [(id: String, name: String)] = [
        ("Pop", "啵"), ("Tink", "叮"), ("Glass", "玻璃杯"), ("Ping", "乒"), ("Purr", "呼噜"), ("Bottle", "瓶子"),
        ("Hero", "英雄"), ("Submarine", "潜水艇"), ("Funk", "放克"), ("Blow", "吹气"), ("Frog", "青蛙"), ("Morse", "摩斯"),
    ]

    private static var current: NSSound?

    static func play(_ id: String) {
        guard id != none else { return }
        current?.stop()
        if id.hasPrefix("kenney:"),
           let url = Bundle.main.resourceURL?.appendingPathComponent("Sounds/kenney-\(id.dropFirst(7)).wav") {
            current = NSSound(contentsOf: url, byReference: true)
        } else {
            current = NSSound(named: id)
        }
        current?.play()
    }
}

// MARK: - Time formats

enum TimeFormats {
    static let custom = "__custom__"
    static let presets: [(format: String, note: String)] = [
        ("HH:mm", "24 小时"), ("HH:mm:ss", "含秒"), ("A h:mm", "12 小时"),
        ("M月D日 HH:mm", "日期与时间"), ("YYYY-MM-DD HH:mm", "完整日期"), ("[[YYYY-MM-DD]] HH:mm", "链接到当天日记"),
    ]
    static func sample(_ f: String) -> String { MomentFormat.string(Date(), format: f.isEmpty ? "HH:mm" : f) }
}

// MARK: - Window

/// Standard macOS preferences: toolbar tabs, one short page each.
/// Window title follows the tab: "乔木闪记 · 通用".
final class SettingsTabs: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        view.window?.title = "\(AppInfo.name) · \(item?.label ?? "设置")"
        view.window?.makeFirstResponder(nil)      // never auto-focus a shortcut recorder
    }
}

enum SettingsWindow {
    static func make() -> NSWindow {
        let tabs = SettingsTabs()
        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = false
        func tab<V: View>(_ title: String, _ symbol: String, _ view: V) {
            let host = NSHostingController(rootView: view)
            host.sizingOptions = [.preferredContentSize]
            let item = NSTabViewItem(viewController: host)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        tab("通用", "gearshape", GeneralSettings())
        tab("场景", "rectangle.stack", RecipeSettings())
        tab("记录", "text.quote", RecordSettings())
        tab("保存", "tray.and.arrow.down", SaveSettings())
        tab("关于", "info.circle", AboutSettings())
        let w = NSWindow(contentViewController: tabs)
        w.styleMask = [.titled, .closable]
        w.toolbarStyle = .preference
        w.title = "\(AppInfo.name) · 通用"
        w.initialFirstResponder = nil
        w.isReleasedWhenClosed = false
        w.center()
        return w
    }
}

private let settingsWidth: CGFloat = 520

// MARK: - 通用

struct GeneralSettings: View {
    @ObservedObject var prefs = Prefs.shared
    @State private var folders = Prefs.shared.knownFolders
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var trusted = AXIsProcessTrusted()

    private var onboardingDone: Bool { prefs.vaultExists && trusted && prefs.didFirstCapture }

    var body: some View {
        Form {
            if !prefs.onboardingDismissed && !onboardingDone {
                Section {
                    OnboardingStep(n: 1, title: "选择保存位置", detail: "Obsidian 仓库或任意文件夹", done: prefs.vaultExists,
                                   action: ("选择…", chooseVault))
                    OnboardingStep(n: 2, title: "开启「辅助功能」", detail: "用来读取其他 App 里选中的内容", done: trusted,
                                   action: ("去开启…", {
                                       _ = SelectionGrabber.ensureAccessibility(prompt: true)
                                       NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                                   }))
                    OnboardingStep(n: 3, title: "试一次", detail: "在任意 App 按 \(KeyboardShortcuts.getShortcut(for: .capture)?.description ?? "打开输入框的快捷键")，写一句话，按 ⌘↩ 保存", done: prefs.didFirstCapture,
                                   action: ("现在试试", { (NSApp.delegate as? AppDelegate)?.toggle() }))
                } header: {
                    HStack {
                        Text("开始使用")
                        Spacer()
                        Button("不再显示") { prefs.onboardingDismissed = true }.buttonStyle(.borderless).font(.caption)
                    }
                }
            }
            Section {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppInfo.name).font(.system(size: 14, weight: .semibold))
                        Text("\(AppInfo.englishName) · 版本 \(AppInfo.version) · 在菜单栏运行").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if trusted {
                        Label("权限已就绪", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if prefs.onboardingDismissed || onboardingDone {
                        Button("开启辅助功能…") {
                            _ = SelectionGrabber.ensureAccessibility(prompt: true)
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                        .help("收录其他 App 中选中的内容需要这个权限")
                    }
                }
            }
            Section("快捷键") {
                KeyboardShortcuts.Recorder("打开输入框", name: .capture)
                KeyboardShortcuts.Recorder("收录选中内容", name: .quickSave)
            }
            Section {
                Picker("保存位置", selection: $prefs.vaultPath) {
                    if prefs.vaultPath.isEmpty { Text("未选择").tag("") }
                    ForEach(folders, id: \.self) { f in
                        Text((f as NSString).lastPathComponent + (FolderMode.isObsidianVault(URL(fileURLWithPath: f)) ? "" : "（文件夹）")).tag(f)
                    }
                }
                .onChange(of: prefs.vaultPath) { path in
                    if !FolderMode.isObsidianVault(URL(fileURLWithPath: path)) { prefs.rememberFolder(path) }
                }
                LabeledContent("位置") {
                    HStack(spacing: 8) {
                        Text(prefs.vaultPath.isEmpty ? "—" : (prefs.vaultPath as NSString).abbreviatingWithTildeInPath)
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("选择…") { chooseVault() }
                    }
                }
                if !prefs.isObsidianVault && !prefs.vaultPath.isEmpty {
                    LabeledContent("日记文件夹") {
                        TextField("", text: $prefs.plainDailyFolder, prompt: Text("日记")).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("日记文件名") {
                        HStack(spacing: 8) {
                            TextField("", text: $prefs.plainDailyFormat, prompt: Text("YYYY-MM-DD"))
                                .multilineTextAlignment(.trailing).font(.system(size: 12, design: .monospaced))
                            Text(TimeFormats.sample(prefs.plainDailyFormat.isEmpty ? "YYYY-MM-DD" : prefs.plainDailyFormat) + ".md")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                HStack(alignment: .top, spacing: 6) {
                    SourceGlyph(bundleID: prefs.isObsidianVault ? "md.obsidian" : "", kind: .finder, size: 11, color: .secondary)
                        .padding(.top, 1)
                    Text(prefs.isObsidianVault
                         ? "Obsidian 仓库：日记的位置、文件名和模板沿用「日记」插件，附件用 ![[ ]] 嵌入。"
                         : "普通文件夹：不需要 Obsidian。附件存进「附件」，用标准 Markdown 链接，Typora、VS Code、iA Writer 都能打开。"
                           + (FolderMode.obsidianInstalled ? "" : "（未检测到 Obsidian）"))
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("登录时自动启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { on in
                        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                        prefs.launchAtLogin = launchAtLogin
                    }
            }
        }
        .formStyle(.grouped)
        .frame(width: settingsWidth, height: (prefs.isObsidianVault ? 450 : 540) + (!prefs.onboardingDismissed && !onboardingDone ? 190 : 0))
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in trusted = AXIsProcessTrusted() }
        .onAppear {
            folders = prefs.knownFolders
        }
    }

    private func chooseVault() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.message = "选择 Obsidian 仓库，或任意用来保存 Markdown 的文件夹"
        if p.runModal() == .OK, let u = p.url {
            prefs.vaultPath = u.path
            folders = prefs.knownFolders
        }
    }
}

private struct OnboardingStep: View {
    let n: Int
    let title: String
    let detail: String
    let done: Bool
    let action: (String, () -> Void)

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.primary : Color.primary.opacity(0.08)).frame(width: 22, height: 22)
                if done { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Color(nsColor: .windowBackgroundColor)) }
                else { Text("\(n)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary) }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium)).strikethrough(done, color: .secondary)
                    .foregroundStyle(done ? .secondary : .primary)
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if !done { Button(action.0, action: action.1).controlSize(.small) }
        }
        .animation(.easeOut(duration: 0.2), value: done)
    }
}

// MARK: - 记录

struct RecordSettings: View {
    @ObservedObject var prefs = Prefs.shared
    @State private var customTime = false
    @State private var showSource = false

    private var style: EntryStyle { EntryStyle(rawValue: prefs.entryStyle) ?? .plain }

    var body: some View {
        Form {
            Section {
                if showSource {
                    MarkdownPreview(text: preview).frame(height: 132)
                } else {
                    NotePreview(markdown: preview, title: CaptureModel.todayNote?.deletingPathExtension().lastPathComponent ?? "今日日记")
                }
            } header: {
                HStack {
                    Text("预览")
                    Spacer()
                    Picker("", selection: $showSource) {
                        Text("效果").tag(false)
                        Text("Markdown").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
                }
            } footer: {
                Text("保存的内容原样写入，不会自动加列表点或引用符号。").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("样式", selection: $prefs.entryStyle) {
                    ForEach(EntryStyle.allCases) { Text($0.title).tag($0.rawValue) }
                }
                if style == .custom { templateEditor }
            }
            Section {
                Toggle("显示时间", isOn: $prefs.timestamp)
                if prefs.timestamp {
                    Picker("格式", selection: timeSelection) {
                        ForEach(TimeFormats.presets, id: \.format) { p in
                            Text("\(TimeFormats.sample(p.format))　\(p.note)").tag(p.format)
                        }
                        Divider()
                        Text("自定义…").tag(TimeFormats.custom)
                    }
                    if customTime { customTimeField }
                }
                Toggle("显示来源", isOn: $prefs.showSource)
                    .help("网页标题链接、App 名称、PDF 文件与页码、书名与作者")
            }
            Section {
                Toggle("识别截图里的文字", isOn: $prefs.ocrImages)
                    .help("在本机识别中英文，写进图片下方默认折叠的块里，之后能在笔记里搜到")
                Toggle("粘贴链接时换成网页标题", isOn: $prefs.linkTitles)
                    .help("粘贴 https://… 后自动变成 [网页标题](链接)，⌘Z 可还原")
            } footer: {
                Text("截图文字在本机识别，写进图片下方的折叠块，日后可以搜索到。").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("空选时收录剪贴板", isOn: $prefs.clipboardFallback)
                    .help("按 ⌘⇧K 没有选中内容时，收录剪贴板里刚复制的内容；关掉后跳过剪贴板，仍收录刚截的屏、录屏和当前网页")
            }
            Section {
                Toggle("存网页时附上页面描述", isOn: $prefs.pageDescription)
                    .help("存网页链接时顺带抓取页面描述（og:description）写在链接下方，日后能搜到")
                Toggle("存网页时自动附上头部截图", isOn: $prefs.pageSnapshot)
                    .help("后台渲染网页顶部并自动补到该条下方；渲染器没有浏览器登录态，登录墙站点会失败")
            }
        }
        .formStyle(.grouped)
        .frame(width: settingsWidth,
               height: 700 + (prefs.timestamp ? 44 : 0) + (prefs.timestamp && customTime ? 120 : 0) + (style == .custom ? 112 : 0))
        .onAppear { customTime = !TimeFormats.presets.contains { $0.format == prefs.timeFormat } }
    }

    private var timeSelection: Binding<String> {
        Binding(get: { customTime ? TimeFormats.custom : prefs.timeFormat },
                set: { v in
                    if v == TimeFormats.custom { customTime = true } else { customTime = false; prefs.timeFormat = v }
                })
    }

    private var customTimeField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("自定义格式", text: $prefs.timeFormat, prompt: Text("HH:mm"))
                    .font(.system(size: 12, design: .monospaced))
                Text(TimeFormats.sample(prefs.timeFormat)).foregroundStyle(.secondary).monospacedDigit()
            }
            Text("""
            YYYY 年 · MM 月 · DD 日 · HH 时 · mm 分 · ss 秒
            hh 12 小时制 · A 上午/下午 · dddd 星期 · [文字] 原样输出
            """)
            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private var templateEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $prefs.customTemplate)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 64)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            HStack(spacing: 4) {
                ForEach(["content", "time", "date", "source", "app", "title", "url", "attachments"], id: \.self) { v in
                    Button("{{\(v)}}") { prefs.customTemplate += "{{\(v)}}" }
                        .buttonStyle(.borderless).font(.system(size: 10, design: .monospaced))
                }
            }
            .help("点击插入变量；时间可写成 {{time:HH:mm}}")
        }
    }

    private var preview: String {
        let f = EntryFormat(template: style == .custom ? prefs.customTemplate : style.template,
                            showTime: prefs.timestamp, timeFormat: prefs.timeFormat.isEmpty ? "HH:mm" : prefs.timeFormat,
                            showSource: prefs.showSource)
        let one = f.render(content: "土地财政是地方政府推动工业化的关键机制。", attachments: [], source: Prefs.sampleSource)
        let two = f.render(content: "明天把第四章读完", attachments: [],
                           source: SourceInfo(app: "Claude", bundleID: "com.anthropic.claudefordesktop", kind: .other),
                           date: Date().addingTimeInterval(900))
        return (one + (f.isList ? "" : "\n") + two).trimmingCharacters(in: .newlines)
    }
}

// MARK: - 保存

struct SaveSettings: View {
    @ObservedObject var prefs = Prefs.shared

    var body: some View {
        Form {
            Section {
                Picker("打开时保存到", selection: $prefs.rememberDestination) {
                    Text("今日日记").tag(false)
                    Text("上次使用的位置").tag(true)
                }
                LabeledContent("插入到标题下") {
                    TextField("", text: $prefs.insertHeading, prompt: Text("留空则追加到末尾"))
                        .multilineTextAlignment(.trailing)
                }
            } footer: {
                Text("填写标题（如「随记」）后，今日日记的内容放进该标题的段落末尾，没有则自动创建。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("附件文件夹") {
                    HStack(spacing: 8) {
                        TextField("", text: $prefs.attachmentFolder, prompt: Text("沿用 Obsidian 设置"))
                            .multilineTextAlignment(.trailing)
                        Button("选择…") { chooseAttachmentFolder() }
                    }
                }
                Toggle("保存后在 Obsidian 中打开", isOn: $prefs.openAfterSave)
            }
            Section {
                LabeledContent("提示音") {
                    HStack(spacing: 6) {
                        Picker("", selection: $prefs.saveSound) {
                            Text("无").tag(SaveSound.none)
                            Section("界面音效 · Kenney") {
                                ForEach(SaveSound.bundled, id: \.id) { Text($0.name).tag($0.id) }
                            }
                            Section("系统声音") {
                                ForEach(SaveSound.system, id: \.id) { Text($0.name).tag($0.id) }
                            }
                        }
                        .labelsHidden().fixedSize()
                        Button { SaveSound.play(prefs.saveSound) } label: { Image(systemName: "play.fill") }
                            .disabled(prefs.saveSound == SaveSound.none)
                            .help("试听")
                    }
                }
                .onChange(of: prefs.saveSound) { SaveSound.play($0) }
                LabeledContent("输入框位置") {
                    Button("恢复默认位置") { prefs.panelX = .nan; prefs.panelY = .nan }
                }
            } footer: {
                Text("选择即可试听。界面音效来自 Kenney Interface Sounds（CC0）。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: settingsWidth, height: 430)
    }

    private func chooseAttachmentFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.message = "选择仓库里的附件文件夹"
        if let vault = prefs.vaultURL { p.directoryURL = vault }
        guard p.runModal() == .OK, let u = p.url, let vault = prefs.vaultURL else { return }
        let root = vault.standardizedFileURL.path, path = u.standardizedFileURL.path
        if path == root { prefs.attachmentFolder = "/" }
        else if path.hasPrefix(root + "/") { prefs.attachmentFolder = String(path.dropFirst(root.count + 1)) }
        else { NSSound.beep() }      // must be inside the vault
    }
}

/// The entries as Obsidian would show them in reading view: white page, inline title, rendered blocks.
struct NotePreview: View {
    let markdown: String
    let title: String

    private enum Block: Hashable {
        case paragraph(String), meta(String), bullet(String), task(String, Bool), quote([String]), callout(String, [String]), embed(String), gap
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var para: [String] = []
        var quote: [String] = []
        var callout: (String, [String])?
        func flush() {
            if !para.isEmpty { out.append(.paragraph(para.joined(separator: "\n"))); para = [] }
            if !quote.isEmpty { out.append(.quote(quote)); quote = [] }
            if let c = callout { out.append(.callout(c.0, c.1)); callout = nil }
        }
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("> [!") {
                flush()
                let title = line.replacingOccurrences(of: #"^> \[![\w-]+\][-+]?\s*"#, with: "", options: .regularExpression)
                callout = (title, [])
            } else if line.hasPrefix(">") {
                let body = line.replacingOccurrences(of: #"^>\s?"#, with: "", options: .regularExpression)
                if callout != nil { callout!.1.append(body) } else { if !para.isEmpty { flush() }; quote.append(body) }
            } else {
                if callout != nil || !quote.isEmpty { flush() }
                if line.isEmpty { flush(); if out.last != .gap { out.append(.gap) } }
                else if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") { flush(); out.append(.task(String(line.dropFirst(6)), line.hasPrefix("- [x]"))) }
                else if line.hasPrefix("- ") { flush(); out.append(.bullet(String(line.dropFirst(2)))) }
                else if line.hasPrefix("— ") { flush(); out.append(.meta(String(line.dropFirst(2)))) }
                else if line.hasPrefix("![") { flush(); out.append(.embed(line)) }
                else if raw.hasPrefix("  "), case .bullet(let b)? = out.last { out[out.count - 1] = .bullet(b + "\n" + line) }
                else { para.append(line) }
            }
        }
        flush()
        while out.last == .gap { out.removeLast() }
        return out
    }

    private func inline(_ s: String) -> AttributedString {
        let src = s.replacingOccurrences(of: #"==([^=]+)=="#, with: "$1", options: .regularExpression)
        var a = (try? AttributedString(markdown: src, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(src)
        for run in a.runs where run.link != nil { a[run.range].underlineStyle = .single }
        return a
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 19, weight: .bold)).padding(.bottom, 4)
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                switch b {
                case .paragraph(let t):
                    Text(inline(t)).lineSpacing(3)
                case .meta(let t):
                    Text(inline("— " + t)).font(.system(size: 12)).foregroundStyle(.secondary)
                case .bullet(let t):
                    HStack(alignment: .firstTextBaseline, spacing: 8) { Text("•").foregroundStyle(.secondary); Text(inline(t)) }
                case .task(let t, let done):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: done ? "checkmark.square.fill" : "square").foregroundStyle(.secondary)
                        Text(inline(t)).strikethrough(done)
                    }
                case .quote(let lines):
                    Text(inline(lines.joined(separator: "\n"))).italic().foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                case .callout(let title, let lines):
                    VStack(alignment: .leading, spacing: 4) {
                        Label { Text(inline(title.isEmpty ? "Quote" : title)).fontWeight(.semibold) } icon: {
                            Image(systemName: "quote.opening")
                        }
                        if !lines.isEmpty { Text(inline(lines.joined(separator: "\n"))) }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                case .embed(let t):
                    Label(t.replacingOccurrences(of: #"[!\[\]()]"#, with: "", options: .regularExpression), systemImage: "photo")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(8).background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                case .gap:
                    Color.clear.frame(height: 4)
                }
            }
        }
        .font(.system(size: 13.5))
        .tint(.primary)
        .textSelection(.enabled)
        .padding(.horizontal, 20).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
        .padding(.vertical, 2)
    }
}

// MARK: - 关于

enum Links {
    static let repo = URL(string: "https://github.com/joeseesun/qiaomu-jot")!
    static let releases = URL(string: "https://github.com/joeseesun/qiaomu-jot/releases/latest")!
    static let issues = URL(string: "https://github.com/joeseesun/qiaomu-jot/issues/new")!
    static let readme = URL(string: "https://github.com/joeseesun/qiaomu-jot#readme")!
}

struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 22) {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 68, height: 68)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(AppInfo.name).font(.system(size: 20, weight: .semibold))
                        Text("\(AppInfo.englishName) \(AppInfo.version)").font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text("按一下快捷键，把想法、选中的文字、截图和文件，收进 Obsidian 或任意 Markdown 文件夹。")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                AboutAction(title: "检查更新", symbol: "arrow.triangle.2.circlepath") { Updater.shared.checkForUpdates() }
                AboutAction(title: "反馈问题", symbol: "ladybug", url: Links.issues)
                AboutAction(title: "使用说明", symbol: "book", url: Links.readme)
                AboutAction(title: "源代码", symbol: "chevron.left.forwardslash.chevron.right", url: Links.repo)
            }
            AutoUpdateToggle()
            HStack(spacing: 14) {
                QRCard(image: "wechat-qr.jpg", title: "关注公众号", symbol: "newspaper", hint: "微信搜索「向阳乔木推荐看」")
                QRCard(image: "reward-qr.png", title: "请我喝杯咖啡", symbol: "cup.and.saucer", hint: "微信扫码，支持持续更新")
            }
            VStack(spacing: 8) {
                HStack(spacing: 14) {
                    ForEach([("qiaomu.ai", "https://qiaomu.ai/"), ("博客", "https://blog.qiaomu.ai/"), ("乔木推荐", "https://tuijian.qiaomu.ai/"),
                             ("X", "https://x.com/vista8"), ("GitHub", "https://github.com/joeseesun"), ("邮箱", "mailto:vista8@gmail.com")],
                            id: \.0) { item in
                        Link(item.0, destination: URL(string: item.1)!).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.primary.opacity(0.75))
                    }
                }
                Text("内容只写入你选的本机文件夹，不上传；仅在获取网页标题时访问该网页。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Text("© 2026 向阳乔木 · MIT 许可 · 第三方许可见仓库 THIRD_PARTY_NOTICES.md")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 24)
        .frame(width: settingsWidth)
        .tint(.primary)
    }
}

private struct AboutAction: View {
    let title: String
    let symbol: String
    var url: URL? = nil
    var action: (() -> Void)? = nil
    @State private var hover = false

    init(title: String, symbol: String, url: URL) { self.title = title; self.symbol = symbol; self.url = url }
    init(title: String, symbol: String, action: @escaping () -> Void) { self.title = title; self.symbol = symbol; self.action = action }

    var body: some View {
        Button { if let action { action() } else if let url { NSWorkspace.shared.open(url) } } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(hover ? 0.09 : 0.05)))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.08)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct AutoUpdateToggle: View {
    @State private var on = Updater.shared.automaticallyChecks
    var body: some View {
        Toggle("自动检查更新（有新版时在菜单栏旁提示，不打断你）", isOn: $on)
            .toggleStyle(.checkbox).font(.system(size: 12)).foregroundStyle(.secondary)
            .onChange(of: on) { Updater.shared.automaticallyChecks = $0 }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct QRCard: View {
    let image: String
    let title: String
    let symbol: String
    let hint: String
    var body: some View {
        VStack(spacing: 10) {
            Group {
                if let url = Bundle.main.resourceURL?.appendingPathComponent("About/\(image)"),
                   let img = NSImage(contentsOf: url) {
                    Image(nsImage: img).resizable().interpolation(.high).scaledToFit()
                } else {
                    Color.primary.opacity(0.05)
                }
            }
            .frame(width: 136, height: 136)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
            VStack(spacing: 3) {
                Label(title, systemImage: symbol).font(.system(size: 13, weight: .semibold))
                Text(hint).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
    }
}

/// Read-only Markdown with the editor's live styling.
struct MarkdownPreview: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.textContainer?.widthTracksTextView = true
        tv.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView, tv.string != text else { return }
        tv.string = text
        if let storage = tv.textStorage { MarkdownStyler.apply(to: storage, size: 13) }
    }
}
