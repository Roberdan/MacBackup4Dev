import Cocoa
import SwiftUI

/// "Cifra i backup" (4.1): creates the encrypted store on the backup disk, shows the recovery
/// key once (the user must confirm it is saved), offers to add the credentials now that they
/// are protected, then hands the new config back. Old unencrypted snapshots are not touched.
final class EncryptionSetupModel: ObservableObject {
    enum Step { case intro, working, failed }
    @Published var step: Step = .intro
    @Published var password = ""
    @Published var confirm = ""
    @Published var error = ""
    @Published var credentials: [DevItem] = []
    @Published var chosenCredentials: Set<String> = []

    let disk: URL
    /// (new config) — called once the encrypted store exists and is open.
    var onDone: ((Config) -> Void)?
    var baseConfig: () -> Config?

    init(disk: URL, baseConfig: @escaping () -> Config?) {
        self.disk = disk
        self.baseConfig = baseConfig
        DispatchQueue.global(qos: .userInitiated).async {
            let creds = DevEnvironment.scan().allItems.filter(\.sensitive)
            DispatchQueue.main.async { self.credentials = creds; self.chosenCredentials = Set(creds.map(\.id)) }
        }
    }

    var problem: String? { EncryptedStore.passwordProblem(password, confirm: confirm) }

    func create() {
        guard problem == nil else { return }
        step = .working
        let disk = self.disk, password = self.password
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let setup = try EncryptedStore.createStore(on: disk, password: password)
                DispatchQueue.main.async { self.finish(setup) }
            } catch {
                DispatchQueue.main.async { self.error = error.localizedDescription; self.step = .failed }
            }
        }
    }

    private func finish(_ setup: EncryptedStore.Setup) {
        password = ""; confirm = ""
        guard var config = baseConfig() else { return }
        config.encryption = EncryptionConfig(container: setup.container, volume: setup.volume)
        config.destination.path = setup.destination
        let extra = credentials.filter { chosenCredentials.contains($0.id) }.flatMap(\.paths)
        config.source.paths = ConfigDiscovery.pruneRedundant(Array(Set(config.source.paths + extra)).sorted())
        onDone?(config)
    }
}

struct EncryptionSetupView: View {
    @ObservedObject var model: EncryptionSetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill").font(.system(size: 28)).foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Backup cifrati").font(.title2.weight(.bold))
                    Text("Protetti dall'app, qualunque disco tu usi.").foregroundColor(.secondary)
                }
            }
            Divider()
            switch model.step {
            case .intro: intro
            case .working:
                HStack { ProgressView().controlSize(.small); Text("Creo il backup cifrato su \(model.disk.lastPathComponent)…") }
                Spacer()
            case .failed:
                Label(model.error, systemImage: "xmark.octagon").foregroundColor(.red)
                Spacer()
                HStack { Spacer(); Button("Indietro") { model.step = .intro } }
            }
        }
        .padding(24)
        .frame(width: 620, height: 600)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            bullet("lock.fill", "I nuovi backup vanno in un contenitore cifrato (AES-256) su \(model.disk.lastPathComponent): senza la password nessuno li legge, anche se il disco non è cifrato.")
            bullet("key.fill", "La password la scegli tu e resta nel Portachiavi di questo Mac. Su un Mac nuovo te la chiedo: senza, i backup non si aprono.")
            bullet("clock.arrow.circlepath", "Il primo backup cifrato è completo (circa 40 minuti). I backup vecchi restano dove sono: li cancelli tu quando vuoi.")
            SecureField("Password (almeno \(EncryptedStore.minimumPasswordLength) caratteri, anche una frase)", text: $model.password)
                .textFieldStyle(.roundedBorder).padding(.top, 6)
            SecureField("Ripeti la password", text: $model.confirm).textFieldStyle(.roundedBorder)
            if let problem = model.problem, !model.password.isEmpty {
                Text(problem).font(.caption).foregroundColor(.orange)
            }
            if !model.credentials.isEmpty {
                Text("Salva anche le credenziali (ora sono protette)").font(.headline).padding(.top, 6)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.credentials) { item in
                            Toggle(isOn: Binding(get: { model.chosenCredentials.contains(item.id) },
                                                 set: { on in if on { model.chosenCredentials.insert(item.id) } else { model.chosenCredentials.remove(item.id) } })) {
                                HStack { Text(item.name); Spacer(); Text(item.paths.joined(separator: ", ")).font(.caption).foregroundColor(.secondary) }
                            }
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
            Spacer()
            HStack {
                Spacer()
                Button("Cifra e inizia il backup") { model.create() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(model.problem != nil)
            }
        }
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundColor(.accentColor).frame(width: 20)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

final class EncryptionSetupWindowController: NSWindowController {
    init(model: EncryptionSetupModel) {
        let window = NSWindow(contentViewController: NSHostingController(rootView: EncryptionSetupView(model: model)))
        window.styleMask = [.titled, .closable]
        window.title = "Backup cifrati"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
