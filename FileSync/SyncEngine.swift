import Foundation

// MARK: - Model

enum SyncMode: String, CaseIterable, Identifiable {
    case twoWay, mirror, update

    var id: String { rawValue }

    var label: String {
        switch self {
        case .twoWay: return "Two-way ↔"
        case .mirror: return "Mirror →"
        case .update: return "Update →"
        }
    }

    var detail: String {
        switch self {
        case .twoWay:
            return "Newer file wins on both sides. Deletions are carried over for files that were synced before."
        case .mirror:
            return "Make the right folder identical to the left one. Extra files on the right are deleted."
        case .update:
            return "Copy new and changed files from left to right. Nothing is ever deleted."
        }
    }
}

enum SyncAction {
    case equal, toRight, toLeft, deleteLeft, deleteRight, conflict, skip

    var symbol: String {
        switch self {
        case .equal: return "="
        case .toRight: return "→"
        case .toLeft: return "←"
        case .deleteLeft: return "✕ L"
        case .deleteRight: return "R ✕"
        case .conflict: return "⚠"
        case .skip: return "·"
        }
    }

    var active: Bool {
        switch self {
        case .toRight, .toLeft, .deleteLeft, .deleteRight: return true
        default: return false
        }
    }

    var isDelete: Bool { self == .deleteLeft || self == .deleteRight }
}

struct FileEntry {
    let rel: String
    let url: URL
    let size: Int64
    let modified: Int64   // milliseconds since 1970
}

struct SyncItem: Identifiable {
    var id: String { rel }
    let rel: String
    let left: FileEntry?
    let right: FileEntry?
    var action: SyncAction
    var enabled: Bool
    let conflict: Bool
}

struct SyncResult {
    var copied = 0
    var deleted = 0
    var bytes: Int64 = 0
    var errors: [String] = []
}

/// What both sides looked like right after the last successful sync of a file.
struct Rec: Codable {
    var size: Int64
    var left: Int64
    var right: Int64
}

final class Records {
    private let fileURL: URL
    private var map: [String: Rec] = [:]

    init(left: URL, right: URL) {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let key = Records.stableHash(left.standardizedFileURL.path + "|" + right.standardizedFileURL.path)
        fileURL = dir.appendingPathComponent("rec_\(key).json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Rec].self, from: data) {
            map = decoded
        }
    }

    subscript(rel: String) -> Rec? {
        get { map[rel] }
        set { map[rel] = newValue }
    }

    func save() {
        if let data = try? JSONEncoder().encode(map) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // Swift's hashValue changes on every launch, so use a fixed FNV-1a hash.
    private static func stableHash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return String(h, radix: 16)
    }
}

// MARK: - Engine

enum SyncEngine {
    // Some file systems only keep 2 s precision.
    private static let tolerance: Int64 = 2000

    // MARK: scanning

    static func scan(root: URL) throws -> [String: FileEntry] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let base = root.standardizedFileURL
        let baseCount = base.pathComponents.count
        var out: [String: FileEntry] = [:]

        guard let walker = fm.enumerator(
            at: base,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else { return out }

        for case let url as URL in walker {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let comps = url.standardizedFileURL.pathComponents
            guard comps.count > baseCount else { continue }
            let rel = comps.dropFirst(baseCount).joined(separator: "/")
            let date = v.contentModificationDate ?? Date(timeIntervalSince1970: 0)
            out[rel] = FileEntry(
                rel: rel,
                url: url,
                size: Int64(v.fileSize ?? 0),
                modified: Int64((date.timeIntervalSince1970 * 1000).rounded())
            )
        }
        return out
    }

    // MARK: filter

