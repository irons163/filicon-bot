import Foundation
import FiliconUpdater

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: FiliconUpdateHelper <install-plan.json>\n".utf8))
    exit(2)
}

do {
    let planURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let data = try Data(contentsOf: planURL)
    let plan = try JSONDecoder().decode(PreparedUpdateInstall.self, from: data)
    try PreparedUpdateApplier.apply(plan)
} catch {
    FileHandle.standardError.write(Data("Filicon update failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
