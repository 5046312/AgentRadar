import XCTest
@testable import AgentRadar

final class HookConfigurationManagerTests: XCTestCase {
    func testCodexConfigUpdatesOnlyExactHooksKey() {
        let source = """
        [features]
        hooks_extra = false
        hooks = false

        [other]
        enabled = true
        """

        let updated = HookConfigurationManager.updatedCodexConfigText(from: source)

        XCTAssertTrue(updated.contains("hooks_extra = false"))
        XCTAssertTrue(updated.contains("hooks = true"))
        XCTAssertTrue(updated.contains("[other]"))
        XCTAssertTrue(HookConfigurationManager.codexHooksEnabled(in: updated))
    }

    func testCodexConfigDoesNotTreatHooksPrefixAsHooksFlag() {
        let source = """
        [features]
        hooks_extra = true
        """

        XCTAssertFalse(HookConfigurationManager.codexHooksEnabled(in: source))
    }
}
