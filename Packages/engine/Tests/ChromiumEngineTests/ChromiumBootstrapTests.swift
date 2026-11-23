import ChromiumBootstrap
import Darwin
import Testing

internal struct ChromiumBootstrapTests {

	@Test
	internal func observationPreservesExistingAllocationAndZone() throws {
		let allocation = try #require(malloc(64))
		defer { free(allocation) }
		let zone = malloc_zone_from_ptr(allocation)
		allocation.storeBytes(of: UInt64(0x12345678), as: UInt64.self)
		let first = ArxReadBootstrapState()
		let second = ArxReadBootstrapState()

		#expect(first.thread_status == KERN_SUCCESS)
		#expect(first.zone_status == KERN_SUCCESS)
		#expect(first.thread_count > 0)
		#expect(first.zone_count > 0)
		#expect(second.zone_count == first.zone_count)
		#expect(first.default_zone_name.0 != 0)
		#expect(malloc_zone_from_ptr(allocation) == zone)
		#expect(allocation.load(as: UInt64.self) == 0x12345678)
	}
}
