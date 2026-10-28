import Testing
@testable import AgentsKit

@Test func formatsElapsed() {
    #expect(AgentFormat.elapsed(5) == "<1 мин")
    #expect(AgentFormat.elapsed(60) == "1 мин")
    #expect(AgentFormat.elapsed(59 * 60 + 59) == "59 мин")
    #expect(AgentFormat.elapsed(60 * 60) == "1 ч")
    #expect(AgentFormat.elapsed(5 * 60 * 60 + 10) == "5 ч")
    #expect(AgentFormat.elapsed(-3) == "<1 мин")
}
