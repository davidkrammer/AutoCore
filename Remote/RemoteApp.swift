import SwiftUI

@main
struct RemoteApp: App {
    @StateObject private var client = RemoteClient()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(client)
                .preferredColorScheme(.dark)
                .tint(Palette.accent)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    // Connected only while open: iOS stops background sockets anyway.
                    if phase == .active { client.becameActive() } else if phase == .background { client.becameInactive() }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var client: RemoteClient

    var body: some View {
        Group {
            if client.state != nil, client.saved != nil {
                MainView()
            } else {
                ConnectView()
            }
        }
        .background(Palette.canvas.ignoresSafeArea())
        .overlay(alignment: .top) { ToastView() }
    }
}

/// Short answers from the Mac ("Stop automation before manual control").
struct ToastView: View {
    @EnvironmentObject private var client: RemoteClient

    var body: some View {
        if let toast = client.toast {
            Label(toast.text, systemImage: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(toast.isError ? Palette.warning : Palette.success)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: Capsule())
                .padding(.top, 52)
                .padding(.horizontal, 20)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: toast.id) {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    withAnimation { client.toast = nil }
                }
                .onTapGesture { withAnimation { client.toast = nil } }
        }
    }
}

// MARK: - Finding and pairing the Mac

struct ConnectView: View {
    @EnvironmentObject private var client: RemoteClient

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    hero
                    switch client.phase {
                    case let .pairing(code, mac):
                        pairing(code: code, mac: mac)
                    case let .connecting(message):
                        VStack(spacing: 10) {
                            ProgressView()
                            Text(message).foregroundStyle(.secondary)
                        }
                        .padding(.top, 20)
                    default:
                        if case let .failed(message) = client.phase {
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .font(.subheadline)
                                .foregroundStyle(Palette.warning)
                                .card(tint: Palette.warning)
                        }
                        macList
                    }
                }
                .padding(20)
            }
            .softEdges()
            .background(Palette.canvas.ignoresSafeArea())
            .toolbar {
                if case .failed = client.phase {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Retry", systemImage: "arrow.clockwise") { client.retry() }
                    }
                }
            }
        }
    }

    private var hero: some View {
        VStack(spacing: 10) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Palette.primaryGradient)
                .padding(.top, 30)
            Text(RemoteBrand.appName)
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text("Watch and control \(RemoteBrand.macApp) on your Mac: the live picture of the iPhone it controls, every tab and its settings.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var macList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(text: "Macs on this Wi-Fi")
                Spacer()
                ProgressView().controlSize(.small)
            }
            if client.macs.isEmpty {
                Text("Looking for \(RemoteBrand.macApp)… Open \(RemoteBrand.macApp) on the Mac; this iPhone has to be on the same Wi-Fi. Allow Local Network access if iOS asks.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(client.macs) { mac in
                Button {
                    Haptics.tap()
                    client.connect(to: mac)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "laptopcomputer")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(Palette.accent)
                            .frame(width: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mac.name).font(.headline)
                            Text(mac.macID == client.saved?.macID ? "Allowed" : "Tap to connect")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .card()
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func pairing(code: String, mac: String) -> some View {
        VStack(spacing: 16) {
            Text("Allow this iPhone on the Mac")
                .font(.headline)
            Text(code.prefix(3) + " " + code.suffix(3))
                .font(.system(size: 52, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .tracking(4)
                .foregroundStyle(Palette.primaryGradient)
            Text("“\(mac)” asks whether to allow this iPhone. Click Allow there if it shows the same code.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            ProgressView()
            Button("Cancel", role: .cancel) { client.cancelPairing() }
                .buttonStyle(.glass)
        }
        .card(padding: 22)
    }
}
