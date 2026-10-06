import Foundation

enum TestFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

func fail(_ message: String) throws {
    throw TestFailure.failed(message)
}

@discardableResult
func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws -> Bool {
    if try !condition() {
        throw TestFailure.failed(message)
    }
    return true
}

func expectEqual<T: Equatable>(_ actual: @autoclosure () throws -> T, _ expected: @autoclosure () throws -> T, _ message: String) throws {
    let lhs = try actual()
    let rhs = try expected()
    if lhs != rhs {
        throw TestFailure.failed("\(message) (got: \(lhs), expected: \(rhs))")
    }
}

func expectNil<T>(_ value: @autoclosure () -> T?, _ message: String) throws {
    if value() != nil {
        throw TestFailure.failed(message)
    }
}

func expectNotNil<T>(_ value: @autoclosure () -> T?, _ message: String) throws {
    if value() == nil {
        throw TestFailure.failed(message)
    }
}

/// Holds a value produced inside a `Task` so a synchronous test can read it after
/// waiting. A captured `var` is a concurrency error under Swift 6 checking.
final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}
