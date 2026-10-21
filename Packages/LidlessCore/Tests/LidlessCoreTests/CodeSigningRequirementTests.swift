import Testing
@testable import LidlessCore

@Suite struct CodeSigningRequirementTests {
    @Test func requirementForValidTeam() {
        #expect(CodeSigningRequirement.requirement(identifier: HelperIDs.app, teamID: "6H45P75YYV")
            == #"anchor apple generic and identifier "io.github.aesarva.Lidless" and certificate leaf[subject.OU] = "6H45P75YYV""#)
    }

    @Test func requirementWithoutTeamIsNil() {
        #expect(CodeSigningRequirement.requirement(identifier: HelperIDs.app, teamID: nil) == nil)
    }

    @Test(arguments: ["6H45P75YY", "6h45p75yyv", "6H45P75YYV\" or true", ""])
    func malformedTeamRejected(_ team: String) {
        #expect(CodeSigningRequirement.validTeamID(team) == nil)
        #expect(CodeSigningRequirement.requirement(identifier: HelperIDs.app, teamID: team) == nil)
    }

    @Test func testRunnerHasNoTeam() {
        #expect(CodeSigningRequirement.ownTeamID() == nil)
    }
}
