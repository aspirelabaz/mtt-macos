import AppKit
import MTPKit
import SwiftUI

struct BrowserView: View {
    @State private var model = BrowserModel()
    private var manager: DeviceManager { .shared }
    private var transfers: TransferManager { .shared }

    // Dialog state
    @State private var newFolderName = ""
    @State private var showNewFolder = false
    @State private var renameTarget: RemoteItem?
    @State private var renameText = ""
    @State private var deleteTargets: [RemoteItem] = []
    @State private var showDelete = false
    @State private var alertMessage: String?
    @State private var showTransfers = false
    @State private var isDropTargeted = false

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            detail
        }
        .navigationTitle(model.device?.name ?? "MTT")
        .navigationSubtitle(model.device == nil ? "" : pathString(model.path))
        .toolbar { toolbar }
        .searchable(text: $model.search, placement: .toolbar, prompt: "Tìm trong thư mục")
        // Pick a phone when one becomes ready, or drop a vanished one.
        .task(id: manager.devices.map { "\($0.id):\($0.state)" }.joined(separator: ",")) {
            model.autoSelect()
        }
        .onChange(of: model.device?.changeCounter) { model.reload() }
        .alert("Thư mục mới", isPresented: $showNewFolder) {
            TextField("Tên thư mục", text: $newFolderName)
            Button("Tạo") { createFolder() }
            Button("Huỷ", role: .cancel) {}
        }
        .alert("Đổi tên", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Tên mới", text: $renameText)
            Button("Đổi tên") { performRename() }
            Button("Huỷ", role: .cancel) {}
        }
        .confirmationDialog(deleteTitle, isPresented: $showDelete) {
            Button("Xoá", role: .destructive) { performDelete() }
            Button("Huỷ", role: .cancel) {}
        } message: {
            Text("Không thể hoàn tác. Thư mục sẽ bị xoá cùng toàn bộ nội dung bên trong.")
        }
        .alert("Có lỗi", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if manager.devices.isEmpty {
            GuideView()
        } else if let device = model.device {
            switch device.state {
            case .ready:
                folderContent(device)
            case .connecting:
                ProgressView("Đang kết nối \(device.name)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let msg):
                ConnectFailedView(device: device, message: msg)
            case .disconnected:
                ContentUnavailableView("Đã ngắt kết nối", systemImage: "cable.connector.slash",
                                       description: Text("Cắm lại điện thoại và chọn \"Chuyển file\"."))
            }
        } else if let failed = manager.devices.first(where: { if case .failed = $0.state { true } else { false } }),
                  case .failed(let msg) = failed.state {
            ConnectFailedView(device: failed, message: msg)
        } else {
            ProgressView("Đang kết nối…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func folderContent(_ device: ConnectedDevice) -> some View {
        VStack(spacing: 0) {
            PathBar(model: model)
            Divider()
            ZStack {
                Group {
                    switch model.viewMode {
                    case .list: FileTableView(model: model, actions: actions)
                    case .grid: FileGridView(model: model, actions: actions)
                    }
                }
                // Edit > Copy / Paste (⌘C / ⌘V) while the file list has focus; the
                // search field keeps normal text copy/paste.
                .onCommand(#selector(NSText.copy(_:))) { copy(model.selectedItems) }
                .onCommand(#selector(NSText.cut(_:))) { cut(model.selectedItems) }
                .onCommand(#selector(NSText.paste(_:))) { paste(into: nil) }
                overlay(device)
            }
            .dropDestination(for: DropItem.self) { dropped, _ in
                handleDrop(dropped, onto: nil)
            } isTargeted: { isDropTargeted = $0 }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor, lineWidth: 3)
                        .padding(4)
                        .allowsHitTesting(false)
                }
            }
            Divider()
            StatusBar(model: model, device: device)
        }
    }

    @ViewBuilder
    private func overlay(_ device: ConnectedDevice) -> some View {
        if model.isLoading && model.items.isEmpty {
            VStack(spacing: 8) {
                ProgressView()
                if device.pendingOps > 1 || transfers.activeCount > 0 {
                    Text("Đang chờ lượt chuyển file hiện tại xong…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        } else if let error = model.errorMessage {
            ContentUnavailableView {
                Label("Không mở được thư mục", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Thử lại") { model.reload() }
            }
        } else if !model.isLoading && model.visibleItems.isEmpty {
            ContentUnavailableView(model.search.isEmpty ? "Thư mục trống" : "Không có kết quả",
                                   systemImage: model.search.isEmpty ? "folder" : "magnifyingglass",
                                   description: Text(model.search.isEmpty ? "Kéo file từ Finder vào đây để chép lên điện thoại." : ""))
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.goBack() } label: { Label("Quay lại", systemImage: "chevron.left") }
                .disabled(!model.canGoBack)
                .keyboardShortcut("[", modifiers: .command)
            Button { model.goForward() } label: { Label("Tiến tới", systemImage: "chevron.right") }
                .disabled(!model.canGoForward)
                .keyboardShortcut("]", modifiers: .command)
            Button { model.goUp() } label: { Label("Lên thư mục cha", systemImage: "arrow.up") }
                .disabled(!model.canGoUp)
                .keyboardShortcut(.upArrow, modifiers: .command)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Kiểu xem", selection: $model.viewMode) {
                Label("Danh sách", systemImage: "list.bullet").tag(BrowserModel.ViewMode.list)
                Label("Lưới", systemImage: "square.grid.2x2").tag(BrowserModel.ViewMode.grid)
            }
            .pickerStyle(.segmented)

            Button { askNewFolder() } label: { Label("Thư mục mới", systemImage: "folder.badge.plus") }
                .disabled(!canEdit)
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button { chooseAndUpload() } label: { Label("Chép lên điện thoại", systemImage: "square.and.arrow.up") }
                .disabled(!canEdit)
            Button { download(model.selectedItems) } label: { Label("Tải về", systemImage: "square.and.arrow.down") }
                .disabled(model.selection.isEmpty)
            Button { askDelete(model.selectedItems) } label: { Label("Xoá", systemImage: "trash") }
                .disabled(model.selection.isEmpty || !canEdit)
                .keyboardShortcut(.delete, modifiers: .command)
            Button { model.reload() } label: { Label("Làm mới", systemImage: "arrow.clockwise") }
                .keyboardShortcut("r", modifiers: .command)

            Button { showTransfers.toggle() } label: {
                Label("Chuyển file", systemImage: transfers.activeCount > 0 ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down.circle")
            }
            .badge(transfers.activeCount)
            .popover(isPresented: $showTransfers, arrowEdge: .bottom) {
                TransfersView()
            }
        }
    }

    private var canEdit: Bool {
        model.device?.isReady == true && model.storage?.isReadOnly == false
    }

    // MARK: - Actions

    private var actions: FileActions {
        FileActions(
            open: { item in
                if item.isFolder {
                    model.open(folder: item)
                } else if let device = model.device, let s = model.storageID {
                    Task { await transfers.open(item, storageID: s, from: device) }
                }
            },
            download: download,
            rename: { item in
                renameText = item.name
                renameTarget = item
            },
            delete: askDelete,
            newFolder: askNewFolder,
            refresh: { model.reload() },
            copy: copy,
            cut: cut,
            hasCut: model.activeCut != nil,
            drop: handleDrop,
            paste: paste,
            canEdit: canEdit
        )
    }

    /// A drop on a folder (or the current folder when `folder` is nil): items
    /// dragged inside MTT are moved on the phone, files from Finder are copied up.
    private func handleDrop(_ dropped: [DropItem], onto folder: RemoteItem?) -> Bool {
        guard canEdit, let device = model.device, let s = model.storageID else { return false }
        let destination = folder?.path ?? model.path
        var files: [URL] = []
        var moves: [RemoteItem] = []
        for d in dropped {
            switch d {
            case .file(let url):
                files.append(url)
            case .remote(let p):
                guard p.deviceID == device.id, p.storageID == s else {
                    alertMessage = "Chưa hỗ trợ kéo giữa hai điện thoại hoặc hai bộ nhớ khác nhau."
                    return false
                }
                // Dropping a folder onto itself, or an item where it already is: nothing to do.
                if p.item.path == destination || Array(p.item.path.dropLast()) == destination { continue }
                moves.append(p.item)
            }
        }
        if !moves.isEmpty {
            Task {
                do { try await device.move(storageID: s, items: moves, to: destination) }
                catch { alertMessage = describe(error) }
            }
        }
        if !files.isEmpty {
            showTransfers = true
            Task { try? await transfers.upload(files, storageID: s, to: destination, on: device) }
        }
        return !moves.isEmpty || !files.isEmpty
    }

    /// Marks items to be moved by the next Paste. Takes over the clipboard so a
    /// stale Finder copy isn't pasted instead; copying anything else cancels it.
    private func cut(_ items: [RemoteItem]) {
        guard canEdit, !items.isEmpty, let d = model.deviceID, let s = model.storageID else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(items.map(\.name).joined(separator: "\n"), forType: .string)
        model.cut = BrowserModel.CutState(deviceID: d, storageID: s, items: items, pasteboardChange: pb.changeCount)
    }

    private func copy(_ items: [RemoteItem]) {
        guard !items.isEmpty, let device = model.device, let s = model.storageID else { return }
        showTransfers = true
        Task { await transfers.copyToPasteboard(items, storageID: s, from: device) }
    }

    /// Uploads the clipboard's files into `folder` (or the current folder).
    private func paste(into folder: RemoteItem?) {
        // A pending Cut: move on the phone.
        if let pending = model.activeCut, canEdit, let device = model.device {
            let destination = folder?.path ?? model.path
            model.cut = nil
            Task {
                do { try await device.move(storageID: pending.storageID, items: pending.items, to: destination) }
                catch { alertMessage = describe(error) }
            }
            return
        }
        let urls = TransferManager.pasteboardFileURLs()
        guard canEdit, !urls.isEmpty, let device = model.device, let s = model.storageID else { return }
        let path = folder?.path ?? model.path
        showTransfers = true
        Task { try? await transfers.upload(urls, storageID: s, to: path, on: device) }
    }

    private var deleteTitle: String {
        deleteTargets.count == 1 ? "Xoá \"\(deleteTargets[0].name)\" khỏi điện thoại?" : "Xoá \(deleteTargets.count) mục khỏi điện thoại?"
    }

    private func download(_ items: [RemoteItem]) {
        guard !items.isEmpty, let device = model.device, let s = model.storageID else { return }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        showTransfers = true
        Task { try? await transfers.download(items, storageID: s, from: device, to: downloads) }
    }

    private func upload(_ urls: [URL]) {
        guard canEdit, !urls.isEmpty, let device = model.device, let s = model.storageID else { return }
        let path = model.path
        showTransfers = true
        Task { try? await transfers.upload(urls, storageID: s, to: path, on: device) }
    }

    private func chooseAndUpload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Chép lên"
        panel.message = "Chọn file hoặc thư mục để chép vào \(pathString(model.path))"
        if panel.runModal() == .OK { upload(panel.urls) }
    }

    private func askNewFolder() {
        newFolderName = "Thư mục mới"
        showNewFolder = true
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let device = model.device, let s = model.storageID else { return }
        let path = model.path
        Task {
            do { try await device.createFolder(storageID: s, in: path, name: name) }
            catch { alertMessage = describe(error) }
        }
    }

    private func performRename() {
        guard let item = renameTarget, let device = model.device, let s = model.storageID else { return }
        let name = renameText.trimmingCharacters(in: .whitespaces)
        renameTarget = nil
        guard !name.isEmpty, name != item.name else { return }
        Task {
            do { try await device.rename(storageID: s, item: item, to: name) }
            catch { alertMessage = describe(error) }
        }
    }

    private func askDelete(_ items: [RemoteItem]) {
        guard !items.isEmpty else { return }
        deleteTargets = items
        showDelete = true
    }

    private func performDelete() {
        guard let device = model.device, let s = model.storageID else { return }
        let items = deleteTargets
        Task {
            do { try await device.delete(storageID: s, items: items) }
            catch { alertMessage = describe(error) }
        }
    }
}

// MARK: - Pieces

private struct StatusBar: View {
    let model: BrowserModel
    let device: ConnectedDevice

    var body: some View {
        HStack(spacing: 8) {
            let n = model.visibleItems.count
            Text(model.selection.isEmpty ? "\(n) mục" : "Đã chọn \(model.selection.count) / \(n) mục")
            if model.isLoading { ProgressView().controlSize(.small) }
            Spacer()
            if let s = model.storage {
                Text("Còn trống \(Fmt.bytes(s.freeBytes)) / \(Fmt.bytes(s.capacity))")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}

struct ConnectFailedView: View {
    let device: ConnectedDevice
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Không kết nối được \(device.name)", systemImage: "exclamationmark.triangle")
        } description: {
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                if device.blockedByPTPCamera {
                    Text("Bấm nút bên dưới để tạm tắt dịch vụ đó (macOS sẽ tự bật lại khi cần) và khởi động lại MTT.")
                } else {
                    Text("• Mở khoá điện thoại và chọn \"Chuyển file\" trong thông báo USB.")
                    Text("• Tắt OpenMTP, Android File Transfer, hoặc Android Studio nếu đang mở.")
                }
            }
            .multilineTextAlignment(.leading)
        } actions: {
            VStack(spacing: 10) {
                if device.blockedByPTPCamera {
                    Button("Giải phóng khỏi Ảnh/Image Capture") {
                        DeviceManager.shared.releaseFromPTPCameraAndRestart()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Toggle("Tự động làm việc này mỗi khi cắm máy", isOn: Binding(
                        get: { PTPCameraDaemon.autoRelease },
                        set: { PTPCameraDaemon.autoRelease = $0 }))
                        .toggleStyle(.checkbox)
                }
                Button("Thử lại") { DeviceManager.shared.retry(device) }
            }
            .fixedSize()
        }
    }
}

struct GuideView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Chưa có điện thoại nào", systemImage: "smartphone")
        } description: {
            VStack(alignment: .leading, spacing: 8) {
                Text("1. Cắm điện thoại Android vào Mac bằng cáp USB.")
                Text("2. Mở khoá điện thoại.")
                Text("3. Kéo thanh thông báo xuống, chạm vào thông báo USB và chọn \"Chuyển file\".")
                Text("4. Nếu vẫn không thấy, hãy tắt OpenMTP, Android File Transfer hoặc Android Studio.")
            }
            .multilineTextAlignment(.leading)
            .padding(.top, 4)
        }
    }
}
