import Foundation

// Async requests may finish in any order, including after cancellation. A
// request must still own its ticket before it changes rows, errors or spinners.
struct RequestGate: Sendable {
    private(set) var current: UUID?
    mutating func begin() -> UUID { let id = UUID(); current = id; return id }
    func accepts(_ id: UUID) -> Bool { current == id }
    mutating func finish(_ id: UUID) { if current == id { current = nil } }
    mutating func cancel() { current = nil }
}

struct AccountEpoch: Equatable, Sendable {
    private(set) var value = UUID()
    mutating func invalidate() { value = UUID() }
    func accepts(_ ticket: UUID) -> Bool { value == ticket }
}
