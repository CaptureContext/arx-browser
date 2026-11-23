import FairPlayPlayer

/// Arx's FairPlay helper app (DEV-1144). The app starts it from `Contents/Helpers`; everything it
/// does lives in the FairPlayPlayer package target.
@main
internal enum ArxFairPlay {
	@MainActor
	internal static func main() {
		FairPlayHelperProcess.run()
	}
}
