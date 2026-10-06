import SwiftUI

// MARK: - Data

struct SnapshotEntry: Identifiable {
    let id = UUID()
    let url: URL

    // "2026-03-20_143846" → "20 Mar 2026 · 14:38"
    var displayDate: String {
        let name = url.lastPathComponent
        let parts = name.split(separator: "_")
        guard parts.count == 2 else { return name }
        let dateParts = parts[0].split(separator: "-")
        let timeParts = Array(parts[1])
        guard dateParts.count == 3, timeParts.count >= 4 else { return name }
        let months = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
        let m = Int(dateParts[1]).flatMap { $0 >= 1 && $0 <= 12 ? months[$0-1] : nil } ?? String(dateParts[1])
        let h = String(timeParts[0...1])
        let min = String(timeParts[2...3])
        return "\(dateParts[2]) \(m) \(dateParts[0]) · \(h):\(min)"
    }
}

// MARK: - View

struct SnapshotPickerView: View {
    let entries: [SnapshotEntry]
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    @State private var selectedID: UUID

    init(entries: [SnapshotEntry], onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
        self.entries = entries
        self.onPick = onPick
        self.onCancel = onCancel
        _selectedID = State(initialValue: entries.first?.id ?? UUID())
    }

    private var selectedEntry: SnapshotEntry? {
        entries.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(Color.mlInfo)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scegli uno snapshot").font(.headline)
                    Text("\(entries.count) versioni disponibili").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()

            Divider()

            // Snapshot list
            List(entries, selection: $selectedID) { entry in
                HStack {
                    Image(systemName: "archivebox")
                        .foregroundStyle(entry.id == selectedID ? Color.mlInfo : Color.secondary)
                    Text(entry.displayDate)
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                    if entry.id == entries.first?.id {
                        Text("Ultimo")
                            .font(.caption)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.mlInfo.opacity(0.15))
                            .foregroundStyle(Color.mlInfo)
                            .clipShape(Capsule())
                    }
                }
                .contentShape(Rectangle())
                .tag(entry.id)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .frame(minHeight: 160)

            Divider()

            // Footer buttons
            HStack {
                Button("Annulla") { onCancel() }
                    .keyboardShortcut(.escape)
                Spacer()
                Button("Ripristina da questo snapshot →") {
                    if let entry = selectedEntry { onPick(entry.url) }
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(selectedEntry == nil)
            }
            .padding()
        }
        .frame(width: 420, height: 320)
    }
}

// MARK: - Window wrapper

final class SnapshotPickerWindowController: NSWindowController {
    init(entries: [SnapshotEntry],
         onPick: @escaping (URL) -> Void,
         onCancel: @escaping () -> Void) {

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        win.title = "Ripristina da snapshot"
        win.isReleasedWhenClosed = false
        win.center()

        super.init(window: win)

        let view = SnapshotPickerView(entries: entries, onPick: { [weak self] url in
            self?.close()
            onPick(url)
        }, onCancel: { [weak self] in
            self?.close()
            onCancel()
        })

        win.contentView = NSHostingView(rootView: view)
    }

    required init?(coder: NSCoder) { fatalError() }
}
