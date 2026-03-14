import ArgumentParser

struct Greet: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Greet someone by name."
    )

    @OptionGroup var options: Options

    @Argument(help: "The name to greet.")
    var name: String

    @Option(name: .shortAndLong, help: "The greeting to use.")
    var greeting: String = "Hello"

    func run() throws {
        if options.verbose {
            print("[verbose] greeting=\(greeting), name=\(name)", to: &StandardError.shared)
        }
        print("\(greeting), \(name)!")
    }
}

/// Helper to write to stderr
struct StandardError: TextOutputStream {
    static var shared = StandardError()
    mutating func write(_ string: String) {
        FileHandle.standardError.write(Data(string.utf8))
    }
}
