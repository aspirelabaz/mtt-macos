import MTPKit
import SwiftUI

struct SidebarView: View {
    let model: BrowserModel
    private var manager: DeviceManager { .shared }

    var body: some View {
        List(selection: selectionBinding) {
            ForEach(manager.devices) { device in
                Section {
                    switch device.state {
                    case .ready:
                        ForEach(device.storages, id: \.id) { storage in
                            StorageRow(storage: storage)
                                .tag(tag(device, storage))
                        }
                    case .connecting:
                        Label("Đang kết nối…", systemImage: "hourglass")
                            .foregroundStyle(.secondary)
                    case .failed:
                        HStack {
                            Label("Không kết nối được", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Thử lại") { manager.retry(device) }
                                .controlSize(.small)
                        }
                    case .disconnected:
                        Label("Đã ngắt kết nối", systemImage: "cable.connector.slash")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    DeviceHeader(device: device)
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if manager.devices.isEmpty {
                Text("Chưa có điện thoại")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func tag(_ d: ConnectedDevice, _ s: MTPStorage) -> String { "\(d.id)|\(s.id)" }

    private var selectionBinding: Binding<String?> {
        Binding {
            guard let d = model.deviceID, let s = model.storageID else { return nil }
            return "\(d)|\(s)"
        } set: { newValue in
            guard let newValue,
                  let bar = newValue.lastIndex(of: "|"),
                  let sid = UInt32(newValue[newValue.index(after: bar)...]),
                  let device = manager.device(id: String(newValue[..<bar])),
                  let storage = device.storages.first(where: { $0.id == sid }) else { return }
            model.select(device: device, storage: storage)
        }
    }
}

private struct DeviceHeader: View {
    let device: ConnectedDevice

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "smartphone")
            Text(device.name)
                .lineLimit(1)
            Spacer()
            if let b = device.info?.batteryPercent {
                Label("\(b)%", systemImage: batterySymbol(b))
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func batterySymbol(_ p: Int) -> String {
        switch p {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

private struct StorageRow: View {
    let storage: MTPStorage

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(storage.description, systemImage: "internaldrive")
                .lineLimit(1)
            let used = storage.capacity > storage.freeBytes ? storage.capacity - storage.freeBytes : 0
            ProgressView(value: storage.capacity > 0 ? Double(used) / Double(storage.capacity) : 0)
                .controlSize(.mini)
                .tint(storage.freeBytes < storage.capacity / 10 ? .orange : .accentColor)
            Text("Còn trống \(Fmt.bytes(storage.freeBytes))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
