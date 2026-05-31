import SwiftUI

/// Grid of device tiles. Tap to select; the grid is locked while connecting/connected so
/// the user can't switch device mid-session.
struct DeviceListView: View {
    @ObservedObject var vm: AppViewModel

    private let columns = [GridItem(.adaptive(minimum: 124), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(vm.devices) { device in
                DeviceCard(device: device, isSelected: device.id == vm.selectedDeviceID)
                    .onTapGesture { vm.select(device.id) }
            }
        }
        .disabled(vm.isConnected || vm.isBusy)
        .opacity(vm.isConnected || vm.isBusy ? 0.6 : 1.0)
    }
}
