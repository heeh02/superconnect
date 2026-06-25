import SwiftUI

/// The unified window root: a sidebar listing every discovered device + a detail pane for the
/// selected one. Binds only to `AppViewModel`; reuses StatusDot / TransportBadge / EmptyStateView.
/// Shaped for multi-device: several DIFFERENT tablets may be connected at once (#51); a
/// per-physical-tablet single-active rule blocks double-connecting ONE tablet (see docs/CONFLICTS.md).
struct DashboardView: View {
    @ObservedObject var vm: AppViewModel
    @State private var newWirelessIP: String = ""
    /// User dismissed the first-run sheet for this session (so it doesn't re-pop until relaunch).
    @State private var onboardingDismissed = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            if let device = vm.selectedDevice {
                DeviceDetailView(vm: vm, device: device)
            } else {
                placeholder
            }
        }
        .frame(minWidth: 780, minHeight: 480)
        .onAppear { vm.onAppear() }
        .sheet(isPresented: onboardingSheet) {
            OnboardingView(vm: vm)
        }
    }

    /// First-run gate (View-layer): show the permissions checklist while the host isn't ready AND
    /// nothing is connected, until the user dismisses it. Reads only `vm.hostReady` + per-device state.
    private var onboardingSheet: Binding<Bool> {
        Binding(
            get: {
                !onboardingDismissed
                    && !vm.hostReady
                    && !vm.devices.contains { vm.isConnected($0.id) || vm.isBusy($0.id) }
            },
            set: { presented in if !presented { onboardingDismissed = true } }
        )
    }

    @ViewBuilder private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "display").foregroundStyle(.tint)
                Text("设备").font(.headline)
                Spacer()
                StatusDot(state: aggregateState)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            Divider()
            if vm.visibleDevices.isEmpty {
                EmptyStateView()
                Spacer(minLength: 0)
            } else {
                List(vm.visibleDevices, selection: Binding(
                    get: { vm.selectedDeviceID },
                    set: { if let id = $0 { vm.select(id) } }   // select only changes the detail pane (no connection side effect, #51)
                )) { device in
                    SidebarRow(device: device, name: vm.displayName(for: device), state: vm.state(for: device.id))
                        .contextMenu {
                            if vm.isManualWireless(device.id) {
                                Button("移除此无线设备", role: .destructive) {
                                    vm.removeManualWirelessDevice(device.id)
                                }
                            }
                        }
                }
                .listStyle(.sidebar)
            }
            Divider()
            addWirelessFooter
        }
    }

    /// Footer: add a tablet by IP for wireless connect (the mDNS-blocked fallback). Accepts
    /// "192.168.1.5" or "192.168.1.5:9000"; the tablet must have 「无线模式」 turned on.
    @ViewBuilder private var addWirelessFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi").foregroundStyle(.secondary).font(.caption)
            TextField("平板 IP（无线）", text: $newWirelessIP)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submitWirelessIP() }
            Button("添加") { submitWirelessIP() }
                .disabled(newWirelessIP.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private func submitWirelessIP() {
        let text = newWirelessIP.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        vm.addManualWirelessDevice(text)
        newWirelessIP = ""
    }

    /// Sidebar header dot: connected if ANY device is connected, busy if any is connecting.
    private var aggregateState: ConnectionState {
        if vm.devices.contains(where: { vm.isConnected($0.id) }) { return .connected }
        if vm.devices.contains(where: { vm.isBusy($0.id) }) { return .connecting }
        return .idle
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "sidebar.left").font(.system(size: 42)).foregroundStyle(.secondary)
            Text("选择一台设备").font(.title3)
            Text("从左侧选择设备，查看状态并连接").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One slim sidebar row: live dot + name + wired/wireless badge.
private struct SidebarRow: View {
    let device: Device
    let name: String
    let state: ConnectionState

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(state: state, size: 11)
            Text(name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
            Spacer()
            TransportBadge(kind: device.transport, connected: state.isConnected)
        }
        .padding(.vertical, 4)
        .help(state.shortLabel)   // hover tooltip = one-word status
    }
}
