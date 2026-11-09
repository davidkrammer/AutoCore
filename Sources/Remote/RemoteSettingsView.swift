import SwiftUI

/// The Remote on the Mac: on or off, and the iPhones allowed to control it.
struct RemoteSettingsView: View {
    @ObservedObject private var server = RemoteServer.shared
    @Environment(\.dismiss) private var dismiss
    @State private var removing: PairedRemote?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(AppBrand.current.name) Remote").font(.title3.weight(.bold))
                    Text("See and control \(AppBrand.current.name) from your iPhone: the live picture, every tab and its settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Toggle(isOn: $server.isEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Allow \(AppBrand.current.name) Remote on this Wi-Fi")
                    Text(server.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .card(cornerRadius: 12)

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(title: "Allowed iPhones")
                if server.remotes.isEmpty {
                    Text("None yet. Open \(AppBrand.current.name) Remote on your iPhone, choose this Mac and allow it here when both show the same code.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(server.remotes) { remote in
                    HStack(spacing: 10) {
                        Image(systemName: "iphone")
                            .foregroundStyle(server.connected.contains(remote.id) ? Palette.success : .secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(remote.name).font(.callout.weight(.semibold))
                            Text(detail(remote))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            removing = remote
                        } label: {
                            Label("Remove", systemImage: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                    }
                    .padding(.vertical, 3)
                }
            }
            .card(cornerRadius: 12)

            Text("Only the Mac and the iPhones you allowed can read what is sent; everything is encrypted. For now it works on the same Wi-Fi as this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 400)
        .alert("Remove this iPhone?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
               presenting: removing) { remote in
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { server.forget(remote) }
        } message: { remote in
            Text(String(format: NSLocalizedString("%@ can no longer control %@ until you allow it again.", comment: "Remote remove"),
                        remote.name, AppBrand.current.name))
        }
    }

    private func detail(_ remote: PairedRemote) -> String {
        if server.connected.contains(remote.id) { return NSLocalizedString("Connected now", comment: "Remote") }
        if let seen = remote.lastSeen {
            return String(format: NSLocalizedString("Last connected %@", comment: "Remote"), AppFormat.relative(seen))
        }
        return remote.model
    }
}

/// The question when an iPhone wants to pair, in the first window.
struct RemotePairingAlert: ViewModifier {
    @ObservedObject private var server = RemoteServer.shared
    let isFirstWindow: Bool

    func body(content: Content) -> some View {
        content.alert(
            Text(String(format: NSLocalizedString("Allow “%@” to control %@?", comment: "Remote pairing"),
                        server.pairingRequest?.name ?? "", AppBrand.current.name)),
            isPresented: Binding(get: { isFirstWindow && server.pairingRequest != nil },
                                 set: { if !$0, server.pairingRequest != nil { server.declinePairing() } }),
            presenting: server.pairingRequest
        ) { _ in
            Button("Don't Allow", role: .cancel) { server.declinePairing() }
            Button("Allow") { server.approvePairing() }
        } message: { request in
            Text(String(format: NSLocalizedString("Code %@. Allow it only if your iPhone shows the same code. It can then see the iPhones in %@ and control them.", comment: "Remote pairing"),
                        request.code, AppBrand.current.name))
        }
    }
}
