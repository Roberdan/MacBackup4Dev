import SwiftUI

// MARK: - Data Model

enum CheckState { case on, off, mixed }

struct ItemInfo: Identifiable {
    let id = UUID()
    let paths: [String]
    let label: String
    let sensitive: Bool
    let isConflict: Bool
    var primaryPath: String { paths.first ?? "" }
}

struct CategoryInfo: Identifiable {
    let id = UUID()
    let name: String
    let items: [ItemInfo]
}

// MARK: - ViewModel

@MainActor
final class TreeSelectionModel: ObservableObject {
    let mode: TreeWindowMode
    @Published var categories: [CategoryInfo]
    let hasBrewfile: Bool

    @Published var checkedPaths: Set<String>
    @Published var expandedCategories: Set<String>
    @Published var brewInstall: Bool = true
    @Published var includeRightsManagedFiles: Bool
    /// Override restore destination: maps primaryPath → custom dest (~/…)
    @Published var destinationOverrides: [String: String] = [:]

    var onConfirmBackup: (([String], Bool) -> Void)?
    var onConfirmRestore: ((URL, [String], Bool, [String: String]) -> Void)?
    var onCancel: (() -> Void)?
    var onRequestAddPath: (() -> Void)?
    var onRequestChangeDestination: ((ItemInfo, @escaping (String) -> Void) -> Void)?

