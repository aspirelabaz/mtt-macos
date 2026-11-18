import AppKit
import MTPKit
import SwiftUI

/// Actions the file views can trigger; implemented by BrowserView.
struct FileActions {
    var open: (RemoteItem) -> Void
    var download: ([RemoteItem]) -> Void
    var rename: (RemoteItem) -> Void
    var delete: ([RemoteItem]) -> Void
    var newFolder: () -> Void
    var refresh: () -> Void
    var copy: ([RemoteItem]) -> Void
    var cut: ([RemoteItem]) -> Void
    var hasCut: Bool
    /// Handles a drop onto a folder (nil = the current folder). Returns false if nothing was done.
    var drop: ([DropItem], RemoteItem?) -> Bool
    /// Pastes clipboard files into the given folder (nil = current folder).
    var paste: (RemoteItem?) -> Void
    var canEdit: Bool
}

// MARK: - Context menu (shared by list and grid)

struct ItemContextMenu: View {
    let items: [RemoteItem]
    let actions: FileActions

    var body: some View {
        let canPaste = actions.canEdit && (actions.hasCut || TransferManager.canPaste)
        if items.isEmpty {
            Button("Dán") { actions.paste(nil) }
                .disabled(!canPaste)
            Divider()
            Button("Thư mục mới…", action: actions.newFolder)
                .disabled(!actions.canEdit)
            Button("Làm mới", action: actions.refresh)
        } else {
            if items.count == 1 {
                Button(items[0].isFolder ? "Mở" : "Mở bằng app mặc định") { actions.open(items[0]) }
                Divider()
            }
            Button("Cắt") { actions.cut(items) }
                .disabled(!actions.canEdit)
            Button("Sao chép") { actions.copy(items) }
            if items.count == 1, items[0].isFolder {
                Button("Dán vào \"\(items[0].name)\"") { actions.paste(items[0]) }
                    .disabled(!canPaste)
            } else {
                Button("Dán") { actions.paste(nil) }
                    .disabled(!canPaste)
            }
            Divider()
            Button("Tải về thư mục Downloads") { actions.download(items) }
            if items.count == 1 {
                Button("Đổi tên…") { actions.rename(items[0]) }
                    .disabled(!actions.canEdit)
            }
            Divider()
            Button("Xoá…", role: .destructive) { actions.delete(items) }
                .disabled(!actions.canEdit)
        }
    }
}

// MARK: - List view

struct FileTableView: View {
    @Bindable var model: BrowserModel
    let actions: FileActions

    var body: some View {
        let storageID = model.storageID ?? 0
        let deviceID = model.deviceID ?? ""
        Table(of: RemoteItem.self, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Tên", value: \.name, comparator: .localizedStandard) { item in
                HStack(spacing: 6) {
                    Image(nsImage: systemIcon(for: item))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .opacity(model.isCut(item) ? 0.45 : 1)
            }
            .width(min: 180, ideal: 320)

            TableColumn("Ngày sửa", value: \.modified) { item in
                Text(item.entry.modified.map { Fmt.date.string(from: $0) } ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 160)

            TableColumn("Kích thước", value: \.size) { item in
                Text(item.isFolder ? "—" : Fmt.bytes(item.size))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 70, ideal: 90)

            TableColumn("Loại") { item in
                Text(item.kindDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 70, ideal: 120)
        } rows: {
            ForEach(model.visibleItems) { item in
                if item.isFolder {
                    // Folders accept drops: MTT items move here, Finder files are copied here.
                    TableRow(item)
                        .draggable(DragPayload(item: item, storageID: storageID, deviceID: deviceID))
                        .dropDestination(for: DropItem.self) { dropped in
                            _ = actions.drop(dropped, item)
                        }
                } else {
                    TableRow(item)
                        .draggable(DragPayload(item: item, storageID: storageID, deviceID: deviceID))
                }
            }
        }
        .contextMenu(forSelectionType: RemoteItem.ID.self) { ids in
            ItemContextMenu(items: model.items.filter { ids.contains($0.id) }, actions: actions)
        } primaryAction: { ids in
            if ids.count == 1, let item = model.items.first(where: { ids.contains($0.id) }) {
                actions.open(item)
            }
        }
    }
}

// MARK: - Grid view

struct FileGridView: View {
    @Bindable var model: BrowserModel
    let actions: FileActions

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 116, maximum: 150), spacing: 12)], spacing: 14) {
                ForEach(model.visibleItems) { item in
                    GridCell(item: item, model: model, isSelected: model.selection.contains(item.id),
                             actions: actions)
                        .opacity(model.isCut(item) ? 0.45 : 1)
                        .onTapGesture(count: 2) { actions.open(item) }
                        .simultaneousGesture(TapGesture().onEnded { select(item) })
                        .contextMenu {
                            let items = model.selection.contains(item.id) ? model.selectedItems : [item]
                            ItemContextMenu(items: items, actions: actions)
                        }
                        .draggable(DragPayload(item: item, storageID: model.storageID ?? 0, deviceID: model.deviceID ?? ""))
                }
            }
            .padding(14)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selection.removeAll() }
        .contextMenu { ItemContextMenu(items: [], actions: actions) }
    }

    private func select(_ item: RemoteItem) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if model.selection.contains(item.id) { model.selection.remove(item.id) } else { model.selection.insert(item.id) }
        } else {
            model.selection = [item.id]
        }
    }
}

private struct GridCell: View {
    let item: RemoteItem
    let model: BrowserModel
    let isSelected: Bool
    let actions: FileActions
    @State private var thumbnail: NSImage?
    @State private var isDropTarget = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(nsImage: systemIcon(for: item))
                        .resizable()
                        .frame(width: 72, height: 72)
                }
            }
            .frame(width: 100, height: 100)
            .background(isSelected || isDropTarget ? Color.accentColor.opacity(isDropTarget ? 0.35 : 0.18) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))

            Text(item.name)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 4)
                .background(isSelected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .frame(width: 116)
        .contentShape(Rectangle())
        .modifier(FolderDropTarget(item: item, actions: actions, isTargeted: $isDropTarget))
        .task(id: item.id) {
            guard item.mayHaveThumbnail, let device = model.device, let storageID = model.storageID else { return }
            thumbnail = await ThumbnailLoader.shared.image(for: item, storageID: storageID, on: device)
        }
    }
}

/// Lets folder cells accept drops; files ignore it.
private struct FolderDropTarget: ViewModifier {
    let item: RemoteItem
    let actions: FileActions
    @Binding var isTargeted: Bool

    func body(content: Content) -> some View {
        if item.isFolder {
            content.dropDestination(for: DropItem.self) { dropped, _ in
                actions.drop(dropped, item)
            } isTargeted: { isTargeted = $0 }
        } else {
            content
        }
    }
}

// MARK: - Path bar

struct PathBar: View {
    let model: BrowserModel

    var body: some View {
        HStack(spacing: 2) {
            Button {
                model.navigate(to: [])
            } label: {
                Label(model.storage?.description ?? "Bộ nhớ", systemImage: "internaldrive")
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.path.isEmpty ? Color.primary : Color.secondary)

            ForEach(Array(model.path.enumerated()), id: \.offset) { index, name in
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Button(name) {
                    model.navigate(to: Array(model.path.prefix(index + 1)))
                }
                .buttonStyle(.plain)
                .lineLimit(1)
                .foregroundStyle(index == model.path.count - 1 ? Color.primary : Color.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
