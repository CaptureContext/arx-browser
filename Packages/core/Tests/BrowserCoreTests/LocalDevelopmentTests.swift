import BrowserCore
import Foundation
import Testing

internal struct LocalDevelopmentTests {
	@Test(arguments: [
		"http://localhost:3000",
		"https://localhost",
		"http://app.localhost:5173/path",
		"http://127.0.0.1:8080",
		"http://[::1]:4000",
		"https://shop.test",
		"http://10.0.0.5:3000",
		"http://172.20.1.2:8000",
		"http://192.168.1.10:5000",
	])
	internal func localPagesGetTheHeader(_ address: String) async throws {
		#expect(LocalDevelopment.isLocal(URL(string: address)))
	}

	@Test(arguments: [
		"https://example.com",
		"http://192.168.1.10",
		"http://172.32.0.1:3000",
		"http://8.8.8.8:53",
		"file:///Users/me/index.html",
		"about:blank",
		"https://test",
		"ftp://localhost:21",
	])
	internal func otherPagesDont(_ address: String) async throws {
		#expect(!LocalDevelopment.isLocal(URL(string: address)))
	}

	@Test
	internal func noAddressIsntLocal() async throws {
		#expect(!LocalDevelopment.isLocal(nil))
	}
}

/// Which tabs the sidebar marks with construction tape, and the host it shows (DEV-786).
internal struct LocalNetworkTests {
	@Test(arguments: [
		"http://localhost:3000",
		"https://localhost",
		"http://app.localhost:5173/path",
		"http://127.0.0.1:8080",
		"http://[::1]:4000",
		"https://shop.test",
		"http://printer.local",
		"http://studio.local:8080",
		"http://10.0.0.5",
		"http://172.16.0.1",
		"http://172.31.255.254:9000",
		"http://192.168.1.1",
		"http://LOCALHOST.:3000",
	])
	internal func localNetworkPages(_ address: String) async throws {
		#expect(LocalDevelopment.isLocalNetwork(URL(string: address)))
	}

	@Test(arguments: [
		"https://example.com",
		"https://local",
		"https://example.local.com",
		"http://172.15.0.1",
		"http://172.32.0.1:3000",
		"http://192.169.1.1",
		"http://11.0.0.1",
		"http://8.8.8.8:53",
		"http://192.168.1",
		"file:///Users/me/index.html",
		"about:blank",
		"ftp://localhost:21",
	])
	internal func otherPages(_ address: String) async throws {
		#expect(!LocalDevelopment.isLocalNetwork(URL(string: address)))
	}

	@Test(arguments: [
		("http://localhost:3000/dashboard", "localhost:3000"),
		("https://localhost", "localhost"),
		("http://[::1]:4000", "[::1]:4000"),
		("http://127.0.0.1:8080", "127.0.0.1:8080"),
		("http://Printer.Local", "printer.local"),
		("http://192.168.1.1", "192.168.1.1"),
		("http://shop.test.:8443", "shop.test:8443"),
	])
	internal func hostLabel(_ address: String, _ label: String) async throws {
		#expect(LocalDevelopment.hostLabel(URL(string: address)) == label)
	}

	@Test
	internal func otherPagesHaveNoHostLabel() async throws {
		#expect(LocalDevelopment.hostLabel(URL(string: "https://example.com:8080")) == nil)
		#expect(LocalDevelopment.hostLabel(nil) == nil)
	}
}
