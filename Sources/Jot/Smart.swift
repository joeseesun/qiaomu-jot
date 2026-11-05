import Foundation
import AppKit
import Vision

/// On-device text recognition for pasted screenshots (Chinese + English).
enum OCR {
    static func text(in url: URL) -> String? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        // Photos with a stray word aren't worth a block.
        return text.filter { !$0.isWhitespace }.count >= 6 ? text : nil
    }

    /// Recognises every image among `urls` (off the main thread), keyed by path.
    static func recognize(_ urls: [URL], completion: @escaping ([String: String]) -> Void) {
        let images = urls.filter { MediaKind($0) == .image }
        guard !images.isEmpty else { completion([:]); return }
        DispatchQueue.global(qos: .userInitiated).async {
            var out: [String: String] = [:]
            for u in images { if let t = text(in: u) { out[u.path] = t } }
            DispatchQueue.main.async { completion(out) }
        }
    }
}

/// Fetches a page title so a pasted bare link can become [title](url).
enum LinkTitle {
    /// The first 400 KB of a page as text (UTF-8 with a GB18030 fallback), delivered raw so
    /// each caller parses on the background thread and only the result hops to main.
    private static func html(_ url: URL, timeout: TimeInterval, completion: @escaping (String?) -> Void) {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            var html: String?
            if let data, let http = resp as? HTTPURLResponse, (200..<400).contains(http.statusCode),
               (http.mimeType ?? "text/html").contains("html") {
                let head = data.prefix(400_000)
                let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
                html = String(data: head, encoding: .utf8) ?? String(data: head, encoding: gb) ?? ""
            }
            completion(html)
        }.resume()
    }

    static func fetch(_ url: URL, completion: @escaping (String?) -> Void) {
        html(url, timeout: 6) { html in
            let title = html.flatMap(parse)
            DispatchQueue.main.async { completion(title) }
        }
    }

    /// og:title first (cleaner on most sites), then <title>.
    static func parse(_ html: String) -> String? {
        let patterns = [
            #"<meta[^>]+property=["']og:title["'][^>]*content=["']([^"']+)["']"#,
            #"<meta[^>]+content=["']([^"']+)["'][^>]*property=["']og:title["']"#,
            #"<title[^>]*>([\s\S]*?)</title>"#,
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: html, range: NSRange(location: 0, length: (html as NSString).length)) else { continue }
            var t = (html as NSString).substring(with: m.range(at: 1))
            t = decodeEntities(t).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if t.count > 120 { t = String(t.prefix(120)) + "…" }
            if !t.isEmpty { return t }
        }
        return nil
    }

    static func decodeEntities(_ s: String) -> String {
        var t = s
        for (k, v) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " "] {
            t = t.replacingOccurrences(of: k, with: v)
        }
        guard let re = try? NSRegularExpression(pattern: #"&#(x?)([0-9a-fA-F]+);"#) else { return t }
        let ns = t as NSString
        var out = "", last = 0
        for m in re.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let hex = ns.substring(with: m.range(at: 1)) == "x"
            if let n = UInt32(ns.substring(with: m.range(at: 2)), radix: hex ? 16 : 10), let u = Unicode.Scalar(n) {
                out.append(Character(u))
            }
            last = NSMaxRange(m.range)
        }
        return out + ns.substring(from: last)
    }

    /// The page's own description from one request. `timeout` stays short: the description is
    /// a nice-to-have, the capture must not wait on slow servers.
    static func description(_ url: URL, timeout: TimeInterval = 3, completion: @escaping (String?) -> Void) {
        html(url, timeout: timeout) { html in
            let text = html.flatMap(parseDescription)
            DispatchQueue.main.async { completion(text) }
        }
    }

    /// og:description first (usually written for humans), then <meta name="description">.
    static func parseDescription(_ html: String) -> String? {
        let patterns = [
            #"<meta[^>]+property=["']og:description["'][^>]*content=["']([^"']+)["']"#,
            #"<meta[^>]+content=["']([^"']+)["'][^>]*property=["']og:description["']"#,
            #"<meta[^>]+name=["']description["'][^>]*content=["']([^"']+)["']"#,
            #"<meta[^>]+content=["']([^"']+)["'][^>]*name=["']description["']"#,
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: html, range: NSRange(location: 0, length: (html as NSString).length)) else { continue }
            var t = (html as NSString).substring(with: m.range(at: 1))
            t = decodeEntities(t).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if t.count > 160 { t = String(t.prefix(160)) + "…" }
            if !t.isEmpty { return t }
        }
        return nil
    }
}

/// Folder conventions: an Obsidian vault (has .obsidian) or a plain Markdown folder.
enum FolderMode {
    static func isObsidianVault(_ folder: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent(".obsidian").path, isDirectory: &isDir) && isDir.boolValue
    }

    static var obsidianInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "md.obsidian") != nil
    }

    /// Default home for captures when Obsidian isn't around.
    static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/乔木闪记", isDirectory: true)
    }

    /// `../附件/截图 1.png` (percent-encoded for standard Markdown links).
    static func relativeLink(from dir: URL, to file: URL) -> String {
        let a = dir.standardizedFileURL.pathComponents, b = file.standardizedFileURL.pathComponents
        var i = 0
        while i < min(a.count, b.count) && a[i] == b[i] { i += 1 }
        let parts = Array(repeating: "..", count: a.count - i) + b[i...]
        return parts.joined(separator: "/")
            .addingPercentEncoding(withAllowedCharacters: CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "()"))) ?? ""
    }
}
