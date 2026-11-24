import Foundation
import SwiftUI

enum Side { case left, right }

@MainActor
final class SyncViewModel: ObservableObject {
    @Published var left: URL?
    @Published var right: URL?
    @Published var mode: SyncMode = .twoWay
    @Published var excludes: String = ""
    @Published var items: [SyncItem] = []
    @Published var compared = false
    @Published var showEqual = false
    @Published var busy: String?
    @Published var progress: Double?
    @Published var message: String?
    @Published var confirmDelete = false

    private let defaults = UserDefaults.standard
    private var accessed: [URL] = []

    init() {
        left = resolve("leftBookmark")
        right = resolve("rightBookmark")
        mode = SyncMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .twoWay
        excludes = defaults.string(forKey: "excludes") ?? ""
    }

    // MARK: settings

    /// Folders are remembered with security-scoped bookmarks so access survives app restarts.
    private func resolve(_ key: String) -> URL? {
        guard let data = defaults.data(forKey: key) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return nil }
        if url.startAccessingSecurityScopedResource() { accessed.append(url) }
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(fresh, forKey: key)
        }
        return url
    }

    func setFolder(_ side: Side, _ url: URL) {
        if url.startAccessingSecurityScopedResource() { accessed.append(url) }
        let key = side == .left ? "leftBookmark" : "rightBookmark"
        if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(data, forKey: key)
        }
        if side == .left { left = url } else { right = url }
        resetResults()
    }

    func setMode(_ m: SyncMode) {
        mode = m
        defaults.set(m.rawValue, forKey: "mode")
        resetResults()
    }

    func setExcludes(_ text: String) {
        excludes = text
        defaults.set(text, forKey: "excludes")
        resetResults()
    }

    private func resetResults() {
        items = []
        compared = false
    }

    // MARK: list interaction

    /// Normal rows: include / exclude. Conflicts: cycle  none → left-to-right → right-to-left.
    func tap(_ rel: String) {
        guard let i = items.firstIndex(where: { $0.rel == rel }) else { return }
        var item = items[i]
        if item.action == .equal { return }
        if item.conflict {
            switch item.action {
            case .conflict: item.action = .toRight
            case .toRight: item.action = .toLeft
            default: item.action = .conflict
            }
            item.enabled = item.action != .conflict
        } else {
            item.enabled.toggle()
        }
        items[i] = item
    }

    // MARK: compare

    func compare() {
        guard let l = left, let r = right else { return }
        if overlaps(l, r) {
            message = "The two folders must not be the same or nested inside each other."
            return
        }
        busy = "Scanning folders…"
        progress = nil
        resetResults()
        let mode = self.mode
        let filters = SyncEngine.parseExcludes(excludes)

        Task.detached { [weak self] in
            do {
                let result = try SyncEngine.compare(left: l, right: r, mode: mode, excludes: filters)
                await MainActor.run {
                    self?.items = result
                    self?.compared = true
                    self?.busy = nil
                }
            } catch {
                await MainActor.run {
                    self?.busy = nil
                    self?.message = "Scan failed: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: synchronise

    func requestSync() {
        if items.contains(where: { $0.enabled && $0.action.isDelete }) {
            confirmDelete = true
        } else {
            sync()
        }
    }

    func sync() {
        guard let l = left, let r = right else { return }
        confirmDelete = false
        busy = "Starting…"
        progress = 0
        let snapshot = items
        let mode = self.mode
        let filters = SyncEngine.parseExcludes(excludes)

        Task.detached { [weak self] in
            let result = SyncEngine.synchronize(left: l, right: r, items: snapshot) { done, total, name in
                Task { @MainActor in
                    self?.busy = "Syncing \(done + 1)/\(total): \(name)"
                    self?.progress = Double(done) / Double(max(total, 1))
                }
            }
            await MainActor.run {
                self?.busy = "Refreshing…"
                self?.progress = nil
            }
            let fresh = try? SyncEngine.compare(left: l, right: r, mode: mode, excludes: filters)

            var text = "\(result.copied) copied (\(formatSize(result.bytes))), \(result.deleted) deleted"
            if !result.errors.isEmpty {
                text += ", \(result.errors.count) failed:\n" + result.errors.prefix(5).joined(separator: "\n")
                if result.errors.count > 5 { text += "\n…" }
            }
            await MainActor.run {
                if let fresh = fresh {
                    self?.items = fresh
                    self?.compared = true
                }
                self?.busy = nil
                self?.message = text
            }
        }
    }

    // MARK: helpers

    private func overlaps(_ a: URL, _ b: URL) -> Bool {
        let x = a.standardizedFileURL.pathComponents
        let y = b.standardizedFileURL.pathComponents
        let n = min(x.count, y.count)
        return Array(x.prefix(n)) == Array(y.prefix(n))
    }
}

func formatSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
