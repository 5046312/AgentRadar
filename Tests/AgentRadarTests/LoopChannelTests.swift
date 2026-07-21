import XCTest
@testable import AgentRadar

@MainActor
final class LoopChannelTests: XCTestCase {
    func testCreatesNormalizedHTTPSChannel() throws {
        let id = UUID(uuidString: "1AE23C7E-994C-4E58-931B-F1EAE3D60361")!

        let channel = try LoopChannelConfiguration(
            id: id,
            name: " 主渠道 ",
            baseURL: "https://rawchat.cn/codex/",
            apiKey: " secret "
        )

        XCTAssertEqual(channel.id, id)
        XCTAssertEqual(channel.name, "主渠道")
        XCTAssertEqual(channel.baseURL, "https://rawchat.cn/codex")
        XCTAssertEqual(channel.apiKey, "secret")
    }

    func testRejectsInvalidChannelFields() {
        XCTAssertThrowsError(
            try LoopChannelConfiguration(name: " ", baseURL: "https://example.com", apiKey: "key")
        ) { error in
            XCTAssertEqual(error as? LoopChannelValidationError, .nameRequired)
        }
        XCTAssertThrowsError(
            try LoopChannelConfiguration(name: "渠道", baseURL: "http://example.com", apiKey: "key")
        ) { error in
            XCTAssertEqual(error as? LoopChannelValidationError, .invalidBaseURL)
        }
        XCTAssertThrowsError(
            try LoopChannelConfiguration(name: "渠道", baseURL: "https://example.com", apiKey: " ")
        ) { error in
            XCTAssertEqual(error as? LoopChannelValidationError, .apiKeyRequired)
        }
        XCTAssertNoThrow(
            try LoopChannelConfiguration(name: "本机", baseURL: "http://127.0.0.1:8080/v1", apiKey: "key")
        )
    }

    func testPersistsChannelCRUDAndKeepsKeyWhenEditLeavesItBlank() throws {
        let suiteName = "LoopChannelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = LoopStore(defaults: defaults)

        let channelID = try store.addChannel(
            name: "主渠道",
            baseURL: "https://api.example.com/v1",
            apiKey: "secret"
        )
        try store.updateChannel(
            id: channelID,
            name: "备用渠道",
            baseURL: "https://backup.example.com/v1",
            apiKey: nil
        )

        let reloaded = LoopStore(defaults: defaults)
        XCTAssertEqual(reloaded.channels.map(\.name), ["备用渠道"])
        XCTAssertEqual(reloaded.channels.first?.baseURL, "https://backup.example.com/v1")
        XCTAssertEqual(reloaded.channels.first?.apiKey, "secret")

        try reloaded.deleteChannel(id: channelID)
        XCTAssertTrue(LoopStore(defaults: defaults).channels.isEmpty)
    }

    func testAggregateStatusUsesFailureRecoveryPendingSuccessPriority() throws {
        var success = LoopChannel(configuration: try LoopChannelConfiguration(
            name: "成功",
            baseURL: "https://success.example.com",
            apiKey: "key"
        ))
        success.phase = .running(count: 1, startedAt: .now)
        success.streakSucceeded = true

        var recovered = LoopChannel(configuration: try LoopChannelConfiguration(
            name: "恢复",
            baseURL: "https://recovered.example.com",
            apiKey: "key"
        ))
        recovered.phase = .waiting(count: 2, nextRunAt: .now)
        recovered.streakSucceeded = true
        recovered.recoveredFromFailure = true

        var pending = LoopChannel(configuration: try LoopChannelConfiguration(
            name: "等待",
            baseURL: "https://pending.example.com",
            apiKey: "key"
        ))
        pending.phase = .resolvingCodex

        var failure = LoopChannel(configuration: try LoopChannelConfiguration(
            name: "失败",
            baseURL: "https://failure.example.com",
            apiKey: "key"
        ))
        failure.phase = .running(count: 1, startedAt: .now)
        failure.streakSucceeded = false

        XCTAssertEqual(LoopAggregateStatus.resolve([]), .inactive)
        XCTAssertEqual(LoopAggregateStatus.resolve([success]), .success)
        XCTAssertEqual(LoopAggregateStatus.resolve([success, pending]), .pending)
        XCTAssertEqual(LoopAggregateStatus.resolve([success, pending, recovered]), .recovered)
        XCTAssertEqual(LoopAggregateStatus.resolve([success, pending, recovered, failure]), .failure)
    }

    func testCodexProviderConfigurationUsesResponsesHTTPSOnlyAndEnvironmentKey() throws {
        let channel = try LoopChannelConfiguration(
            name: "主渠道",
            baseURL: "https://rawchat.cn/codex",
            apiKey: "secret"
        )

        XCTAssertEqual(channel.codexConfigurationOverrides, [
            "model_provider=\"agentradar_loop\"",
            "model_providers.agentradar_loop.name=\"AgentRadar Loop\"",
            "model_providers.agentradar_loop.base_url=\"https://rawchat.cn/codex\"",
            "model_providers.agentradar_loop.wire_api=\"responses\"",
            "model_providers.agentradar_loop.env_key=\"AGENTRADAR_LOOP_API_KEY\"",
            "model_providers.agentradar_loop.supports_websockets=false"
        ])
    }
}
