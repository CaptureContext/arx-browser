import Foundation

public enum ChromiumNewContentsDisposition: Int, Equatable, Sendable {
	case foregroundTab = 1
	case backgroundTab = 2
	case window = 3
	case popup = 4
}
