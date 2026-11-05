import Foundation

/// Turns a raw selection plus its source into the Markdown block written to the daily note.
enum CaptureFormatter {
    struct Result {
        /// The captured content, as it was (web selections converted to Markdown, PDF line breaks repaired).
        var markdown: String
        var files: [URL]
        var tempDirs: [URL]
        var source: SourceInfo?
    }

    static func compose(_ g: Grabbed, _ ctx: SourceContext?) -> Result {
        var files = g.files
        var temps: [URL] = []
        for m in g.media {
            let f = DateFormatter(); f.dateFormat = "yyyyMMddHHmmss"
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let kind = ["mp4", "mov"].contains(m.ext) ? "video" : "image"
            let url = dir.appendingPathComponent("Pasted \(kind) \(f.string(from: Date())).\(m.ext)")
            if (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil,
               (try? m.data.write(to: url)) != nil { files.append(url); temps.append(dir) }
        }

        var source = ctx.map(SourceInfo.init)
        let raw = g.text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var body = ""
        if !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            switch ctx?.kind {
            case .browser, .mail, .notes:
                body = raw
                if let html = g.html {
                    let converted = HTMLToMarkdown.convert(html, base: ctx?.url)
                    // Trust the conversion only if it kept (nearly) all of the text.
                    if plainLength(converted) >= Int(Double(plainLength(raw)) * 0.8) { body = converted }
                }
                if ctx?.kind == .browser, ctx?.url?.pathExtension.lowercased() == "pdf" { body = cleanPDF(body) }
            case .pdf:
                body = cleanPDF(raw)
            case .book:
                let b = parseBookCitation(raw)
                body = b.text
                if let c = b.citation { source?.detail = c }
            case .code, .terminal:
                // Code keeps a fence: without it indentation and symbols don't survive Markdown.
                let code = dedent(raw).trimmingCharacters(in: .newlines)
                if !code.contains("\n"), code.count <= 80, ctx?.kind == .code {
                    body = "`\(code)`"
                } else {
                    let lang = ctx?.kind == .terminal ? "" : language(for: ctx?.fileName)
                    let fence = code.contains("```") ? "~~~" : "```"
                    body = "\(fence)\(lang)\n\(code)\n\(fence)"
                }
            default:
                body = raw
            }
        }
        if ctx?.kind == .finder { source = nil }      // a file from Finder needs no "source"
        return Result(markdown: body.trimmingCharacters(in: .whitespacesAndNewlines), files: files,
                      tempDirs: temps, source: source)
    }

    /// The bookmark entry used when nothing is selected in a browser.
    static func pageLink(_ ctx: SourceContext) -> String? {
        guard ctx.url != nil else { return nil }
        return SourceInfo(ctx).markdown
    }

    /// Selected text of an already-recorded page becomes an H2 section under its entry: the
    /// heading is a short outline label (40 chars) — the full text rides along as a quote.
    static func sectionHeading(from selection: String) -> String? {
        let t = selection
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        return "## " + (t.count > 40 ? String(t.prefix(40)) + "…" : t)
    }

    // MARK: Text cleanup

