import Foundation
import Testing
import FiliconAgents
@testable import Filicon

@Suite("Built-in pet avatars")
struct PetAvatarTests {
    @MainActor
    @Test(arguments: AgentPetAvatar.allCases)
    func everyPetHasADecodableIdleFrame(_ pet: AgentPetAvatar) throws {
        let image = try #require(PetAvatarImages.image(for: pet))
        #expect(image.width == 192)
        #expect(image.height == 208)
        #expect(PetAvatarImages.image(for: pet) === image)
    }

    @Test(arguments: AgentPetAvatar.allCases)
    func selectionSurvivesPersistence(_ pet: AgentPetAvatar) throws {
        let avatar = AgentAvatar.pet(pet, shape: .hexagon)
        let data = try JSONEncoder().encode(avatar)
        let restored = try JSONDecoder().decode(AgentAvatar.self, from: data)
        #expect(restored == avatar)
        #expect(restored.imageRelativePath == nil)
    }

    @Test func legacyAvatarsWithoutPetIDStillDecode() throws {
        let character = Data(##"{"kind":"character","character":"AB","colorHex":"#5B6CFF","shape":"circle"}"##.utf8)
        let decoded = try JSONDecoder().decode(AgentAvatar.self, from: character)
        #expect(decoded.kind == .character)
        #expect(decoded.petID == nil)
        #expect(decoded.character == "AB")
        let image = AgentAvatar.image(hash: "existing-hash", relativePath: "existing.png")
        let restored = try JSONDecoder().decode(AgentAvatar.self, from: JSONEncoder().encode(image))
        #expect(restored == image)
    }
}
