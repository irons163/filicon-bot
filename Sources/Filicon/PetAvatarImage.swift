import SwiftUI
import ImageIO
import FiliconAgents

/// The original sprite sheets remain unmodified. Avatars display the first
/// idle frame (192 × 208) rather than animating inside lists and chat rows.
@MainActor
enum PetAvatarImages {
    private static var frames: [AgentPetAvatar: CGImage] = [:]

    static func image(for pet: AgentPetAvatar) -> CGImage? {
        if let frame = frames[pet] { return frame }
        let urls = FiliconLocalization.resourceRoots().flatMap { root in
            [root.appending(path: "PetAvatars/\(pet.rawValue).webp"),
             root.appending(path: "\(pet.rawValue).webp")]
        }
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  sheet.width == 1536, sheet.height == 2288,
                  let frame = sheet.cropping(to: CGRect(x: 0, y: 0, width: 192, height: 208)) else { continue }
            frames[pet] = frame
            return frame
        }
        return nil
    }
}

struct PetAvatarImage: View {
    let pet: AgentPetAvatar
    var body: some View {
        if let image = PetAvatarImages.image(for: pet) {
            Image(decorative: image, scale: 1).resizable().interpolation(.none).scaledToFit()
                .accessibilityLabel(pet.name)
        } else {
            Image(systemName: "pawprint.fill").resizable().scaledToFit()
                .accessibilityLabel(pet.name)
        }
    }
}
