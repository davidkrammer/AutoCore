import SwiftUI

/// Live picture, the tabs of the Mac window, and the iPhone and account.
struct MainView: View {
    @EnvironmentObject private var client: RemoteClient
    @SceneStorage("tab") private var tab = "live"

    var body: some View {
        TabView(selection: $tab) {
            Tab("Live", systemImage: "play.rectangle.fill", value: "live") {
                NavigationStack {
                    LiveView()
                        .background(Color.black.ignoresSafeArea())
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { WindowToolbar() }
                }
            }
            Tab("Control", systemImage: "slider.horizontal.3", value: "control") {
                NavigationStack {
                    ControlTab()
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { WindowToolbar() }
                }
            }
            Tab("iPhone", systemImage: "iphone.gen3", value: "setup") {
                NavigationStack {
                    SetupView()
                        .navigationTitle("iPhone & Mac")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { WindowToolbar() }
                }
            }
        }
        .tabBarMinimizeBehavior(.never)
        .onAppear { client.wantsFrames = tab == "live" }
        .onChange(of: tab) { _, new in client.wantsFrames = new == "live" }
        .overlay(alignment: .top) { connectionBanner }
    }

    @ViewBuilder private var connectionBanner: some View {
        if case let .connecting(message) = client.phase {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(message).font(.footnote.weight(.semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: Capsule())
            .padding(.top, 50)
        }
    }

    private struct ControlTab: View {
        @EnvironmentObject private var client: RemoteClient

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ModeBar()
                    if let panel = client.state?.panel {
                        PanelView(panel: panel)
                            .id(client.state?.mode)
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
            .softEdges()
            .scrollDismissesKeyboard(.interactively)
            .background(Palette.canvas.ignoresSafeArea())
        }
    }
}

/// The Mac window's tabs; a running tool locks the others like on the Mac.
struct ModeBar: View {
    @EnvironmentObject private var client: RemoteClient

    var body: some View {
        let window = client.selectedSummary
        let current = client.state?.mode
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(window?.modes ?? []) { mode in
                    let selected = mode.id == current
                    let locked = window?.lockedMode != nil && window?.lockedMode != mode.id
                    Button {
                        Haptics.tap()
                        client.select(mode: mode.id)
                    } label: {
                        Label(mode.title, systemImage: mode.symbol ?? "circle")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .foregroundStyle(selected ? Color.white : Palette.tint(mode.tint))
                            .background(selected ? AnyShapeStyle(Palette.tint(mode.tint).gradient)
                                                 : AnyShapeStyle(Color.white.opacity(0.07)), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(locked)
                    .opacity(locked ? 0.35 : 1)
                }
            }
            .padding(.vertical, 4)
        }
        .scrollClipDisabled()
    }
}

/// Title: the window's account and link; a menu switches between windows.
struct WindowToolbar: ToolbarContent {
    @EnvironmentObject private var client: RemoteClient

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            let window = client.selectedSummary
            Menu {
                ForEach(client.state?.windows ?? []) { item in
                    Button {
                        client.select(window: item.id)
                    } label: {
                        Label(item.account.map { "\($0) · \(item.name)" } ?? item.name,
                              systemImage: item.id == window?.id ? "checkmark" : "iphone")
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    ZStack(alignment: .bottomTrailing) {
                        AccountBadge(name: window?.account, size: 26)
                        Circle()
                            .fill(Palette.link(window?.link))
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(Palette.canvas, lineWidth: 2))
                            .offset(x: 2, y: 2)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(window?.account ?? window?.name ?? RemoteBrand.macApp)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(window?.activity ?? window?.linkSummary ?? "")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if (client.state?.windows.count ?? 0) > 1 {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .disabled((client.state?.windows.count ?? 0) < 2)
        }
    }
}

/// The window's iPhone (connect or disconnect), its account, the other
/// windows, and the Mac.
struct SetupView: View {
    @EnvironmentObject private var client: RemoteClient
    @State private var forgetting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let windows = client.state?.windows, windows.count > 1 {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(text: "Windows on the Mac")
                        ForEach(windows) { window in
                            Button {
                                Haptics.tap()
                                client.select(window: window.id)
                            } label: {
                                HStack(spacing: 10) {
                                    AccountBadge(name: window.account, size: 30)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(window.account ?? window.name).font(.subheadline.weight(.semibold))
                                        Text(window.name + " · " + (window.activity ?? window.linkSummary))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: window.id == client.selectedSummary?.id ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(window.id == client.selectedSummary?.id ? Palette.accent : .secondary)
                                }
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .card()
                }
                if let setup = client.state?.setup {
                    PanelView(panel: setup)
                }
                macCard
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 30)
        }
        .softEdges()
        .background(Palette.canvas.ignoresSafeArea())
        .alert("Forget this Mac?", isPresented: $forgetting) {
            Button("Cancel", role: .cancel) {}
            Button("Forget", role: .destructive) { client.forgetMac() }
        } message: {
            Text("To connect again, allow this iPhone on the Mac once more.")
        }
    }

    private var macCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Mac")
            HStack(spacing: 10) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(client.state?.macName ?? client.saved?.name ?? "Mac").font(.subheadline.weight(.semibold))
                    Text("\(RemoteBrand.macApp) \(client.state?.appVersion ?? "") · \(client.phase == .connected ? "connected" : "connecting")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Button(role: .destructive) {
                forgetting = true
            } label: {
                Label("Forget this Mac", systemImage: "trash")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.danger)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Palette.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .card()
    }
}
