import Foundation
import UsageCore

@main
struct LLMUsageCLI {
    static func main() async {
        do {
            let options = try UsageCLI.Options(arguments: Array(CommandLine.arguments.dropFirst()))
            if options.help {
                print(UsageCLI.help)
                return
            }
            guard let profiles = Profiles.readForReload() else {
                FileHandle.standardError.write(Data("Cannot parse profiles.json.\n".utf8))
                exit(2)
            }
            let report = await UsageCLI.collect(profiles: profiles)
            print(try options.json ? report.json() : report.table())
            if report.hasErrors { exit(1) }
        } catch {
            FileHandle.standardError.write(Data("Invalid arguments or output. Use llm-usage --help.\n".utf8))
            exit(2)
        }
    }
}
