import XCTest
@testable import AgentRadar

final class CodexCommandContextTests: XCTestCase {
    func testUsesLoginShellPathWhenExecutingResolvedCodex() throws {
        let output = """
        __AGENTRADAR_CODEX_PATH__=/bin/zsh
        __AGENTRADAR_LOGIN_PATH__=/Users/test/.nvm/versions/node/v20/bin:/Users/test/Library/pnpm:/usr/bin:/bin

        """
        let context = try XCTUnwrap(CodexCommandContext(discoveryOutput: output))

        let environment = context.executionEnvironment(base: ["PATH": "/usr/bin:/bin"])

        XCTAssertEqual(context.executableURL.path, "/bin/zsh")
        XCTAssertEqual(
            environment["PATH"],
            "/Users/test/.nvm/versions/node/v20/bin:/Users/test/Library/pnpm:/usr/bin:/bin"
        )
    }

    func testRejectsUntaggedShellStartupPath() {
        let output = """
        /bin/zsh
        __AGENTRADAR_LOGIN_PATH__=/usr/bin:/bin

        """

        XCTAssertNil(CodexCommandContext(discoveryOutput: output))
    }
}
