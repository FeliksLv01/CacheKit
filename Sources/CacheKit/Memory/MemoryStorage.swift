import Foundation

private final class MemoryNode<Value>: @unchecked Sendable where Value: Sendable {
    let key: String
    var value: Value
    var cost: Int
    var expirationTimestamp: TimeInterval?
    unowned(unsafe) var previous: MemoryNode?
    var next: MemoryNode?

    init(
        key: String,
        value: Value,
        cost: Int,
        expirationTimestamp: TimeInterval?
    ) {
        self.key = key
        self.value = value
        self.cost = cost
        self.expirationTimestamp = expirationTimestamp
    }
}

public final class MemoryStorage<Value: Sendable>: @unchecked Sendable {
    private typealias Node = MemoryNode<Value>

    private let lock = UnfairLock()
    private let countLimit: Int
    private let costLimit: Int
    private let now: (@Sendable () -> Date)?
    private var nodes: [String: Node] = [:]
    private var head: Node?
    private var tail: Node?
    private var totalCost = 0

    public init(
        countLimit: Int,
        costLimit: Int,
        now: (@Sendable () -> Date)? = nil
    ) {
        precondition(countLimit >= 0)
        precondition(costLimit >= 0)
        self.countLimit = countLimit
        self.costLimit = costLimit
        self.now = now
        if countLimit > 0 {
            nodes.reserveCapacity(countLimit)
        }
    }

    public func value(forKey key: String) -> Value? {
        let injectedTimestamp = now?().timeIntervalSince1970
        var removedNode: Node?
        let value: Value? = lock.withLock { () -> Value? in
            guard let node = nodes[key] else { return nil }
            if let expirationTimestamp = node.expirationTimestamp,
               expirationTimestamp <= (injectedTimestamp ?? Date().timeIntervalSince1970) {
                nodes.removeValue(forKey: key)
                totalCost -= node.cost
                detach(node)
                removedNode = node
                return nil
            }
            moveToHead(node)
            return node.value
        }
        withExtendedLifetime(removedNode) {}
        return value
    }

    public func setValue(_ value: Value, forKey key: String, cost: Int = 0, expirationDate: Date? = nil) {
        precondition(cost >= 0)
        var displacedValues: [Value] = []
        var removedNodes: [Node] = []
        lock.withLock {
            if let node = nodes[key] {
                displacedValues.append(node.value)
                totalCost -= node.cost
                node.value = value
                node.cost = cost
                node.expirationTimestamp = expirationDate?.timeIntervalSince1970
                totalCost += cost
                moveToHead(node)
            } else {
                let node = Node(
                    key: key,
                    value: value,
                    cost: cost,
                    expirationTimestamp: expirationDate?.timeIntervalSince1970
                )
                nodes[key] = node
                totalCost += cost
                insertAtHead(node)
            }

            while exceedsLimits, let victim = tail {
                nodes.removeValue(forKey: victim.key)
                totalCost -= victim.cost
                detach(victim)
                removedNodes.append(victim)
            }
        }
        withExtendedLifetime(displacedValues) {}
        withExtendedLifetime(removedNodes) {}
    }

    public func removeValue(forKey key: String) {
        let removedNode: Node? = lock.withLock { () -> Node? in
            guard let node = nodes.removeValue(forKey: key) else { return nil }
            totalCost -= node.cost
            detach(node)
            return node
        }
        withExtendedLifetime(removedNode) {}
    }

    public func removeAll() {
        let removedHead = lock.withLock {
            let removedHead = head
            nodes.removeAll(keepingCapacity: true)
            head = nil
            tail = nil
            totalCost = 0
            return removedHead
        }
        withExtendedLifetime(removedHead) {}
    }

    public var count: Int {
        lock.withLock { nodes.count }
    }

    private var exceedsLimits: Bool {
        (countLimit > 0 && nodes.count > countLimit) ||
            (costLimit > 0 && totalCost > costLimit)
    }

    private func insertAtHead(_ node: Node) {
        node.previous = nil
        node.next = head
        head?.previous = node
        head = node
        if tail == nil {
            tail = node
        }
    }

    private func moveToHead(_ node: Node) {
        guard head !== node else { return }
        detach(node)
        insertAtHead(node)
    }

    private func detach(_ node: Node) {
        let previous = node.previous
        let next = node.next
        previous?.next = next
        next?.previous = previous
        if head === node {
            head = next
        }
        if tail === node {
            tail = previous
        }
        node.previous = nil
        node.next = nil
    }
}
