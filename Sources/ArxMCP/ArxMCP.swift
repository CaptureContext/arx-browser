import ArxCommandLine
import Foundation

@main
internal enum ArxMCP {
	internal static func main() async {
		exit(await ArxCommandLine.main())
	}
}
