import Foundation

@main
enum ParakeetSmokeTestMain {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let audioPath = parseAudioPath(from: arguments) else {
            fputs(
                """
                usage: ParakeetSmokeTest --audio <absolute-path-to-wav>

                Example:
                  ./scripts/run-parakeet-smoke.sh

                """,
                stderr
            )
            exit(SmokeTestExitCode.usageError.rawValue)
        }

        let code = await ParakeetSmokeTestRunner.run(audioPath: audioPath)
        exit(code.rawValue)
    }

    private static func parseAudioPath(from arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--audio") else {
            return nil
        }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else {
            return nil
        }
        let value = arguments[valueIndex]
        guard !value.isEmpty, !value.hasPrefix("-") else {
            return nil
        }
        return value
    }
}
