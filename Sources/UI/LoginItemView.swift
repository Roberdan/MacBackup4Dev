import Cocoa
import SwiftUI
import ServiceManagement

struct LoginItemView: View {
    @ObservedObject var state: AppUIState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "power.circle.fill")
                    .font(.system(size: 30)).foregroundColor(.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Avvio al login").font(.title2.weight(.bold))
                    Text("Apri \(AppIdentity.name) quando accedi al Mac.")
                        .foregroundColor(.secondary)
                }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label(state.loginItemLabel, systemImage: statusSymbol)
                        .font(.headline).foregroundColor(statusColor)
                    statusContent
                    if let error = state.loginItemError {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Modifica non completata", systemImage: "exclamationmark.triangle.fill")
                                .font(.headline).foregroundColor(.red)
                            Text(error).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text("La pianificazione dei backup non cambia.")
                        .font(.caption).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button("Ricontrolla") { state.onRefreshLoginItem?() }
                Spacer()
                Button(state.loginItemActionTitle) { state.requestLoginItemPrimaryAction() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!state.canSetLoginItem)
            }
        }
        .padding(24)
        .frame(width: 520, height: 520)
    }

    @ViewBuilder
    private var statusContent: some View {
        switch state.loginItemStatus {
        case .notRegistered:
            Text("Premi «Attiva avvio al login»: configuriamo noi l'avvio, senza farti aggiungere l'app manualmente nelle Impostazioni.")
            Text("Se macOS richiede un consenso aggiuntivo, vedrai qui i passaggi da seguire.")
                .foregroundColor(.secondary)
        case .enabled:
            Text("Al prossimo accesso al Mac troverai \(AppIdentity.name) nella barra dei menu. Non serve riavviare adesso.")
            Text("Puoi chiudere questa finestra. La scelta è salvata da macOS.")
                .foregroundColor(.secondary)
        case .requiresApproval:
            Text("La richiesta è registrata, ma l'avvio non è ancora attivo: macOS aspetta il tuo consenso.")
            Text("1. Premi «Apri Elementi login» qui sotto.")
            Text("2. Cerca \(AppIdentity.name). Se non la vedi in «Apri al login» / «Open at Login», scorri fino alle app in background.")
            Text("3. Abilita \(AppIdentity.name), poi torna in questa finestra: mostriamo «Attivo» solo quando macOS lo conferma.")
            Text("Non serve usare «+»: la richiesta è già registrata. Se non trovi l'app, torna qui e premi «Ricontrolla».")
                .font(.caption).foregroundColor(.secondary)
            Button("Annulla richiesta di avvio") { state.onSetLoginItem?(false) }
        case .notFound:
            Text(LoginItemManager.Failure.notFound.localizedDescription)
        @unknown default:
            Text(LoginItemManager.Failure.unknownStatus.localizedDescription)
        }
    }

    private var statusSymbol: String {
        switch state.loginItemStatus {
        case .enabled: return "checkmark.circle.fill"
        case .requiresApproval: return "exclamationmark.circle.fill"
        case .notRegistered: return "power.circle"
        default: return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch state.loginItemStatus {
        case .enabled: return .green
        case .requiresApproval: return .orange
        case .notRegistered: return .secondary
        default: return .red
        }
    }
}

final class LoginItemWindowController: NSWindowController {
    init(state: AppUIState) {
        let hosting = NSHostingController(rootView: LoginItemView(state: state))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.title = "Avvio al login"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
