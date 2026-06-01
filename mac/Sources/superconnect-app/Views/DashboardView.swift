import SwiftUI

/// The unified window root: a sidebar listing every discovered device + a detail pane for the
/// selected one. Binds only to `AppViewModel`; reuses StatusDot / TransportBadge / EmptyStateView.
/// Shaped for multi-device (the sidebar lists all); one active connection at a time today.
struct DashboardView: View {
    @ObservedObject var vm: AppViewModel

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
            if vm.devices.isEmpty {
                EmptyStateView()
                Spacer(minLength: 0)
            } else {
                List(vm.devices, selection: Binding(
                    get: { vm.selectedDeviceID },
                    set: { if let id = $0 { vm.select(id) } }   // routes through the mid-connection guard
                )) { device in
                    SidebarRow(device: device, state: vm.state(for: device.id))
                }
                .listStyle(.sidebar)
            }
        }
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
    let state: ConnectionState

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(state: state)
            Text(device.name).fontWeight(.medium).lineLimit(1)
            Spacer()
            TransportBadge(kind: device.transport)
        }
        .padding(.vertical, 4)
    }
}
