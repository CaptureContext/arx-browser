extension IdentifiedArray {
	/// Resolves an optional reference, such as a space's selected tab, without unwrapping at each call site.
	@inlinable
	public subscript(id id: ID?) -> Element? {
		id.flatMap { self[id: $0] }
	}
}
