import Foundation

struct TestFailure: Error, CustomStringConvertible {
    let message: String
    let file: String
    let line: Int

    var description: String { "\(message) (\(file):\(line))" }
}

func expect(_ condition: Bool, _ message: String, file: String = #fileID, line: Int = #line) throws {
    if !condition {
        throw TestFailure(message: message, file: file, line: line)
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", file: String = #fileID, line: Int = #line) throws {
    if actual != expected {
        throw TestFailure(message: "\(message.isEmpty ? "not equal" : message): \(actual) != \(expected)", file: file, line: line)
    }
}

func expectApprox(_ actual: Double, _ expected: Double, _ epsilon: Double = 1e-9, _ message: String = "", file: String = #fileID, line: Int = #line) throws {
    if abs(actual - expected) > epsilon {
        throw TestFailure(message: "\(message.isEmpty ? "not approximately equal" : message): \(actual) vs \(expected)", file: file, line: line)
    }
}

func required<T>(_ value: T?, _ message: String = "unexpected nil", file: String = #fileID, line: Int = #line) throws -> T {
    guard let value else { throw TestFailure(message: message, file: file, line: line) }
    return value
}

private var passed = 0
private var failed = 0

func runTest(_ name: String, _ body: () throws -> Void) {
    do {
        try body()
        passed += 1
        print("✔ \(name)")
    } catch {
        failed += 1
        print("✘ \(name): \(error)")
    }
}

func finish() -> Never {
    print("\nArgusTests: \(passed) passed, \(failed) failed")
    exit(failed == 0 ? 0 : 1)
}