    init(mode: TreeWindowMode, enabledPaths: Set<String> = [], includeRightsManagedFiles: Bool = false) {
        self.mode = mode
        self.includeRightsManagedFiles = includeRightsManagedFiles

        switch mode {
        case .backup:
            let discovered = ConfigDiscovery.discover()
            var catMap: [String: [ItemInfo]] = [:]
            var catOrder: [String] = []
            var initialChecked: Set<String> = []

            for item in discovered {
                if catMap[item.category] == nil {
                    catOrder.append(item.category)
                    catMap[item.category] = []
                }
                catMap[item.category]!.append(
                    ItemInfo(paths: item.paths, label: item.label,
                             sensitive: item.sensitive, isConflict: false)
                )
                let shouldCheck = enabledPaths.isEmpty
                    || item.paths.allSatisfy { enabledPaths.contains($0) }
                if shouldCheck { item.paths.forEach { initialChecked.insert($0) } }
            }

            categories = catOrder.map { CategoryInfo(name: $0, items: catMap[$0]!) }
            checkedPaths = initialChecked
            expandedCategories = []       // collapsed by default
            hasBrewfile = false

        case .restore(let snapshotURL):
            // Scan snapshot top-level to know what's available
            let snapshotItems = RestoreEngine.scanSnapshot(at: snapshotURL)
            let snapshotTopLevel = Set(snapshotItems.map { $0.relativePath })

            // Use candidatesForRestore: matches against snapshot WITHOUT requiring
            // files to exist on this machine (works on a fresh/different Mac)
            let discovered = ConfigDiscovery.candidatesForRestore(snapshotTopLevels: snapshotTopLevel)
            var catMap: [String: [ItemInfo]] = [:]
            var catOrder: [String] = []
            var initialChecked: Set<String> = []
            var coveredTopLevels = Set<String>()

            for item in discovered {
                for path in item.paths {
                    let rel = path.hasPrefix("~/") ? String(path.dropFirst(2)) : path
                    if let slash = rel.firstIndex(of: "/") {
                        coveredTopLevels.insert(String(rel[rel.startIndex..<slash]))
                    } else {
                        coveredTopLevels.insert(rel)
                    }
                }
                let hasConflict = item.paths.contains {
                    FileManager.default.fileExists(atPath: NSString(string: $0).expandingTildeInPath)
                }
                if catMap[item.category] == nil { catOrder.append(item.category); catMap[item.category] = [] }
                catMap[item.category]!.append(
                    ItemInfo(paths: item.paths, label: item.label,
                             sensitive: item.sensitive, isConflict: hasConflict)
                )
                item.paths.forEach { initialChecked.insert($0) }
            }

            // Repos: scan snapshot subdirs for GitHub/Developer/Projects
            let repoParents = ["GitHub", "Developer", "Projects"]
            for parentName in repoParents where snapshotTopLevel.contains(parentName) {
                coveredTopLevels.insert(parentName)
                let parentURL = snapshotURL.appendingPathComponent(parentName)
                let repos = (try? FileManager.default.contentsOfDirectory(
                    at: parentURL, includingPropertiesForKeys: [.isDirectoryKey], options: []
                )) ?? []
                for repoURL in repos.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    let name = repoURL.lastPathComponent
                    let path = "~/\(parentName)/\(name)"
                    let hasConflict = FileManager.default.fileExists(
                        atPath: NSString(string: path).expandingTildeInPath)
                    if catMap["Repos"] == nil { catOrder.append("Repos"); catMap["Repos"] = [] }
                    catMap["Repos"]!.append(
                        ItemInfo(paths: [path], label: "\(parentName)/\(name)",
                                 sensitive: false, isConflict: hasConflict)
                    )
                    initialChecked.insert(path)
                }
            }

            // Anything in snapshot not matched by known categories → "Custom"
            for snapshotItem in snapshotItems where !coveredTopLevels.contains(snapshotItem.relativePath) {
                if catMap["Custom"] == nil { catOrder.append("Custom"); catMap["Custom"] = [] }
                let path = "~/\(snapshotItem.relativePath)"
                catMap["Custom"]!.append(
                    ItemInfo(paths: [path], label: snapshotItem.relativePath,
                             sensitive: false, isConflict: snapshotItem.existsAtDest)
                )
                initialChecked.insert(path)
            }

            categories = catOrder.map { CategoryInfo(name: $0, items: catMap[$0]!) }
            checkedPaths = initialChecked
            expandedCategories = Set(catOrder)
            hasBrewfile = FileManager.default.fileExists(
                atPath: snapshotURL.appendingPathComponent("_environment/Brewfile").path
            )
        }
    }

    // MARK: - Queries

    func checkState(for category: CategoryInfo) -> CheckState {
        let all = category.items.flatMap(\.paths)
        let n = all.filter { checkedPaths.contains($0) }.count
        if n == 0 { return .off }
        if n == all.count { return .on }
        return .mixed
    }

    func isItemChecked(_ item: ItemInfo) -> Bool {
        !item.paths.isEmpty && item.paths.allSatisfy { checkedPaths.contains($0) }
    }

    func isCategoryExpanded(_ category: CategoryInfo) -> Bool {
        expandedCategories.contains(category.name)
    }

    var selectedPaths: [String] { Array(checkedPaths) }

    var selectedItemCount: Int {
        categories.flatMap(\.items).filter { isItemChecked($0) }.count
    }

    // MARK: - Mutations

    func confirmBackup() {
        onConfirmBackup?(selectedPaths, includeRightsManagedFiles)
    }

    func toggleCategory(_ category: CategoryInfo) {
        let all = category.items.flatMap(\.paths)
        if checkState(for: category) == .on { all.forEach { checkedPaths.remove($0) } }
        else                               { all.forEach { checkedPaths.insert($0) } }
    }

    func toggleItem(_ item: ItemInfo) {
        if isItemChecked(item) { item.paths.forEach { checkedPaths.remove($0) } }
        else                   { item.paths.forEach { checkedPaths.insert($0) } }
    }

    /// Returns false (and adds nothing) for a system-protected path -- OneDrive/CloudStorage
    /// included, since that toggle is config-only and this picker has no way to read it.
    @discardableResult
    func addCustomPath(_ path: String) -> Bool {
        guard !ConfigDiscovery.isForbidden(path) else { return false }
        let label = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).lastPathComponent
        let info = ItemInfo(paths: [path], label: label, sensitive: false, isConflict:
            FileManager.default.fileExists(atPath: NSString(string: path).expandingTildeInPath))
        if let idx = categories.firstIndex(where: { $0.name == "Custom" }) {
            categories[idx] = CategoryInfo(name: "Custom", items: categories[idx].items + [info])
        } else {
            categories.append(CategoryInfo(name: "Custom", items: [info]))
            expandedCategories.insert("Custom")
        }
        checkedPaths.insert(path)
        return true
    }

    func selectAll()    { categories.flatMap(\.items).flatMap(\.paths).forEach { checkedPaths.insert($0) } }
    func selectNone()   { checkedPaths.removeAll() }
    func selectNewOnly() {
        checkedPaths.removeAll()
        for item in categories.flatMap(\.items) where !item.isConflict {
            item.paths.forEach { checkedPaths.insert($0) }
        }
    }
}

