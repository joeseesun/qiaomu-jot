import Foundation

/// Where a capture is saved: today's daily note (default), an existing note, or a new note in a folder.
struct Destination: Codable, Hashable {
    enum Kind: String, Codable { case daily, note, folder }
    var kind: Kind
    /// Vault-relative path: the note file (with .md) or the folder ("" = vault root).
    var path: String

    static let daily = Destination(kind: .daily, path: "")

    var name: String {
        switch kind {
        case .daily: return "今日日记"
        case .note: return ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        case .folder: return path.isEmpty ? "仓库根目录" : (path as NSString).lastPathComponent
        }
    }
    /// Parent folder shown in grey next to the name.
    var parent: String {
        let p = (path as NSString).deletingLastPathComponent
        return kind == .daily || p.isEmpty ? "" : p
    }
    var symbol: String {
        switch kind {
        case .daily: return "calendar"
        case .note: return "doc.text"
        case .folder: return "folder"
        }
    }
}

/// A folder or note plus the keys it can be found by.
struct IndexEntry {
    let destination: Destination
    let name: String        // lowercased
    let path: String        // lowercased
    let pinyin: String      // 置身事内 → zhishenshinei
    let initials: String    // 置身事内 → zssn
    let aliases: [String]   // frontmatter aliases, lowercased
}

/// Whole-vault search in the spirit of Obsidian's quick switcher: fuzzy names, pinyin, aliases;
/// note contents come from Spotlight (see `ContentSearch`).
enum VaultIndex {
    static func entry(_ d: Destination, aliases: [String] = []) -> IndexEntry {
        let name = d.kind == .folder && d.path.isEmpty ? "" : d.name
        let py = pinyin(name)
        return IndexEntry(destination: d, name: name.lowercased(), path: d.path.lowercased(),
                          pinyin: py.full, initials: py.initials, aliases: aliases.map { $0.lowercased() })
    }

