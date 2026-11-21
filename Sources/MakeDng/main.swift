import Foundation
import TraincullCore

// Writes the made-up DNG (`SyntheticDng`) to the path given, for the automated build's
// launch check: Apple's decoder can develop it, so the RAW panel can be driven for real.
let arguments = CommandLine.arguments
guard arguments.count == 2 || arguments.count == 4 else {
    FileHandle.standardError.write(Data("usage: make-dng <file.dng> [width height]\n".utf8))
    exit(2)
}
let bytes = arguments.count == 4 ? SyntheticDng.make(width: Int(arguments[2]) ?? 1536, height: Int(arguments[3]) ?? 1024) : SyntheticDng.make()
try Data(bytes).write(to: URL(fileURLWithPath: arguments[1]))
print("wrote \(arguments[1]) (\(bytes.count) bytes)")