// MARK: - Native tri-state checkbox via NSViewRepresentable

/// Wraps NSButton with allowsMixedState = true for proper indeterminate (dash) visual.
struct IndeterminateCheckbox: NSViewRepresentable {
    let state: CheckState
    let action: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let btn = NSButton()
        btn.setButtonType(.switch)
        btn.allowsMixedState = true
        btn.title = ""
        btn.target = context.coordinator
        btn.action = #selector(Coordinator.clicked)
        return btn
    }

    func updateNSView(_ btn: NSButton, context: Context) {
        switch state {
        case .on:    btn.state = .on
        case .off:   btn.state = .off
        case .mixed: btn.state = .mixed
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    class Coordinator: NSObject {
        let action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func clicked() { action() }
    }
}

// MARK: - Category header (DisclosureGroup label)

struct CategoryHeaderRow: View {
    let category: CategoryInfo
    @ObservedObject var model: TreeSelectionModel

    var body: some View {
        HStack(spacing: 6) {
            // Tri-state checkbox — intercepted, doesn't propagate to DisclosureGroup toggle
            IndeterminateCheckbox(state: model.checkState(for: category)) {
                model.toggleCategory(category)
            }
            .frame(width: 14, height: 14)

            Text(category.name.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.secondary)

            Text("(\(category.items.count))")
                .font(.system(size: 10))
                .foregroundColor(Color(.tertiaryLabelColor))

            Spacer()

            // Show count badge when collapsed
            if !model.isCategoryExpanded(category) {
                let n = category.items.filter { model.isItemChecked($0) }.count
                if n > 0 {
                    Text("\(n) selezionati")
                        .font(.system(size: 10))
                        .foregroundColor(.accentColor)
                }
            }
        }
        .padding(.vertical, 1)
    }
}

// MARK: - Item row

struct ItemRow: View {
    let item: ItemInfo
    @ObservedObject var model: TreeSelectionModel

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { model.isItemChecked(item) },
                set: { _ in model.toggleItem(item) }
            )) { EmptyView() }
            .toggleStyle(.checkbox)
            .labelsHidden()

            if case .restore = model.mode {
                // In restore mode: show label + destination path below
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.label)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    // Destination path — tappable to change
                    HStack(spacing: 3) {
                        let dest = model.destinationOverrides[item.primaryPath] ?? item.paths.first ?? ""
                        Text(dest.count > 42 ? "…" + String(dest.suffix(40)) : dest)
                            .font(.system(size: 10))
                            .foregroundColor(item.isConflict ? .mlRosso.opacity(0.8) : Color(.tertiaryLabelColor))
                            .lineLimit(1)
                        Button {
                            model.onRequestChangeDestination?(item) { newDest in
                                model.destinationOverrides[item.primaryPath] = newDest
                            }
                        } label: {
                            Image(systemName: "arrow.triangle.turn.up.right.circle")
                                .font(.system(size: 9))
                                .foregroundColor(.mlInfo)
                        }
                        .buttonStyle(.plain)
                        .help("Cambia destinazione")
                    }
                }
            } else {
                Text(item.label)
                    .font(.system(size: 12))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if item.sensitive {
                Text("sensitive")
                    .font(.system(size: 9))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.orange.opacity(0.5), lineWidth: 0.5))
            }

            if case .restore = model.mode {
                Text(item.isConflict ? "⚠ sovrascrive" : "✚ nuovo")
                    .font(.system(size: 9).weight(.medium))
                    .foregroundColor(item.isConflict ? .mlRosso : .mlVerde)
            } else {
                Text(shortPath(item.primaryPath))
                    .font(.system(size: 10))
                    .foregroundColor(Color(.tertiaryLabelColor))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 180, alignment: .trailing)
            }
        }
    }

    /// First destination path, shortened for display
    private var destPath: String {
        let p = item.paths.first ?? ""
        return p.count > 42 ? "…" + String(p.suffix(40)) : p
    }

    private func shortPath(_ p: String) -> String {
        p.count > 34 ? "…" + String(p.suffix(32)) : p
    }
}

// MARK: - Main Tree View

struct TreeView: View {
    @StateObject var model: TreeSelectionModel
    @State private var showOverwriteAlert = false

