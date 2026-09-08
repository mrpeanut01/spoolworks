import Foundation

// A minimal test harness.
//
// This machine has Command Line Tools without Xcode: XCTest is absent, and the bundled
// Testing.framework is incomplete (dyld cannot resolve lib_TestingInterop.dylib). Rather than
// depend on a toolchain that may or may not be installed, tests are a plain executable — they
// run anywhere Swift runs, including CI, with `swift run SpoolworksTests`.
//
// Exit code is 0 when everything passes and 1 otherwise, so it drops straight into a pipeline.

struct Expectation {
    let message: String
    let file: String
    let line: Int
}

final class TestContext {
    private(set) var failures: [Expectation] = []

    func record(_ message: String, file: String, line: Int) {
        failures.append(Expectation(message: message, file: (file as NSString).lastPathComponent, line: line))
    }

    /// Asserts a condition.
    func expect(_ condition: Bool, _ message: @autoclosure () -> String = "expected true",
                file: String = #file, line: Int = #line) {
        if !condition { record(message(), file: file, line: line) }
    }

    /// Asserts equality, reporting both sides on failure.
    func equal<T: Equatable>(_ actual: T, _ expected: T, _ label: String = "",
                             file: String = #file, line: Int = #line) {
        if actual != expected {
            let prefix = label.isEmpty ? "" : "\(label): "
            record("\(prefix)expected \(expected), got \(actual)", file: file, line: line)
        }
    }

    /// Asserts the value is non-nil and returns it, so callers can keep going.
    func unwrap<T>(_ value: T?, _ label: String = "value",
                   file: String = #file, line: Int = #line) -> T? {
        if value == nil { record("\(label) was nil", file: file, line: line) }
        return value
    }

    /// Asserts the closure throws anything.
    func throwsError(_ label: String = "operation", file: String = #file, line: Int = #line,
                     _ body: () throws -> Void) {
        do {
            try body()
            record("\(label) should have thrown but did not", file: file, line: line)
        } catch {
            // expected
        }
    }

    /// Asserts the closure throws a specific, equatable error.
    func throwsError<E: Error & Equatable>(_ expected: E, file: String = #file, line: Int = #line,
                                           _ body: () throws -> Void) {
        do {
            try body()
            record("expected to throw \(expected) but did not throw", file: file, line: line)
        } catch let error as E where error == expected {
            // expected
        } catch {
            record("expected \(expected), got \(error)", file: file, line: line)
        }
    }

    /// Asserts the closure does not throw.
    func noThrow(_ label: String = "operation", file: String = #file, line: Int = #line,
                 _ body: () throws -> Void) {
        do { try body() }
        catch { record("\(label) threw unexpectedly: \(error)", file: file, line: line) }
    }
}

struct TestCase {
    let name: String
    let run: (TestContext) throws -> Void
}

struct TestSuite {
    let name: String
    let cases: [TestCase]
}

/// Sugar so test files read close to a normal testing DSL.
func test(_ name: String, _ run: @escaping (TestContext) throws -> Void) -> TestCase {
    TestCase(name: name, run: run)
}

enum TestDriver {
    static func run(_ suites: [TestSuite]) -> Int32 {
        var passed = 0
        var failed = 0
        let start = Date()

        for suite in suites {
            print("\n\u{1B}[1m\(suite.name)\u{1B}[0m")
            for testCase in suite.cases {
                let ctx = TestContext()
                var thrown: Error?
                do { try testCase.run(ctx) } catch { thrown = error }

                if let thrown {
                    failed += 1
                    print("  \u{1B}[31m✗\u{1B}[0m \(testCase.name)")
                    print("      threw unexpectedly: \(thrown)")
                } else if ctx.failures.isEmpty {
                    passed += 1
                    print("  \u{1B}[32m✓\u{1B}[0m \(testCase.name)")
                } else {
                    failed += 1
                    print("  \u{1B}[31m✗\u{1B}[0m \(testCase.name)")
                    for f in ctx.failures {
                        print("      \(f.message)  (\(f.file):\(f.line))")
                    }
                }
            }
        }

        let elapsed = String(format: "%.2fs", Date().timeIntervalSince(start))
        print("\n" + String(repeating: "─", count: 52))
        if failed == 0 {
            print("\u{1B}[32m\(passed) passed\u{1B}[0m in \(elapsed)")
            return 0
        }
        print("\u{1B}[31m\(failed) failed\u{1B}[0m, \(passed) passed in \(elapsed)")
        return 1
    }
}
