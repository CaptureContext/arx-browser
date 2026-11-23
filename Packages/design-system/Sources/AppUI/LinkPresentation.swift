import BrowserCore

public func linkErrorMessage(_ error: LinkTransformationError) -> String {
	switch error {
	case .invalidURL: String.localized(.appUI.links.invalidURL)
	case .unsupportedScheme: String.localized(.appUI.links.unsupportedScheme)
	case .credentialsNotAllowed: String.localized(.appUI.links.credentials)
	case .nonstandardPort: String.localized(.appUI.links.nonstandardPort)
	case .invalidHost: String.localized(.appUI.links.invalidHost)
	case .invalidRule: String.localized(.appUI.links.invalidRule)
	case .invalidTemplate: String.localized(.appUI.links.invalidTemplate)
	case .missingPreferredRule: String.localized(.appUI.links.missingRule)
	case .duplicateRule: String.localized(.appUI.links.duplicateRule)
	}
}

public func linkTransformationMessage(_ outcome: LinkTransformation.Outcome) -> String {
	switch outcome {
	case .original: String.localized(.appUI.links.original)
	case let .cleaned(names): String.localized(.appUI.links.removed(names.formatted(.list(type: .and))))
	case .sensitiveParametersPreserved: String.localized(.appUI.links.sensitive)
	case .noTrackingParameters: String.localized(.appUI.links.noTrackers)
	case let .proxy(rule): String.localized(.appUI.links.matched(rule.name))
	case .noMatchingRule: String.localized(.appUI.links.noMatch)
	case let .preserved(error): String.localized(.appUI.links.preserved(linkErrorMessage(error)))
	}
}