    /// Comma / semicolon / newline separated globs; `*` and `?` are supported.
    static func parseExcludes(_ text: String) -> [NSRegularExpression] {
        text.split(whereSeparator: { ",;\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap { glob in
                var pattern = "^"
                for ch in glob {
                    switch ch {
                    case "*": pattern += ".*"
                    case "?": pattern += "."
                    default: pattern += NSRegularExpression.escapedPattern(for: String(ch))
                    }
                }
                pattern += "$"
                return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            }
    }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, options: [], range: NSRange(s.startIndex..., in: s)) != nil
    }

    private static func isExcluded(_ rel: String, _ excludes: [NSRegularExpression]) -> Bool {
        excludes.contains { re in
            matches(re, rel) || rel.split(separator: "/").contains { matches(re, String($0)) }
        }
    }

    // MARK: comparison

    static func compare(left: URL, right: URL, mode: SyncMode, excludes: [NSRegularExpression]) throws -> [SyncItem] {
        let l = try scan(root: left)
        let r = try scan(root: right)
        let records = Records(left: left, right: right)
        var items: [SyncItem] = []
        for rel in Set(l.keys).union(r.keys).sorted() {
            if isExcluded(rel, excludes) { continue }
            let action = decide(l[rel], r[rel], records[rel], mode)
            items.append(SyncItem(
                rel: rel,
                left: l[rel],
                right: r[rel],
                action: action,
                enabled: action.active,
                conflict: action == .conflict
            ))
        }
        return items
    }

    private static func decide(_ a: FileEntry?, _ b: FileEntry?, _ rc: Rec?, _ mode: SyncMode) -> SyncAction {
        if let a = a, let b = b {
            let sameByRecord = rc.map { $0.size == a.size && $0.left == a.modified && $0.right == b.modified } ?? false
            let same = a.size == b.size && (abs(a.modified - b.modified) <= tolerance || sameByRecord)
            if same { return .equal }
            switch mode {
            case .mirror:
                return .toRight
            case .update:
                return a.modified > b.modified ? .toRight : .skip
            case .twoWay:
                guard let rc = rc else { return a.modified >= b.modified ? .toRight : .toLeft }
                let leftChanged = a.size != rc.size || a.modified != rc.left
                let rightChanged = b.size != rc.size || b.modified != rc.right
                if leftChanged && rightChanged { return .conflict }
                if leftChanged { return .toRight }
                if rightChanged { return .toLeft }
                return .equal
            }
        }
        if let a = a { // only on the left
            if mode == .twoWay, let rc = rc, a.size == rc.size, a.modified == rc.left {
                return .deleteLeft // synced before, right side deleted it, left unchanged
            }
            return .toRight
        }
        if let b = b { // only on the right
            switch mode {
            case .mirror: return .deleteRight
            case .update: return .skip
            case .twoWay:
                if let rc = rc, b.size == rc.size, b.modified == rc.right { return .deleteRight }
                return .toLeft
            }
        }
        return .equal
    }

    // MARK: synchronisation

    static func synchronize(
        left: URL,
        right: URL,
        items: [SyncItem],
        onProgress: (_ done: Int, _ total: Int, _ name: String) -> Void
    ) -> SyncResult {
        var result = SyncResult()
        let records = Records(left: left, right: right)

        // copies first, deletions last
        let active = items.filter { $0.enabled && $0.action.active }
        let todo = active.filter { !$0.action.isDelete } + active.filter { $0.action.isDelete }

        for (i, item) in todo.enumerated() {
            onProgress(i, todo.count, item.rel)
            do {
                switch item.action {
                case .toRight:
                    guard let src = item.left else { continue }
                    let (size, mod) = try copy(src, toRoot: right, rel: item.rel)
                    records[item.rel] = Rec(size: size, left: src.modified, right: mod)
                    result.copied += 1
                    result.bytes += size
                case .toLeft:
                    guard let src = item.right else { continue }
                    let (size, mod) = try copy(src, toRoot: left, rel: item.rel)
                    records[item.rel] = Rec(size: size, left: mod, right: src.modified)
                    result.copied += 1
                    result.bytes += size
                case .deleteLeft:
                    if let f = item.left { try coordinatedDelete(f.url) }
                    records[item.rel] = nil
                    result.deleted += 1
                case .deleteRight:
                    if let f = item.right { try coordinatedDelete(f.url) }
                    records[item.rel] = nil
                    result.deleted += 1
                default:
                    break
                }
            } catch {
                result.errors.append("\(item.rel): \(error.localizedDescription)")
            }
        }

        // remember identical pairs too, so later deletions can be detected
        for item in items where item.action == .equal {
            if let a = item.left, let b = item.right {
                records[item.rel] = Rec(size: a.size, left: a.modified, right: b.modified)
            }
        }
        records.save()
        return result
    }

    // MARK: file operations

    private static func copy(_ src: FileEntry, toRoot: URL, rel: String) throws -> (Int64, Int64) {
        let fm = FileManager.default
        let dst = toRoot.standardizedFileURL.appendingPathComponent(rel)
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        let srcDate = Date(timeIntervalSince1970: Double(src.modified) / 1000)
        try coordinatedCopy(from: src.url, to: dst, modified: srcDate)

        let v = try dst.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let mod = Int64(((v.contentModificationDate ?? srcDate).timeIntervalSince1970 * 1000).rounded())
        return (Int64(v.fileSize ?? Int(src.size)), mod)
    }

    /// Coordinated so files that live in iCloud Drive are downloaded first.
    /// Existing files are replaced atomically (copy to a temp file, then swap).
    private static func coordinatedCopy(from src: URL, to dst: URL, modified: Date) throws {
        var coordinationError: NSError?
        var innerError: Error?
        NSFileCoordinator().coordinate(
            readingItemAt: src, options: [],
            writingItemAt: dst, options: .forReplacing,
            error: &coordinationError
        ) { readURL, writeURL in
            let fm = FileManager.default
            do {
                if fm.fileExists(atPath: writeURL.path) {
                    let tmp = writeURL.deletingLastPathComponent()
                        .appendingPathComponent(".filesync-\(UUID().uuidString).tmp")
                    try fm.copyItem(at: readURL, to: tmp)
                    try fm.setAttributes([.modificationDate: modified], ofItemAtPath: tmp.path)
                    _ = try fm.replaceItemAt(writeURL, withItemAt: tmp)
                } else {
                    try fm.copyItem(at: readURL, to: writeURL)
                    try fm.setAttributes([.modificationDate: modified], ofItemAtPath: writeURL.path)
                }
            } catch {
                innerError = error
            }
        }
        if let e = (coordinationError as Error?) ?? innerError { throw e }
    }

    private static func coordinatedDelete(_ url: URL) throws {
        var coordinationError: NSError?
        var innerError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { u in
            do { try FileManager.default.removeItem(at: u) } catch { innerError = error }
        }
        if let e = (coordinationError as Error?) ?? innerError { throw e }
    }
}
