import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
    /// Private drag type so dropping a task on the grid can be told apart from
    /// dropping arbitrary text. Declared in Info.plist as an exported type.
    static let cadenceTodo = UTType(exportedAs: "dev.xiaochen.Cadence.todo")
}

/// What travels from a task row to the calendar grid. Only the id — the drop
/// handler reads everything else from the model, so a stale payload cannot
/// resurrect a deleted task.
struct TodoTransfer: Codable, Transferable, Hashable {
    var todoID: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .cadenceTodo)
    }
}
