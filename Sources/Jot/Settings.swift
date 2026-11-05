import Foundation
import SwiftUI
import AppKit
import KeyboardShortcuts

enum AppInfo {
    /// Product name. The bundle is Jot.app; Finder shows 乔木闪记 on Chinese systems (InfoPlist.strings).
    static let name = "乔木闪记"
    static let englishName = "Jot"
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
}

extension KeyboardShortcuts.Name {
    static let capture = Self("capture", default: .init(.j, modifiers: [.command, .shift]))
    static let quickSave = Self("quickSave", default: .init(.k, modifiers: [.command, .shift]))
}

final class Prefs: ObservableObject {
    static let shared = Prefs()
    @AppStorage("vaultPath") var vaultPath: String = ""
    @AppStorage("attachmentFolder") var attachmentFolder: String = ""
    @AppStorage("timestamp") var timestamp: Bool = false
    @AppStorage("openAfterSave") var openAfterSave: Bool = false
    @AppStorage("insertHeading") var insertHeading: String = ""
    @AppStorage("saveSound") var saveSound: String = "kenney:glass_004"
    @AppStorage("showFormatBar") var showFormatBar: Bool = false
    @AppStorage("didOnboard") var didOnboard: Bool = false
    /// Set by the first successful save; ticks the last onboarding step.
    @AppStorage("didFirstCapture") var didFirstCapture: Bool = false
    @AppStorage("onboardingDismissed") var onboardingDismissed: Bool = false

    var vaultExists: Bool {
        var isDir: ObjCBool = false
        return !vaultPath.isEmpty && FileManager.default.fileExists(atPath: vaultPath, isDirectory: &isDir) && isDir.boolValue
    }
    /// The user's choice; re-applied at launch so it survives moving or renaming the app.
    @AppStorage("launchAtLogin") var launchAtLogin: Bool = true     // on by default; registered at first launch
    @AppStorage("rememberDestination") var rememberDestination: Bool = false
    @AppStorage("entryStyle") var entryStyle: String = EntryStyle.plain.rawValue
    @AppStorage("customTemplate") var customTemplate: String = EntryStyle.plain.template
    @AppStorage("timeFormat") var timeFormat: String = "HH:mm"
    @AppStorage("showSource") var showSource: Bool = true
    /// Text in pasted screenshots goes into a folded callout under the image (searchable in Obsidian).
    @AppStorage("ocrImages") var ocrImages: Bool = true
    /// A pasted bare link becomes [page title](url).
    @AppStorage("linkTitles") var linkTitles: Bool = true
    /// ⌘⇧K with nothing selected also saves what was just copied; off = skip the clipboard (screenshot and page link still work).
    @AppStorage("clipboardFallback") var clipboardFallback: Bool = true
    /// A saved page link also gets the page description under it (og:description, same request as the title).
    @AppStorage("pageDescription") var pageDescription: Bool = true
    /// A saved page link gets an offscreen render of the page top tucked under the entry.
    @AppStorage("pageSnapshot") var pageSnapshot: Bool = true
    /// Daily notes in a plain (non-Obsidian) folder.
    @AppStorage("plainDailyFolder") var plainDailyFolder: String = "日记"
    @AppStorage("plainDailyFormat") var plainDailyFormat: String = "YYYY-MM-DD"
    /// Non-Obsidian folders used before, newest first (newline separated).
    @AppStorage("recentFolders") var recentFoldersRaw: String = ""

    var recentFolders: [String] { recentFoldersRaw.split(separator: "\n").map(String.init) }

    func rememberFolder(_ path: String) {
        let list = [path] + recentFolders.filter { $0 != path }
        recentFoldersRaw = list.prefix(6).joined(separator: "\n")
    }

    var isObsidianVault: Bool { vaultURL.map(FolderMode.isObsidianVault) ?? false }

    /// Obsidian vaults plus plain folders used before, current first if neither.
    var knownFolders: [String] {
        var all = Self.discoverVaults()
        for f in recentFolders where !all.contains(f) && FileManager.default.fileExists(atPath: f) { all.append(f) }
        if !vaultPath.isEmpty && !all.contains(vaultPath) { all.insert(vaultPath, at: 0) }
        return all
    }

    /// Captures saved to today's daily note through this app (any entry format).
    func dailyCount(_ delta: Int = 0) -> Int {
        let key = "count-\(vaultPath)-\(MomentFormat.string(Date(), format: "YYYY-MM-DD"))"
        let n = max(0, UserDefaults.standard.integer(forKey: key) + delta)
        if delta != 0 { UserDefaults.standard.set(n, forKey: key) }
        return n
    }
    @AppStorage("draft") var draft: String = ""
    @AppStorage("recentTags") var recentTags: String = ""
    @AppStorage("panelX") var panelX: Double = .nan
    @AppStorage("panelY") var panelY: Double = .nan

    var vaultURL: URL? { vaultPath.isEmpty ? nil : URL(fileURLWithPath: vaultPath) }

    /// Vaults known to Obsidian itself, most recently opened first.
    static func discoverVaults() -> [String] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaults = obj["vaults"] as? [String: [String: Any]] else { return [] }
        return vaults.values
            .sorted { ($0["ts"] as? Double ?? 0) > ($1["ts"] as? Double ?? 0) }
            .compactMap { $0["path"] as? String }
    }
}
