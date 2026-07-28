import Testing

@testable import tng

@Suite struct CLITerminalContextTests {
  @Test func actualTerminalUsesDetectedWidthAndDefaultMarkdownLimit() {
    let context = CLITerminalContext.resolve(
      environment: [:],
      outputIsTerminal: true,
      detectedWidth: 160
    )

    #expect(context.isTerminal)
    #expect(context.viewportWidth == 160)
    #expect(context.markdownWidth == 120)
    #expect(context.colorEnabled)
  }

  @Test func nonTerminalUsesPlainFallbacks() {
    let context = CLITerminalContext.resolve(
      environment: [:],
      outputIsTerminal: false,
      detectedWidth: nil
    )

    #expect(context.isTerminal == false)
    #expect(context.viewportWidth == 80)
    #expect(context.markdownWidth == 80)
    #expect(context.colorEnabled == false)
  }

  @Test(
    arguments: [
      ("40", 200, 40),
      ("50%", 200, 100),
      ("1%", 80, 1),
      ("true", 90, 90),
      ("0", 90, 90),
      ("-1", 90, 90),
      ("0%", 90, 90),
      ("invalid%", 90, 90),
    ]
  )
  func forceTTYControlsTerminalStyleAndViewport(
    specification: String,
    detectedWidth: Int,
    expectedWidth: Int
  ) {
    let context = CLITerminalContext.resolve(
      environment: ["TNG_FORCE_TTY": specification],
      outputIsTerminal: false,
      detectedWidth: detectedWidth
    )

    #expect(context.isTerminal)
    #expect(context.viewportWidth == expectedWidth)
    #expect(context.colorEnabled)
  }

  @Test func percentageForceTTYUsesFallbackWidth() {
    let context = CLITerminalContext.resolve(
      environment: ["TNG_FORCE_TTY": "50%"],
      outputIsTerminal: false,
      detectedWidth: nil
    )

    #expect(context.viewportWidth == 40)
  }

  @Test(
    arguments: [
      ([:], 160, 120),
      (["TNG_MDWIDTH": "72"], 160, 72),
      (["TNG_MDWIDTH": "200"], 160, 160),
      (["TNG_MDWIDTH": "invalid"], 160, 120),
      (["TNG_MDWIDTH": "0"], 160, 120),
      (["TNG_MDWIDTH": "-1"], 160, 120),
    ]
  )
  func markdownWidthUsesConfiguredOrDefaultLimit(
    environment: [String: String],
    viewportWidth: Int,
    expectedWidth: Int
  ) {
    let context = CLITerminalContext.resolve(
      environment: environment.merging(["TNG_FORCE_TTY": String(viewportWidth)]) { current, _ in
        current
      },
      outputIsTerminal: false,
      detectedWidth: nil
    )

    #expect(context.markdownWidth == expectedWidth)
  }

  @Test(
    arguments: [
      (["NO_COLOR": "1"], true, false),
      (["CLICOLOR": "0"], true, false),
      (["CLICOLOR_FORCE": "1"], false, true),
      (["CLICOLOR_FORCE": "0"], false, false),
      (["NO_COLOR": ""], true, true),
      (["NO_COLOR": "1", "CLICOLOR_FORCE": "1"], true, false),
      (["CLICOLOR": "0", "CLICOLOR_FORCE": "1"], true, false),
    ]
  )
  func colorEnvironmentUsesDocumentedPrecedence(
    environment: [String: String],
    outputIsTerminal: Bool,
    expectedColor: Bool
  ) {
    let context = CLITerminalContext.resolve(
      environment: environment,
      outputIsTerminal: outputIsTerminal,
      detectedWidth: 80
    )

    #expect(context.colorEnabled == expectedColor)
  }
}
