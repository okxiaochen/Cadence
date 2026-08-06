import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Dragging tasks around the app.
///
/// This uses `NSItemProvider` with `onDrag`/`onDrop` rather than SwiftUI's
/// `Transferable` + `.draggable`/`.dropDestination`. Inside a `List` that also
/// has selection and its own gestures, `.draggable` silently never starts the
/// drag; the AppKit-backed path is the one that actually works there.
enum TaskDrag {
    /// A private type identifier, declared in Info.plist. Keeping it private
    /// means text dragged in from elsewhere cannot masquerade as a task.
    static let typeIdentifier = "dev.xiaochen.Cadence.todo"

    static func provider(for todoID: String) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: typeIdentifier,
            visibility: .ownProcess
        ) { completion in
            completion(Data(todoID.utf8), nil)
            return nil
        }
        return provider
    }

    /// Item providers arrive with their payload behind an async load, so the
    /// ids come back on the main actor once every provider has answered.
    static func todoIDs(
        from providers: [NSItemProvider],
        completion: @escaping @MainActor ([String]) -> Void
    ) -> Bool {
        let matching = providers.filter { $0.hasItemConformingToTypeIdentifier(typeIdentifier) }
        guard !matching.isEmpty else { return false }

        let group = DispatchGroup()
        let collector = IDCollector()

        for provider in matching {
            group.enter()
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                if let data, let id = String(data: data, encoding: .utf8), !id.isEmpty {
                    collector.append(id)
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            let ids = collector.ids
            guard !ids.isEmpty else { return }
            MainActor.assumeIsolated { completion(ids) }
        }
        return true
    }
}

private final class IDCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var ids: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ id: String) { lock.lock(); storage.append(id); lock.unlock() }
}

// MARK: - Source

extension View {
    func todoDragSource(_ todoID: String) -> some View {
        onDrag { TaskDrag.provider(for: todoID) }
    }
}

// MARK: - Simple destination

/// For targets that only need "which tasks", not "dropped where".
struct TodoDropTarget: ViewModifier {
    var onDrop: @MainActor ([String]) -> Void

    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.accentColor.opacity(isTargeted ? 0.25 : 0))
            )
            .onDrop(of: [TaskDrag.typeIdentifier], isTargeted: $isTargeted) { providers in
                TaskDrag.todoIDs(from: providers, completion: onDrop)
            }
    }
}

extension View {
    func todoDropTarget(_ perform: @escaping @MainActor ([String]) -> Void) -> some View {
        modifier(TodoDropTarget(onDrop: perform))
    }
}

// MARK: - Positional destination

/// The calendar needs the drop *point* to turn it into a time, which the plain
/// `onDrop(of:isTargeted:perform:)` does not provide.
struct CalendarDropDelegate: DropDelegate {
    var onEnterExit: @MainActor (Bool) -> Void
    var onDrop: @MainActor (CGPoint, [String]) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType(TaskDrag.typeIdentifier) ?? .data])
    }

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated { onEnterExit(true) }
    }

    func dropExited(info: DropInfo) {
        MainActor.assumeIsolated { onEnterExit(false) }
    }

    func performDrop(info: DropInfo) -> Bool {
        // Captured now: the providers answer asynchronously, by which time the
        // drop info is gone.
        let location = info.location
        MainActor.assumeIsolated { onEnterExit(false) }
        return TaskDrag.todoIDs(from: info.itemProviders(for: [TaskDrag.typeIdentifier])) { ids in
            onDrop(location, ids)
        }
    }
}
