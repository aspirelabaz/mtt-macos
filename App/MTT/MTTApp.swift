import AppKit
import SwiftUI

@main
struct MTTApp: App {
    init() {
        Agent.bootstrap()  // may hand over to a launchd-started copy and exit
        _ = TransferManager.shared  // hooks into device removal
        DeviceManager.shared.start()
        if Agent.finderIntegrationAvailable {
            ServiceHost.shared.start()
            DomainManager.shared.start()
        }
    }

    var body: some Scene {
        Window("MTT", id: "browser") {
            BrowserView()
                .frame(minWidth: 780, minHeight: 460)
        }
        .defaultSize(width: 1000, height: 640)
        // Opened from MenuBarLabel instead, so a login launch stays in the menu bar.
        .defaultLaunchBehavior(.suppressed)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            MenuBarContent()
        } label: {
            MenuBarLabel()
        }
    }
}

/// Always alive (it's in the menu bar), so it decides whether to open the window at launch.
private struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: DeviceManager.shared.devices.contains(where: \.isReady) ? "smartphone.fill" : "smartphone")
            .task {
                if Agent.shouldOpenWindowAtLaunch() {
                    openWindow(id: "browser")
                    NSApp.activate()
                }
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
        if !Agent.finderIntegrationAvailable && !Agent.disabled {
            Divider()
            Text("Chưa hiện trong Finder: cần bật MTT trong Cài đặt > Mục đăng nhập")
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
