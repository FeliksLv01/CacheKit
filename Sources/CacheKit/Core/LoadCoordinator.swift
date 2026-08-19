import Foundation

actor LoadCoordinator<Value: Sendable> {
    private struct Operation: Sendable {
        let identifier: UUID
        let task: Task<Value, Error>
    }

    private var operations: [String: Operation] = [:]

    func value(
        forKey key: String,
        loader: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        if let operation = operations[key] {
            return try await operation.task.value
        }

        let identifier = UUID()
        let task = Task { try await loader() }
        operations[key] = Operation(identifier: identifier, task: task)
        do {
            let value = try await task.value
            removeOperation(forKey: key, identifier: identifier)
            return value
        } catch {
            removeOperation(forKey: key, identifier: identifier)
            throw error
        }
    }

    private func removeOperation(forKey key: String, identifier: UUID) {
        guard operations[key]?.identifier == identifier else { return }
        operations.removeValue(forKey: key)
    }
}
