import AppKit
import SwiftUI

struct TransfersView: View {
    private var transfers: TransferManager { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Chuyển file").font(.headline)
                Spacer()
                Button("Xoá mục đã xong") { transfers.clearFinished() }
                    .controlSize(.small)
                    .disabled(!transfers.jobs.contains { $0.state.isFinished })
            }
            .padding(12)
            Divider()
            if transfers.visibleJobs.isEmpty {
                Text("Chưa có lượt chuyển file nào.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(transfers.visibleJobs) { job in
                            JobRow(job: job)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .frame(width: 380)
    }
}

private struct JobRow: View {
    let job: TransferJob

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: job.kind == .download ? "arrow.down.circle" : "arrow.up.circle")
                .font(.title2)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if job.state == .running || job.state == .queued {
                    ProgressView(value: job.fraction)
                        .controlSize(.small)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            actions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var actions: some View {
        switch job.state {
        case .queued, .running:
            Button { job.cancel() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Huỷ")
        case .done where job.kind == .download && !job.isTemporary:
            if let url = job.resultURL {
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                    Image(systemName: "magnifyingglass.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Hiện trong Finder")
            }
        default:
            EmptyView()
        }
    }

    private var tint: Color {
        switch job.state {
        case .failed: return .red
        case .done: return .green
        case .cancelled: return .secondary
        default: return .accentColor
        }
    }

    private var detail: String {
        switch job.state {
        case .queued:
            return "Đang chờ…"
        case .running:
            let files = job.filesTotal > 1 ? "Tệp \(min(job.filesDone + 1, job.filesTotal))/\(job.filesTotal) · " : ""
            let bytes = job.bytesTotal > 0 ? "\(Fmt.bytes(job.bytesDone)) / \(Fmt.bytes(job.bytesTotal))" : ""
            return files + bytes + (job.currentFile.isEmpty ? "" : "\n\(job.currentFile)")
        case .cancelling:
            return "Đang huỷ… (điện thoại cần khoảng 10 giây để sẵn sàng lại)"
        case .done:
            let summary = job.filesTotal > 1 ? "Xong · \(job.filesTotal) tệp · \(Fmt.bytes(job.bytesTotal))" : "Xong · \(Fmt.bytes(job.bytesTotal))"
            return job.doneNote.map { summary + "\n" + $0 } ?? summary
        case .cancelled:
            return "Đã huỷ"
        case .failed(let msg):
            return msg
        }
    }
}
