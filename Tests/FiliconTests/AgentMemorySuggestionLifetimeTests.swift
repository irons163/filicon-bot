import Testing
import CustomDump
@testable import FiliconAgents

@Suite("Composite memory lifetime", .timeLimit(.minutes(1)))
struct AgentMemorySuggestionLifetimeTests {
    @Test(arguments: ["first", "second", "ancestor", "child"])
    func anyRevokedScopePreventsFinalCommit(scope: String) throws {
        let ancestor = AgentMemorySuggestionLifetime()
        let first = AgentMemorySuggestionLifetime(parents: [ancestor])
        let second = AgentMemorySuggestionLifetime()
        let child = AgentMemorySuggestionLifetime(parents: [second, first, ancestor, first])
        try child.check()
        switch scope {
        case "first": first.close()
        case "second": second.close()
        case "ancestor": ancestor.close()
        default: child.close()
        }
        var saved = false
        #expect(throws: CancellationError.self) { try child.commit { saved = true } }
        expectNoDifference(saved, false)
        if scope == "child" { try first.check(); try second.check(); try ancestor.check() }
    }

    @Test func oppositeParentOrderUsesOneLockOrder() async throws {
        let first = AgentMemorySuggestionLifetime(), second = AgentMemorySuggestionLifetime()
        let lhs = AgentMemorySuggestionLifetime(parents: [first, second])
        let rhs = AgentMemorySuggestionLifetime(parents: [second, first])
        let count = try await withThrowingTaskGroup(of: Int.self) { tasks in
            for n in 0..<100 { tasks.addTask { try (n.isMultiple(of: 2) ? lhs : rhs).commit { 1 } } }
            var total = 0
            for try await result in tasks { total += result }
            return total
        }
        expectNoDifference(count, 100)
    }
}
