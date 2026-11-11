import Foundation

/// A small serial assertion runner for machines with Command Line Tools only.
enum TestResults {
    struct Failure {
        let group: String
        let message: String
        let file: StaticString
        let line: UInt
    }
    private(set) static var groupCount = 0
    private(set) static var assertionCount = 0
    private(set) static var failures: [Failure] = []
    private static var currentGroup = "执行器"

    static func run(_ name: String, file: StaticString = #filePath, line: UInt = #line,
                    _ body: () throws -> Void) {
        groupCount += 1
        currentGroup = name
        let previousFailures = failures.count
        do { try body() } catch {
            fail("测试抛出未捕获错误：\(error)", file: file, line: line)
        }
        print("\(failures.count == previousFailures ? "通过" : "失败")：\(name)")
    }

    static func check(_ success: Bool, _ message: String, file: StaticString, line: UInt) {
        assertionCount += 1
        if !success { fail(message, file: file, line: line) }
    }

    static func fail(_ message: String, file: StaticString, line: UInt) {
        failures.append(Failure(group: currentGroup, message: message, file: file, line: line))
    }

    static func printSummary() {
        for failure in failures {
            print("\(failure.file):\(failure.line)：[\(failure.group)] \(failure.message)")
        }
        print("共 \(groupCount) 组，\(assertionCount) 项断言，\(failures.count) 项失败。")
    }
}

func expectEqual<T: Equatable>(
    _ actual: @autoclosure () throws -> T,
    _ expected: @autoclosure () throws -> T,
    file: StaticString = #filePath, line: UInt = #line
) {
    do {
        let actualValue = try actual()
        let expectedValue = try expected()
        TestResults.check(actualValue == expectedValue,
                          "预期 \(String(reflecting: expectedValue))，实际 \(String(reflecting: actualValue))。",
                          file: file, line: line)
    } catch {
        TestResults.check(false, "比较时意外抛出错误：\(error)", file: file, line: line)
    }
}

func expectEqual(
    _ actual: @autoclosure () throws -> Double,
    _ expected: @autoclosure () throws -> Double,
    accuracy: Double,
    file: StaticString = #filePath, line: UInt = #line
) {
    do {
        let actualValue = try actual()
        let expectedValue = try expected()
        let success = accuracy >= 0 && (actualValue == expectedValue || abs(actualValue - expectedValue) <= accuracy)
        TestResults.check(success, "预期 \(expectedValue) ± \(accuracy)，实际 \(actualValue)。", file: file, line: line)
    } catch {
        TestResults.check(false, "比较时意外抛出错误：\(error)", file: file, line: line)
    }
}

func expectTrue(_ expression: @autoclosure () throws -> Bool,
                file: StaticString = #filePath, line: UInt = #line) {
    do {
        TestResults.check(try expression(), "预期 true，实际 false。", file: file, line: line)
    } catch {
        TestResults.check(false, "断言时意外抛出错误：\(error)", file: file, line: line)
    }
}

func expectFalse(_ expression: @autoclosure () throws -> Bool,
                 file: StaticString = #filePath, line: UInt = #line) {
    do {
        TestResults.check(!(try expression()), "预期 false，实际 true。", file: file, line: line)
    } catch {
        TestResults.check(false, "断言时意外抛出错误：\(error)", file: file, line: line)
    }
}

func expectNil<T>(_ expression: @autoclosure () throws -> T?,
                  file: StaticString = #filePath, line: UInt = #line) {
    do {
        let value = try expression()
        TestResults.check(value == nil, "预期 nil，实际 \(String(reflecting: value))。", file: file, line: line)
    } catch {
        TestResults.check(false, "断言时意外抛出错误：\(error)", file: file, line: line)
    }
}

func expectThrowsError<T>(
    _ expression: @autoclosure () throws -> T,
    file: StaticString = #filePath, line: UInt = #line,
    _ errorHandler: ((Error) throws -> Void)? = nil
) {
    do {
        _ = try expression()
        TestResults.check(false, "预期抛出错误，但表达式成功返回。", file: file, line: line)
    } catch {
        TestResults.check(true, "", file: file, line: line)
        do { try errorHandler?(error) } catch {
            TestResults.fail("错误检查回调抛出未捕获错误：\(error)", file: file, line: line)
        }
    }
}
