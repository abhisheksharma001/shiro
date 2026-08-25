import XCTest
@testable import Shiro

/// Focused tests for `SkillsRegistry.Skill` pure logic: template filling
/// and argument parsing. No network, no database.
@MainActor
final class SkillsTemplateTests: XCTestCase {

    // MARK: - Fixtures

    private func makeSkill(parameters: [SkillsRegistry.SkillParameter],
                           template: String = "Research: {{topic}}") -> SkillsRegistry.Skill {
        SkillsRegistry.Skill(
            name: "research",
            description: "Deep research",
            trigger: "/research",
            systemPrompt: "You are a researcher.",
            promptTemplate: template,
            parameters: parameters,
            model: nil,
            maxTurns: nil,
            allowedTools: nil,
            enabled: true
        )
    }

    private func param(_ name: String, required: Bool = true,
                       defaultValue: String? = nil) -> SkillsRegistry.SkillParameter {
        SkillsRegistry.SkillParameter(name: name, description: name, required: required,
                                      defaultValue: defaultValue)
    }

    // MARK: - fillTemplate

    func testFillTemplateSubstitutesProvidedArgs() {
        let skill = makeSkill(parameters: [param("topic")])
        XCTAssertEqual(skill.fillTemplate(args: ["topic": "Swift concurrency"]),
                       "Research: Swift concurrency")
    }

    func testFillTemplateLeavesUnknownPlaceholdersIntact() {
        let skill = makeSkill(parameters: [], template: "Hello {{name}}, bye {{missing}}")
        XCTAssertEqual(skill.fillTemplate(args: ["name": "Shiro"]),
                       "Hello Shiro, bye {{missing}}")
    }

    // MARK: - parseArgs

    func testParseArgsSingleParamTakesWholeString() {
        let skill = makeSkill(parameters: [param("topic")])
        XCTAssertEqual(skill.parseArgs("  Swift concurrency  "),
                       ["topic": "Swift concurrency"])
    }

    func testParseArgsMultiParamFillsDefaultsForMissing() {
        let skill = makeSkill(
            parameters: [param("depth", defaultValue: "standard"), param("format")],
            template: "{{depth}} {{format}}"
        )
        let args = skill.parseArgs("depth=deep format=md")
        XCTAssertEqual(args["depth"], "deep")
        XCTAssertEqual(args["format"], "md")

        let withDefaults = skill.parseArgs("format=md")
        XCTAssertEqual(withDefaults["depth"], "standard")
        XCTAssertEqual(withDefaults["format"], "md")
    }
}