    /// Folders and Markdown notes (hidden folders and Obsidian's 「排除的文件」 skipped).
    static func scan(_ vault: URL, limit: Int = 30_000) -> [IndexEntry] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: vault, includingPropertiesForKeys: [.isDirectoryKey],
                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        let root = vault.standardizedFileURL.path
        let ignored = ignoreFilters(vault)
        var out = [entry(Destination(kind: .folder, path: ""))]
        for case let url as URL in en {
            if out.count >= limit { break }
            let full = url.standardizedFileURL.path
            guard full.count > root.count + 1 else { continue }
            let rel = String(full.dropFirst(root.count + 1))
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if ignored.contains(where: { $0(rel) }) { if isDir { en.skipDescendants() }; continue }
            if isDir {
                out.append(entry(Destination(kind: .folder, path: rel)))
            } else if url.pathExtension.lowercased() == "md" {
                out.append(entry(Destination(kind: .note, path: rel), aliases: aliases(of: url)))
            }
        }
        return out
    }

    /// Obsidian's Settings → Files & links → Excluded files: path prefixes or /regex/.
    static func ignoreFilters(_ vault: URL) -> [(String) -> Bool] {
        guard let data = try? Data(contentsOf: vault.appendingPathComponent(".obsidian/app.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["userIgnoreFilters"] as? [String] else { return [] }
        return list.compactMap { f in
            if f.count > 2, f.hasPrefix("/"), f.hasSuffix("/"), let re = try? NSRegularExpression(pattern: String(f.dropFirst().dropLast())) {
                return { re.firstMatch(in: $0, range: NSRange(location: 0, length: ($0 as NSString).length)) != nil }
            }
            let prefix = f.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return prefix.isEmpty ? nil : { $0 == prefix || $0.hasPrefix(prefix + "/") }
        }
    }

    /// `aliases:` / `alias:` from YAML frontmatter (inline list, block list or single value).
    static func aliases(of url: URL) -> [String] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: 4096), let text = String(data: data, encoding: .utf8), text.hasPrefix("---") else { return [] }
        let lines = text.components(separatedBy: "\n").dropFirst()
        var out: [String] = [], inList = false
        func clean(_ s: String) -> String { s.trimmingCharacters(in: CharacterSet(charactersIn: " \"'[]")) }
        for line in lines {
            if line.hasPrefix("---") { break }
            let t = line.trimmingCharacters(in: .whitespaces)
            if inList, t.hasPrefix("- ") { out.append(clean(String(t.dropFirst(2)))); continue }
            inList = false
            guard let colon = t.firstIndex(of: ":"), ["aliases", "alias"].contains(t[..<colon].lowercased()) else { continue }
            let value = t[t.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.isEmpty { inList = true } else { out += value.split(separator: ",").map { clean(String($0)) } }
        }
        return out.filter { !$0.isEmpty }
    }

    static func pinyin(_ s: String) -> (full: String, initials: String) {
        guard s.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) else { return ("", "") }
        let m = NSMutableString(string: s)
        CFStringTransform(m, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(m, nil, kCFStringTransformStripDiacritics, false)
        let parts = (m as String).lowercased().split { !$0.isLetter && !$0.isNumber }
        return (parts.joined(), parts.compactMap { $0.first }.map(String.init).joined())
    }

    /// fzf-style subsequence match: consecutive runs and word starts score high, gaps cost a little.
    static func fuzzy(_ query: String, _ target: String) -> Int? {
        let q = Array(query), t = Array(target)
        guard !q.isEmpty, q.count <= t.count else { return nil }
        var qi = 0, score = 0, streak = 0, last = -1, first = -1
        for (i, c) in t.enumerated() where qi < q.count && c == q[qi] {
            if first < 0 { first = i }
            var s = 10
            if i == last + 1 { streak += 1; s += 6 * streak } else { streak = 0; if last >= 0 { s -= min(i - last - 1, 5) } }
            if i == 0 || " /-_.（(".contains(t[i - 1]) { s += 12 }
            score += s; last = i; qi += 1
        }
        return qi == q.count ? score - min(first, 10) : nil
    }

    private static func score(_ word: String, _ e: IndexEntry) -> Int? {
        var best: Int?
        func take(_ v: Int?) { if let v { best = max(best ?? v, v) } }
        if e.name.hasPrefix(word) { take(1000) } else if e.name.contains(word) { take(600) }
        take(fuzzy(word, e.name).map { $0 * 3 })
        for a in e.aliases {
            if a.hasPrefix(word) { take(900) }
            take(fuzzy(word, a).map { $0 * 3 })
        }
        if word.allSatisfy(\.isASCII), !e.pinyin.isEmpty {
            if e.initials.hasPrefix(word) { take(800) }
            if word.count >= 2, e.pinyin.hasPrefix(word) { take(850) } else if word.count >= 3, e.pinyin.contains(word) { take(450) }
            take(fuzzy(word, e.initials).map { $0 * 3 })
            take(fuzzy(word, e.pinyin).map { $0 * 2 })
        }
        take(fuzzy(word, e.path))
        return best
    }

    /// Pinyin input methods show composing text with syllable separators (yi'ji); drop them.
    static func normalize(_ query: String) -> String {
        query.lowercased()
            .replacingOccurrences(of: "['’‘ˈ`]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[\\s\u{2000}-\u{200B}\u{3000}]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Every query word must match (name, alias, pinyin or path); best total first, then shorter paths.
    /// Space-separated pinyin syllables ("yi ji") also count as one word ("yiji").
    static func search(_ items: [IndexEntry], _ query: String, limit: Int = 50) -> [Destination] {
        let words = normalize(query).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        let joined = words.count > 1 && words.allSatisfy { $0.allSatisfy { $0.isASCII && $0.isLetter } } ? words.joined() : nil
        let scored: [(Destination, Int)] = items.compactMap { e in
            guard !e.path.isEmpty else { return nil }
            var total: Int? = 0
            for w in words { guard let s = score(w, e) else { total = nil; break }; total! += s }
            if let joined, let s = score(joined, e) { total = max(total ?? s, s) }
            return total.map { (e.destination, $0) }
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.path.count < $1.0.path.count }.prefix(limit).map(\.0)
    }
}

/// Full-text search over note contents through Spotlight: no index of our own to build or keep fresh.
final class ContentSearch {
    private var query: NSMetadataQuery?
    private var observer: NSObjectProtocol?

    func run(_ text: String, in vault: URL, completion: @escaping ([(Destination, String)]) -> Void) {
        cancel()
        let q = NSMetadataQuery()
        q.predicate = NSPredicate(format: "kMDItemTextContent CONTAINS[cd] %@ AND kMDItemFSName ENDSWITH[c] '.md'", text)
        q.searchScopes = [vault]
        let root = vault.standardizedFileURL.path
        observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main) { [weak self] _ in
            q.stop()
            let paths = (0..<min(q.resultCount, 40)).compactMap { (q.result(at: $0) as? NSMetadataItem)?.value(forAttribute: NSMetadataItemPathKey) as? String }
            DispatchQueue.global(qos: .userInitiated).async {
                let hits: [(Destination, String)] = paths.compactMap { p in
                    let full = URL(fileURLWithPath: p).standardizedFileURL.path
                    guard full.hasPrefix(root + "/") else { return nil }
                    let rel = String(full.dropFirst(root.count + 1))
                    guard !rel.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { return nil }
                    return (Destination(kind: .note, path: rel), Self.snippet(in: URL(fileURLWithPath: p), for: text) ?? "")
                }
                DispatchQueue.main.async { completion(Array(hits.prefix(15))) }
            }
            self?.cancel()
        }
        query = q
        q.start()
    }

    func cancel() {
        query?.stop(); query = nil
        if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
    }

    /// The line around the first match, trimmed to fit a row.
    static func snippet(in url: URL, for text: String) -> String? {
        guard let s = try? String(contentsOf: url, encoding: .utf8),
              let r = s.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        let line = s[s.lineRange(for: r)].trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^([#>\-*+]|\d+\.)+\s*"#, with: "", options: .regularExpression)
        guard let lr = line.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) else { return line }
        let before = line[..<lr.lowerBound], after = line[lr.upperBound...]
        let head = before.count > 18 ? "…" + before.suffix(18) : String(before)
        let tail = after.count > 40 ? after.prefix(40) + "…" : String(after)
        return head + String(line[lr.lowerBound..<lr.upperBound]) + tail
    }
}

/// For 「同网址归并到已存笔记」: the most recently modified candidate that really contains the
/// URL, with the exact line it sits on so follow-ups can be amended right under it.
enum MergeTarget {
    static func pick(paths: [String], url: String, in vault: URL) -> (file: URL, entry: String)? {
        var best: (file: URL, entry: String, modified: Date)?
        let root = vault.standardizedFileURL.path
        for p in paths.prefix(20) where p.hasSuffix(".md") {
            let file = URL(fileURLWithPath: p.hasPrefix("/") ? p : root + "/" + p)
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let line = text.components(separatedBy: "\n").first(where: { $0.contains(url) }) else { continue }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if best == nil || modified > best!.modified { best = (file, line, modified) }
        }
        return best.map { (file: $0.file, entry: $0.entry) }
    }

    /// The page's whole section as one amend anchor: from its line down to the last line before
    /// the next `#` heading or `---` rule — so additions land below everything the page owns.
    static func sectionEnd(_ page: History.Entry) -> History.Entry {
        guard let text = try? String(contentsOf: page.note, encoding: .utf8) else { return page }
        let lines = text.components(separatedBy: "\n")
        guard let i = lines.firstIndex(of: page.entry) else { return page }
        var j = i
        while j + 1 < lines.count,
              lines[j + 1].range(of: #"^(?:#\s|---\s*$)"#, options: .regularExpression) == nil { j += 1 }
        return History.Entry(note: page.note, entry: lines[i...j].joined(separator: "\n"), files: [], indent: "")
    }
}

enum NoteNaming {
    /// Obsidian-safe file name: no path separators or link-breaking characters.
    static func sanitize(_ title: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|#^[]").union(.newlines).union(.controlCharacters)
        var s = title.components(separatedBy: bad).joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        if s.count > 80 { s = String(s.prefix(80)).trimmingCharacters(in: .whitespaces) }
        return s
    }

    /// Title for a new note: the first meaningful line of text, else a timestamp.
    static func autoTitle(from text: String, date: Date = Date()) -> String {
        for line in text.components(separatedBy: "\n") {
            let t = line.replacingOccurrences(of: #"^\s*(#{1,6}\s+|>\s*|[-*+]\s+(\[[ xX]\]\s+)?|\d+\.\s+|[-—]\s+)"#,
                                              with: "", options: .regularExpression)
                .replacingOccurrences(of: #"[*_=~`]"#, with: "", options: .regularExpression)
            let s = sanitize(t)
            if !s.isEmpty && !s.hasPrefix("!") { return s.count > 40 ? String(s.prefix(40)) : s }
        }
        return "随记 " + MomentFormat.string(date, format: "YYYY-MM-DD HHmm")
    }
}

struct RecentDestination: Codable, Equatable {
    var destination: Destination
    var date: Date
}

extension Prefs {
    private static let recentsKey = "recentDestinations.v2"

    private var allRecents: [String: [RecentDestination]] {
        UserDefaults.standard.data(forKey: Self.recentsKey)
            .flatMap { try? JSONDecoder().decode([String: [RecentDestination]].self, from: $0) } ?? [:]
    }

    /// Destinations chosen in the picker for the current vault (daily note excluded), newest first.
    var recentDestinations: [RecentDestination] { allRecents[vaultPath] ?? [] }

    func remember(_ d: Destination) {
        guard d.kind != .daily else { return }
        var all = allRecents
        var list = all[vaultPath] ?? []
        list.removeAll { $0.destination == d }
        list.insert(RecentDestination(destination: d, date: Date()), at: 0)
        all[vaultPath] = Array(list.prefix(12))
        UserDefaults.standard.set(try? JSONEncoder().encode(all), forKey: Self.recentsKey)
    }

    /// Recently used folders plus the notes captures were recently written to (any note,
    /// including ones created here), excluding daily notes, newest first.
    func recentPlaces(vault: URL, limit: Int = 8) -> [RecentDestination] {
        let root = vault.standardizedFileURL.path
        let dailyFolder = DailyNoteConfig.load(vault: vault).folder
        var out = recentDestinations
        for item in RecentCaptures.items {
            let path = URL(fileURLWithPath: item.notePath).standardizedFileURL.path
            guard path.hasPrefix(root + "/"), FileManager.default.fileExists(atPath: path) else { continue }
            let rel = String(path.dropFirst(root.count + 1))
            let folder = (rel as NSString).deletingLastPathComponent
            if !dailyFolder.isEmpty && (folder == dailyFolder || folder.hasPrefix(dailyFolder + "/")) { continue }
            let d = Destination(kind: .note, path: rel)
            if let i = out.firstIndex(where: { $0.destination == d }) {
                if out[i].date < item.date { out[i].date = item.date }
            } else {
                out.append(RecentDestination(destination: d, date: item.date))
            }
        }
        return Array(out.sorted { $0.date > $1.date }.prefix(limit))
    }

    var lastDestination: Destination {
        get {
            UserDefaults.standard.data(forKey: "lastDestination")
                .flatMap { try? JSONDecoder().decode(Destination.self, from: $0) } ?? .daily
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "lastDestination") }
    }
}