    var body: some View {
        VStack(spacing: 0) {
            toolbarRow
            Divider()

            List {
                ForEach(model.categories) { category in
                    DisclosureGroup(
                        isExpanded: Binding(
                            get: { model.isCategoryExpanded(category) },
                            set: { open in
                                if open { model.expandedCategories.insert(category.name) }
                                else    { model.expandedCategories.remove(category.name)  }
                            }
                        )
                    ) {
                        ForEach(category.items) { item in
                            ItemRow(item: item, model: model)
                        }
                    } label: {
                        CategoryHeaderRow(category: category, model: model)
                    }
                }
                if model.mode.isBackup {
                    Button {
                        model.onRequestAddPath?()
                    } label: {
                        Label("Aggiungi cartella o file…", systemImage: "plus.circle")
                            .font(.system(size: 12))
                            .foregroundColor(.mlInfo)
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                    .padding(.leading, 20)
                }
            }
            .listStyle(.inset)

            if model.mode.isBackup {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Includi file protetti (Rights Management)", isOn: $model.includeRightsManagedFiles)
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("includeRightsManagedFiles")
                        .accessibilityHint("Indipendente da Tutti. Può causare richieste di autorizzazione aziendale.")
                    Text("Esclude i file con protezione riconosciuta, non tutti i documenti Office. Includerli può causare richieste aziendali. Altre regole aziendali possono bloccare anche file non protetti.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("La scelta viene salvata con Avvia Backup.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }

            if model.hasBrewfile {
                Divider()
                Toggle("Reinstall Homebrew packages from Brewfile", isOn: $model.brewInstall)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }

            Divider()
            bottomBar
        }
        .frame(minWidth: 500, minHeight: 520)
        .alert("Sovrascrivere i file esistenti?", isPresented: $showOverwriteAlert) {
            Button("Sovrascrivi e Ripristina", role: .destructive) { confirmRestore() }
            Button("Annulla", role: .cancel) { }
        } message: {
            let n = model.categories.flatMap(\.items)
                .filter { model.isItemChecked($0) && $0.isConflict }.count
            Text("Hai selezionato \(n) elemento/i già presenti. Gli originali saranno salvati in ~/.rustybackup-pre-restore/")
        }
    }

    // MARK: - Toolbar

    private var toolbarRow: some View {
        HStack(spacing: 12) {
            Text(model.mode.isBackup ? "Seleziona cosa includere nel backup" : "Seleziona cosa ripristinare")
                .font(.headline)
                .foregroundColor(model.mode.isBackup ? .mlInfo : .mlVerde)
            Spacer()
            Button("Tutti")   { model.selectAll()     }.buttonStyle(.plain).font(.callout)
            Button("Nessuno") { model.selectNone()    }.buttonStyle(.plain).font(.callout)
            if !model.mode.isBackup {
                Button("Solo nuovi") { model.selectNewOnly() }.buttonStyle(.plain).font(.callout)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Text("\(model.selectedItemCount) elementi selezionati")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Button("Annulla") { model.onCancel?() }
                .keyboardShortcut(.cancelAction)
            Button(model.mode.isBackup ? "Avvia Backup" : "Ripristina Selezionati") {
                handleConfirm()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.selectedPaths.isEmpty)
            .buttonStyle(.borderedProminent)
            .tint(model.mode.isBackup ? .mlInfo : .mlVerde)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Actions

    private func handleConfirm() {
        switch model.mode {
        case .backup:
            model.confirmBackup()
        case .restore(_):
            let conflicts = model.categories.flatMap(\.items)
                .filter { model.isItemChecked($0) && $0.isConflict }
            if conflicts.isEmpty { confirmRestore() }
            else { showOverwriteAlert = true }
        }
    }

    private func confirmRestore() {
        guard case .restore(let url) = model.mode else { return }
        // RestoreEngine expects relative paths WITHOUT "~/" prefix
        let items = model.categories.flatMap(\.items)
            .filter { model.isItemChecked($0) }.flatMap(\.paths)
            .map { $0.hasPrefix("~/") ? String($0.dropFirst(2)) : $0 }
        // Build destination overrides (also strip ~/)
        var overrides: [String: String] = [:]
        for (key, val) in model.destinationOverrides {
            let relKey = key.hasPrefix("~/") ? String(key.dropFirst(2)) : key
            overrides[relKey] = val
        }
        model.onConfirmRestore?(url, items, model.brewInstall, overrides)
    }
}


/// Flat data model for an item in the tree.
