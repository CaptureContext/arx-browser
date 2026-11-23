#if DEBUG
@testable import AppFeature
import Foundation
import Testing
import UserNotifications

/// The web-notifications ticket's smoke (DEV-885): what it prints for the runner, and how it
/// matches the site's reopened tab.
internal struct NotificationSmokeTests {
	@Test
	internal func theDeliveryLineIsTheRunnersJSON() throws {
		let delivery = NotificationSmoke.Delivery(
			title: "Arx notification smoke 1234abcd",
			subtitle: "127.0.0.1:48123",
			body: "Arx notification smoke body",
			attachments: 1,
			origins: ["http://127.0.0.1:48123"]
		)
		let prefix = "ARX_NOTIFICATION_SMOKE_DELIVERED "
		#expect(delivery.resultLine.hasPrefix(prefix))
		#expect(!delivery.resultLine.contains("\n"))

		let json = Data(delivery.resultLine.dropFirst(prefix.count).utf8)
		#expect(try JSONDecoder().decode(NotificationSmoke.Delivery.self, from: json) == delivery)
		#expect(delivery.resultLine.contains(#""subtitle":"127.0.0.1:48123""#))
	}

	@Test
	internal func authorizationNamesAreTheRunnersWords() {
		#expect(NotificationSmoke.authorizationName(.authorized) == "authorized")
		#expect(NotificationSmoke.authorizationName(.notDetermined) == "notDetermined")
		#expect(NotificationSmoke.authorizationName(.denied) == "denied")
		#expect(NotificationSmoke.authorizationName(.provisional) == "provisional")
	}

	@Test
	internal func theReopenedTabMatchesTheNotificationsOrigin() throws {
		let origin = try #require(URL(string: "http://127.0.0.1:48123"))
		#expect(NotificationSmoke.isSameOrigin(URL(string: "http://127.0.0.1:48123/"), origin))
		#expect(NotificationSmoke.isSameOrigin(URL(string: "HTTP://127.0.0.1:48123/page?fire=1"), origin))
		#expect(!NotificationSmoke.isSameOrigin(URL(string: "http://127.0.0.1:48124/"), origin))
		#expect(!NotificationSmoke.isSameOrigin(URL(string: "https://127.0.0.1:48123/"), origin))
		#expect(!NotificationSmoke.isSameOrigin(nil, origin))

		let site = try #require(URL(string: "https://example.com"))
		#expect(NotificationSmoke.isSameOrigin(URL(string: "https://example.com:443/a"), site))
	}

	@Test
	internal func itRunsOnlyWhenAskedWithADisposableProfile() {
		#expect(NotificationSmoke.isRequested(environment: [
			"ARX_NOTIFICATION_SMOKE": "1",
			"ARX_ENGINE_PROFILE": "/tmp/profile",
		]))
		#expect(!NotificationSmoke.isRequested(environment: ["ARX_NOTIFICATION_SMOKE": "1"]))
		#expect(!NotificationSmoke.isRequested(environment: ["ARX_ENGINE_PROFILE": "/tmp/profile"]))
	}
}
#endif
