import Foundation
import Combine

public enum ImportOutcome: Equatable {
    case imported(entryID: String), duplicate(entryID: String)
}

public enum ImportStatus: Equatable {
    case waiting, reading, importing
    case imported(entryID: String), duplicate(entryID: String), failed(String)

    public var entryID: String? {
        switch self {
        case .imported(let id), .duplicate(let id): return id
        default: return nil
        }
    }
}

public struct ImportItem: Identifiable {
    public let id = UUID()
    public var name: String
    public var status: ImportStatus = .waiting
}

public struct ImportCandidate {
    public let name: String
    let loadURL: @MainActor () async throws -> URL

    public init(name: String, loadURL: @escaping @MainActor () async throws -> URL) {
        self.name = name
        self.loadURL = loadURL
    }

    public static func file(_ url: URL) -> ImportCandidate {
        ImportCandidate(name: url.lastPathComponent) { url }
    }
}

/// Transient feedback for the latest batch, including failures before a file URL is resolved.
@MainActor public final class ImportBatch: ObservableObject {
    @Published public private(set) var items: [ImportItem] = []
    @Published public private(set) var isImporting = false
    @Published public private(set) var notice: String?

    public init() {}

    @discardableResult public func start(
        _ candidates: [ImportCandidate],
        importFile: @escaping (URL) async throws -> ImportOutcome,
        completion: @escaping () -> Void = {}
    ) -> Bool {
        guard !isImporting else {
            notice = "上一批文件仍在导入，此次未导入。请等待完成后再选择或拖入。"
            return false
        }
        guard !candidates.isEmpty else { notice = "未收到文件，请重新选择或拖入图片。"; return false }
        guard candidates.count <= 10 else {
            notice = "每次最多导入 10 张图片，本次 \(candidates.count) 个文件均未导入。请分批重试。"
            return false
        }
        isImporting = true
        notice = nil
        items = candidates.map { ImportItem(name: $0.name) }
        Task {
            for (index, candidate) in candidates.enumerated() {
                items[index].status = .reading
                do {
                    let url = try await candidate.loadURL()
                    if !url.lastPathComponent.isEmpty { items[index].name = url.lastPathComponent }
                    items[index].status = .importing
                    switch try await importFile(url) {
                    case .imported(let id): items[index].status = .imported(entryID: id)
                    case .duplicate(let id): items[index].status = .duplicate(entryID: id)
                    }
                } catch { items[index].status = .failed(error.localizedDescription) }
            }
            isImporting = false
            completion()
        }
        return true
    }
}
