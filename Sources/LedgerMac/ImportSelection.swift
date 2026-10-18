import Foundation
import Combine

public struct ImportSelectionItem: Identifiable {
    public let id = UUID()
    public var name: String
    public var url: URL?
    public var preview: ImagePreview?
    public var error: String?
    public var isChecking = true
}

/// Holds a read-only selection until the user explicitly confirms it.
@MainActor public final class ImportSelection: ObservableObject {
    @Published public private(set) var rows: [ImportSelectionItem] = []
    @Published public private(set) var isPresented = false
    @Published public private(set) var isChecking = false
    @Published public private(set) var notice: String?
    private var generation = UUID()

    public init() {}
    public var readyCount: Int { rows.filter { $0.preview != nil && $0.error == nil }.count }

    @discardableResult public func stage(_ candidates: [ImportCandidate]) -> Bool {
        guard !isPresented else { notice = "请先确认或取消当前待导入文件，再选择新的一批。"; return false }
        guard !candidates.isEmpty else { notice = "未收到文件，请重新选择或拖入图片。"; return false }
        guard candidates.count <= 10 else { notice = "每次最多选择 10 张图片，本次文件均未导入。请分批重试。"; return false }
        generation = UUID()
        let current = generation
        notice = nil
        rows = candidates.map { ImportSelectionItem(name: $0.name) }
        let ids = rows.map(\.id)
        isPresented = true
        isChecking = true
        Task {
            for (id, candidate) in zip(ids, candidates) {
                guard generation == current else { return }
                guard rows.contains(where: { $0.id == id }) else { continue }
                do {
                    let url = try await candidate.loadURL()
                    guard generation == current else { return }
                    guard let index = rows.firstIndex(where: { $0.id == id }) else { continue }
                    rows[index].url = url
                    if !url.lastPathComponent.isEmpty { rows[index].name = url.lastPathComponent }
                    let preview = try await Task.detached(priority: .userInitiated) {
                        try ImagePipeline.preview(url: url)
                    }.value
                    guard generation == current else { return }
                    if let index = rows.firstIndex(where: { $0.id == id }) {
                        rows[index].preview = preview
                        rows[index].isChecking = false
                    }
                } catch {
                    guard generation == current else { return }
                    if let index = rows.firstIndex(where: { $0.id == id }) {
                        rows[index].error = error.localizedDescription
                        rows[index].isChecking = false
                    }
                }
            }
            guard generation == current else { return }
            isChecking = false
        }
        return true
    }

    public func remove(_ id: UUID) { rows.removeAll { $0.id == id } }

    public func cancel() {
        generation = UUID()
        rows = []
        isPresented = false
        isChecking = false
        notice = nil
    }

    public func confirm() -> [ImportCandidate] {
        guard isPresented, !isChecking, readyCount > 0 else { return [] }
        let candidates = rows.compactMap { row -> ImportCandidate? in
            guard let preview = row.preview, row.error == nil, let url = row.url else { return nil }
            return .file(url, expectedContentHash: preview.contentHash)
        }
        cancel()
        return candidates
    }
}
