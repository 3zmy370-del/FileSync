import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var vm = SyncViewModel()
    @State private var showPicker = false
    @State private var pickSide: Side = .left

    private var busy: Bool { vm.busy != nil }

    private var visible: [SyncItem] {
        vm.showEqual ? vm.items : vm.items.filter { $0.action != .equal }
    }
    private var toRight: Int { vm.items.filter { $0.enabled && $0.action == .toRight }.count }
    private var toLeft: Int { vm.items.filter { $0.enabled && $0.action == .toLeft }.count }
    private var deletes: Int { vm.items.filter { $0.enabled && $0.action.isDelete }.count }
    private var conflicts: Int { vm.items.filter { $0.action == .conflict }.count }

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                FolderCard(title: "Left folder (source)", url: vm.left, disabled: busy) {
                    pickSide = .left
                    showPicker = true
                }
                FolderCard(title: "Right folder (target)", url: vm.right, disabled: busy) {
                    pickSide = .right
                    showPicker = true
                }

                Picker("Mode", selection: Binding(get: { vm.mode }, set: { vm.setMode($0) })) {
                    ForEach(SyncMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(busy)

                Text(vm.mode.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                TextField(
                    "Exclude (e.g. *.tmp, .thumbnails)",
                    text: Binding(get: { vm.excludes }, set: { vm.setExcludes($0) })
                )
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(busy)

                HStack(spacing: 10) {
                    Button { vm.compare() } label: {
                        Text("Compare").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.left == nil || vm.right == nil || busy)

                    Button { vm.requestSync() } label: {
                        Text("Synchronize").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || (toRight + toLeft + deletes) == 0)
                }

                statusArea

                List(visible) { item in
                    ItemRow(item: item) { vm.tap(item.rel) }
                }
                .listStyle(.plain)
            }
            .padding(.horizontal, 12)
            .navigationTitle("FileSync")
            .navigationBarTitleDisplayMode(.inline)
        }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                vm.setFolder(pickSide, url)
            }
        }
        .alert(
            "FileSync",
            isPresented: Binding(get: { vm.message != nil }, set: { if !$0 { vm.message = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vm.message ?? "")
        }
        .confirmationDialog(
            "\(deletes) file(s) will be permanently deleted.",
            isPresented: $vm.confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Synchronize", role: .destructive) { vm.sync() }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var statusArea: some View {
        if let text = vm.busy {
            VStack(alignment: .leading, spacing: 4) {
                Text(text).font(.footnote).lineLimit(1).truncationMode(.middle)
                if let p = vm.progress {
                    ProgressView(value: p)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
        } else if vm.compared {
            if vm.items.allSatisfy({ $0.action == .equal }) {
                Text("Both folders are in sync.").frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack {
                    Text("→ \(toRight)   ← \(toLeft)   ✕ \(deletes)   ⚠ \(conflicts)")
                        .font(.system(.footnote, design: .monospaced))
                    Spacer()
                    Toggle("Show identical", isOn: $vm.showEqual)
                        .toggleStyle(.switch)
                        .labelsHidden()
                    Text("Show identical").font(.caption)
                }
            }
        }
    }
}

// MARK: - Pieces

struct FolderCard: View {
    let title: String
    let url: URL?
    let disabled: Bool
    let onPick: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                if let url = url {
                    Text(url.lastPathComponent).lineLimit(1)
                    Text(url.deletingLastPathComponent().path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                } else {
                    Text("No folder selected")
                }
            }
            Spacer()
            Button("Select", action: onPick)
                .buttonStyle(.bordered)
                .disabled(disabled)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.4)))
    }
}

struct ItemRow: View {
    let item: SyncItem
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Text(item.action.symbol)
                    .font(.system(.title3, design: .monospaced))
                    .frame(width: 48, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.rel).lineLimit(2).foregroundStyle(.primary)
                    Text(details)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if item.action != .equal && !item.conflict {
                    Image(systemName: item.enabled ? "checkmark.square.fill" : "square")
                        .foregroundStyle(item.enabled ? Color.accentColor : Color.secondary)
                }
            }
            .opacity(item.enabled || item.action == .equal ? 1 : 0.5)
        }
        .buttonStyle(.plain)
    }

    private var details: String {
        var s = "L: \(info(item.left))\nR: \(info(item.right))"
        if item.conflict { s += "\nChanged on both sides – tap to choose direction" }
        return s
    }

    private func info(_ e: FileEntry?) -> String {
        guard let e = e else { return "—" }
        let date = Date(timeIntervalSince1970: Double(e.modified) / 1000)
        return "\(formatSize(e.size)) · \(date.formatted(date: .numeric, time: .shortened))"
    }
}

#Preview {
    ContentView()
}
