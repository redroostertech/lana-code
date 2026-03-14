import ArgumentParser

@main
struct MyCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mycli",
        abstract: "A command-line tool.",
        version: "0.1.0",
        subcommands: [Greet.self, Info.self],
        defaultSubcommand: nil
    )
}

struct Options: ParsableArguments {
    @Flag(name: .shortAndLong, help: "Enable verbose output.")
    var verbose: Bool = false
}

struct Info: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show application information."
    )

    @OptionGroup var options: Options

    func run() throws {
        print("mycli v\(MyCLI.configuration.version)")
        print("Verbose: \(options.verbose)")
        #if os(macOS)
        print("Platform: macOS")
        #elseif os(Linux)
        print("Platform: Linux")
        #endif
    }
}
