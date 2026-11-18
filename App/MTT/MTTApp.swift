import AppKit
import SwiftUI

@main
struct MTTApp: App {
    init() {
        _ = TransferManager.shared  // hooks into device removal
        DeviceManager.shared.start()
    }

    var body: some Scene {
        Window("MTT", id: "browser") {
            BrowserView()
                .frame(minWidth: 780, minHeight: 460)
        }
        .defaultSize(width: 1000, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            MenuBarContent()
        } label: {
            Image(systemName: DeviceManager.shared.devices.contains(where: \.isReady) ? "smartphone.fill" : "smartphone")
        }
    }
}

private struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    private var manager: DeviceManager { .shared }
    private var transfers: TransferManager { .shared }

    var body: some View {
        if manager.devices.isEmpty {
            Text("Chưa có điện thoại")
        }
        ForEach(manager.devices) { device in
            switch device.state {
            case .ready:
                let battery = device.info?.batteryPercent.map { " · pin \($0)%" } ?? ""
                Text(device.name + battery)
                ForEach(device.storages, id: \.id) { s in
                    Text("    \(s.description): còn trống \(Fmt.bytes(s.freeBytes))")
                }
            case .connecting:
                Text("\(device.name): đang kết nối…")
            case .failed:
                Text("\(device.name): không kết nối được")
            case .disconnected:
                Text("\(device.name): đã ngắt kết nối")
            }
        }
        if transfers.activeCount > 0 {
            Divider()
            Text("Đang chuyển \(transfers.activeCount) mục…")
        }
        Divider()
        Button("Mở trình duyệt file") {
            openWindow(id: "browser")
            NSApp.activate()
        }
        .keyboardShortcut("o")
        Divider()
        Button("Thoát MTT") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
