# StyleCheckerTests

Tests StyleChecker with Swift Testing, on the swift-style guide's own correct and incorrect examples, wrapped in functions so they parse. Each rule has a test that the guide's correct shapes pass and its wrong shapes report on the expected lines; `leavesJudgementCallsAlone` keeps the examples the guide rejects for length or balance unreported. Output tests cover the plain and GitHub formats. Nothing outside the process is needed.
