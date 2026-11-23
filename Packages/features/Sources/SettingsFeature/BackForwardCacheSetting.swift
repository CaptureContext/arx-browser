import Foundation
import _ComposableArchitecture

/// How many pages each tab keeps ready for an instant Back and Forward (DEV-943), from
/// Settings › Advanced › Memory.
///
/// The engine reads it once at launch, so a change applies the next time Arx opens. It's kept
/// in Arx's defaults under the name of the engine's feature flag, which the environment can
/// override (`ARX_BACK_FORWARD_CACHE_SIZE`), and not in the workspace: it tunes this Mac's
/// engine rather than describing anyone's browsing. The engine's `engine_bridge.mm` keeps the
/// same default and maximum.
public enum BackForwardCachePages {
	/// Back, Back again and Forward, where nearly every cache hit happens.
	public static let defaultCount: Int = 3

	/// 0 turns the cache off; Chrome keeps 6.
	public static let counts: ClosedRange<Int> = 0 ... 6

	/// The defaults key and environment variable the engine reads at launch.
	public static let featureFlag: String = "ARX_BACK_FORWARD_CACHE_SIZE"
}

extension SharedKey where Self == AppStorageKey<Int>.Default {
	/// Settings › Advanced › Memory › Pages kept for Back and Forward (DEV-943).
	public static var backForwardCachePages: Self {
		Self[.appStorage(BackForwardCachePages.featureFlag), default: BackForwardCachePages.defaultCount]
	}
}
