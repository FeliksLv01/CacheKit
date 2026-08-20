import Foundation

public struct CacheCodec<Value>: Sendable {
    public let encode: @Sendable (Value) throws -> Data
    public let decode: @Sendable (Data) throws -> Value

    public init(
        encode: @escaping @Sendable (Value) throws -> Data,
        decode: @escaping @Sendable (Data) throws -> Value
    ) {
        self.encode = encode
        self.decode = decode
    }
}

public extension CacheCodec where Value == Data {
    static let data = CacheCodec(encode: { $0 }, decode: { $0 })
}

public extension CacheCodec where Value: Codable & Sendable {
    static var codable: CacheCodec<Value> {
        CacheCodec(
            encode: { try JSONEncoder().encode($0) },
            decode: { try JSONDecoder().decode(Value.self, from: $0) }
        )
    }
}