    static func quote(_ md: String) -> String {
        md.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? ">" : "> " + $0 }
            .joined(separator: "\n")
    }

    private static func plainLength(_ s: String) -> Int {
        s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
    }

    static func isCJK(_ c: Character?) -> Bool {
        guard let v = c?.unicodeScalars.first?.value else { return false }
        return (0x2E80...0x9FFF).contains(v) || (0xF900...0xFAFF).contains(v) || (0xFF00...0xFFEF).contains(v)
    }

    /// PDF copies break every visual line. Re-join lines into paragraphs, fix hyphenation and ligatures.
    static func cleanPDF(_ s: String) -> String {
        var text = s.replacingOccurrences(of: "\u{00AD}", with: "")
        for (lig, rep) in ["ﬁ": "fi", "ﬂ": "fl", "ﬀ": "ff", "ﬃ": "ffi", "ﬄ": "ffl"] {
            text = text.replacingOccurrences(of: lig, with: rep)
        }
        let paragraphs = text.components(separatedBy: "\n").reduce(into: [[String]]([[]])) { acc, line in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { if !(acc.last?.isEmpty ?? true) { acc.append([]) } } else { acc[acc.count - 1].append(t) }
        }.filter { !$0.isEmpty }

        var out: [String] = []
        for lines in paragraphs {
            let longest = lines.map(\.count).max() ?? 0
            var cur = ""
            for (i, line) in lines.enumerated() {
                if cur.isEmpty { cur = line; continue }
                let prev = lines[i - 1]
                let endsSentence = prev.last.map { "。！？.!?:：”\"".contains($0) } ?? false
                if endsSentence && Double(prev.count) < Double(longest) * 0.7 {   // short last line → new paragraph
                    out.append(cur); cur = line; continue
                }
                if cur.hasSuffix("-"), line.first?.isLowercase == true {
                    cur.removeLast(); cur += line
                } else if isCJK(cur.last) || isCJK(line.first) {
                    cur += line
                } else {
                    cur += " " + line
                }
            }
            if !cur.isEmpty { out.append(cur) }
        }
        return out.joined(separator: "\n\n")
    }

    /// Apple Books appends "摘录来自 / 书名 / 作者 / 此材料可能受版权保护。"; Kindle appends a citation paragraph.
    static func parseBookCitation(_ s: String) -> (text: String, citation: String?) {
        var lines = s.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        if let i = lines.lastIndex(where: { ["摘录来自", "摘錄來自", "Excerpt From", "Excerpt from"].contains($0.trimmingCharacters(in: .whitespaces)) }) {
            let rest = lines[(i + 1)...].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let title = rest.first
            let author = rest.count > 1 && !rest[1].contains("版权") && !rest[1].lowercased().contains("copyright") ? rest[1] : nil
            lines = Array(lines[..<i])
            let body = stripQuotes(lines.joined(separator: "\n"))
            let citation = title.map { "《\($0)》" + (author.map { " \($0)" } ?? "") }
            return (body, citation)
        }
        let paras = s.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n\n")
        if paras.count > 1, let last = paras.last, last.contains("Kindle") {
            return (stripQuotes(paras.dropLast().joined(separator: "\n\n")), last.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (s, nil)
    }

    private static func stripQuotes(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let f = t.first, let l = t.last, ["“", "\"", "「"].contains(f), ["”", "\"", "」"].contains(l), t.count > 2 {
            t = String(t.dropFirst().dropLast())
        }
        return t
    }

    static func dedent(_ s: String) -> String {
        let lines = s.components(separatedBy: "\n")
        let indents = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix { $0 == " " || $0 == "\t" }.count }
        guard let n = indents.min(), n > 0 else { return s }
        return lines.map { $0.count >= n ? String($0.dropFirst(n)) : $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
    }

    static func language(for fileName: String?) -> String {
        guard let ext = fileName.map({ ($0 as NSString).pathExtension.lowercased() }), !ext.isEmpty else { return "" }
        let map = ["py": "python", "js": "javascript", "mjs": "javascript", "ts": "typescript", "rs": "rust",
                   "rb": "ruby", "kt": "kotlin", "m": "objectivec", "mm": "objectivec", "cs": "csharp",
                   "sh": "bash", "zsh": "bash", "yml": "yaml", "md": "markdown", "h": "c", "hpp": "cpp", "cc": "cpp"]
        return map[ext] ?? ext
    }
}

/// Small HTML → Markdown converter for copied web selections (keeps headings, emphasis, links,
/// lists, quotes, code, images and simple tables).
enum HTMLToMarkdown {
    static func convert(_ html: String, base: URL?) -> String {
        var doc = html
        if doc.range(of: "<html", options: .caseInsensitive) == nil {
            doc = "<html><head><meta charset=\"utf-8\"></head><body>\(doc)</body></html>"
        }
        // Pass a String, not Data: Tidy's byte-level charset sniffing reads UTF-8 as Latin-1.
        guard let xml = try? XMLDocument(xmlString: doc, options: [.documentTidyHTML]),
              let root = xml.rootElement() else { return "" }
        let body = (try? root.nodes(forXPath: "//body").first) ?? root
        let r = Renderer(base: base)
        return r.tidy(r.render(body))
    }

    private struct Renderer {
        let base: URL?

        func render(_ node: XMLNode, pre: Bool = false) -> String {
            if node.kind == .text {
                let s = node.stringValue ?? ""
                return pre ? s : s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            }
            guard let el = node as? XMLElement else { return "" }
            let name = (el.name ?? "").lowercased()
            let kids = { (pre: Bool) in (el.children ?? []).map { render($0, pre: pre) }.joined() }

            switch name {
            case "script", "style", "head", "noscript", "template", "svg", "button", "iframe", "input", "select":
                return ""
            case "br": return "\n"
            case "hr": return "\n\n---\n\n"
            case "h1", "h2", "h3", "h4", "h5", "h6":
                let level = Int(String(name.last!)) ?? 1
                let t = oneLine(kids(false))
                return t.isEmpty ? "" : "\n\n" + String(repeating: "#", count: level) + " " + t + "\n\n"
            case "p", "div", "section", "article", "header", "footer", "main", "aside", "figure", "figcaption", "dl", "dd", "dt", "nav":
                return "\n\n" + kids(false) + "\n\n"
            case "strong", "b": return wrap(kids(false), "**")
            case "em", "i", "cite": return wrap(kids(false), "*")
            case "del", "s", "strike": return wrap(kids(false), "~~")
            case "mark": return wrap(kids(false), "==")
            case "code":
                if pre { return kids(true) }
                let t = oneLine(el.stringValue ?? "")
                return t.isEmpty ? "" : "`\(t)`"
            case "pre":
                let code = (el.stringValue ?? "").trimmingCharacters(in: .newlines)
                return "\n\n```\n\(code)\n```\n\n"
            case "a":
                let text = oneLine(kids(false))
                guard let href = el.attribute(forName: "href")?.stringValue, !href.hasPrefix("javascript:"),
                      !href.hasPrefix("#"), let url = URL(string: href, relativeTo: base)?.absoluteURL else { return text }
                return text.isEmpty ? "" : "[\(text)](\(url.absoluteString))"
            case "img":
                guard let src = el.attribute(forName: "src")?.stringValue, !src.hasPrefix("data:"),
                      let url = URL(string: src, relativeTo: base)?.absoluteURL else { return "" }
                let alt = el.attribute(forName: "alt")?.stringValue ?? ""
                return "![\(alt)](\(url.absoluteString))"
            case "ul", "ol":
                var n = 0
                let items: [String] = (el.children ?? []).compactMap { child in
                    guard (child as? XMLElement)?.name?.lowercased() == "li" else { return nil }
                    n += 1
                    let marker = name == "ol" ? "\(n). " : "- "
                    let content = tidy(render(child))
                    guard !content.isEmpty else { return nil }
                    let pad = String(repeating: " ", count: marker.count)
                    let lines = content.components(separatedBy: "\n")
                    return marker + lines[0] + lines.dropFirst().map { "\n" + ($0.isEmpty ? "" : pad + $0) }.joined()
                }
                return "\n\n" + items.joined(separator: "\n") + "\n\n"
            case "li":
                return kids(false)
            case "blockquote":
                let inner = tidy(kids(false))
                return "\n\n" + inner.components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n") + "\n\n"
            case "table":
                let rows = ((try? el.nodes(forXPath: ".//tr")) ?? []).compactMap { $0 as? XMLElement }
                let cells = rows.map { row in
                    (row.children ?? []).compactMap { $0 as? XMLElement }
                        .filter { ["td", "th"].contains($0.name?.lowercased() ?? "") }
                        .map { oneLine(render($0)).replacingOccurrences(of: "|", with: "\\|") }
                }.filter { !$0.isEmpty }
                guard let header = cells.first else { return "" }
                var out = ["| " + header.joined(separator: " | ") + " |",
                           "|" + Array(repeating: " --- |", count: header.count).joined()]
                out += cells.dropFirst().map { "| " + $0.joined(separator: " | ") + " |" }
                return "\n\n" + out.joined(separator: "\n") + "\n\n"
            default:
                return kids(pre)
            }
        }

        private func oneLine(_ s: String) -> String {
            s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        }

        /// `**x**` keeping surrounding spaces outside the markers.
        private func wrap(_ s: String, _ m: String) -> String {
            let core = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !core.isEmpty else { return s }
            let lead = s.hasPrefix(" ") ? " " : "", trail = s.hasSuffix(" ") ? " " : ""
            return lead + m + core + m + trail
        }

        func tidy(_ s: String) -> String {
            var lines = s.components(separatedBy: "\n").map { line -> String in
                var l = line.replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression)
                // Collapsed whitespace leaves a stray leading space; real indentation (nested lists) is ≥ 2.
                if l.hasPrefix(" ") && !l.hasPrefix("  ") { l.removeFirst() }
                return l
            }
            // Collapse runs of blank lines.
            lines = lines.enumerated().filter { i, l in !(l.isEmpty && i > 0 && lines[i - 1].isEmpty) }.map(\.1)
            return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
