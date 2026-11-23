import AppKit
import BrowserCaptureClient
import BrowserCore
import BrowserDownloadsClient
import BrowserEngineClient
import BrowserExtensionsClient
import BrowserMediaClient
import BrowserPageInspectionClient
import BrowserPageInteractionClient
import BrowserPageWaitClient
import BrowserSurfaceClient
import BrowserSiteIconClient
import ChromiumEngine

extension ChromiumBrowserEngine {
	// MARK: - Automation

	/// Available for explicit composition only after the ABI5 native fixture gate passes.
	public var capture: BrowserCaptureClient {
		ChromiumCaptureAdapter.client(
			fullDocumentIsAvailable: { [runtime] in runtime.supportsDocumentCapture },
			captureDocument: { [self] id, limits in
				guard let page = pages[id]
				else { throw ChromiumCaptureFailure.staleDocument }

				return try await runtime.capture(page, limits: limits, fullDocument: true)
			},
			wholePageIsAvailable: { [runtime] in runtime.supportsWholePageCapture },
			captureWholePage: { [self] id, limits in
				guard let page = pages[id]
				else { throw ChromiumCaptureFailure.staleDocument }

				return try await runtime.captureWholePage(page, limits: limits)
			},
			isAvailable: { [self] in runtime.state == .running },
			revision: { [self] id in pages[id] == nil ? nil : sessionRevisions[id] },
			documentRevision: { [self] id in pages[id].flatMap(runtime.documentRevision) },
			isVisible: { [self] in isVisibleForCapture($0) },
			ordinaryProfileID: { [self] id in
				guard pages[id]?.isPrivate == false else { return nil }
				return pageProfiles[id]
			},
			offscreenIsAvailable: { [runtime] in runtime.supportsOffscreenCapture },
			captureOffscreen: { [self] id, limits in
				guard let page = pages[id]
				else { throw ChromiumCaptureFailure.staleDocument }

				return try await runtime.capture(page, limits: limits, offscreen: true)
			},
			pdfIsAvailable: { [runtime] in runtime.supportsPDF },
			pdf: { [self] id, kind, maximumBytes, allowsPrivate in
				guard let page = pages[id]
				else { throw ChromiumPDFFailure.staleDocument }

				return try await runtime.pdf(
					page,
					kind: kind,
					maximumBytes: maximumBytes,
					allowsPrivate: allowsPrivate
				)
			},
			// Capture Area scrolls the page from Arx's translation world, an isolated world (DEV-1208).
			scrollIsAvailable: { [runtime] in runtime.supportsTranslationScripts },
			pageZoom: { [self] id in pages[id].flatMap { runtime.pageZoom($0) } },
			evaluateScroll: { [self] id, script in
				guard let page = pages[id]
				else { throw ChromiumDeveloperFailure.staleDocument }

				return try await runtime.evaluateTranslationScript(
					page,
					source: script,
					maximumBytes: 256,
					timeoutMilliseconds: 1_000
				)
			},
			capture: { [self] id, limits in
				guard let page = pages[id]
				else { throw ChromiumCaptureFailure.staleDocument }

				return try await runtime.capture(page, limits: limits)
			}
		)
	}

	/// Stable before runtime startup. Reads only the exact loaded ordinary session.
	public var inspection: BrowserPageInspectionClient {
		ChromiumInspectionAdapter.client(
			isAvailable: { [runtime] in
				runtime.state == .running && runtime.supportsInspection
			},
			sourceIsCurrent: { [weak self] source in
				self?.inspectionPage(for: source) != nil
			},
			inspect: { [weak self] source, frameID, limits in
				guard
					let self,
					let page = self.inspectionPage(for: source)
				else { throw ChromiumInspectionFailure.staleReference }

				return try await self.runtime.inspect(page, scope: source.scopeID, frameID: frameID, limits: limits)
			},
			documentIsCurrent: { [weak self] snapshot, source in
				guard
					let self,
					let page = self.inspectionPage(for: source)
				else { return false }

				return self.runtime.inspectionDocumentIsCurrent(
					snapshot,
					on: page,
					scope: source.scopeID
				)
			},
			revokeScope: { [runtime] in runtime.revokeInspectionScope($0) }
		)
	}

	/// Retained before startup; every activation resolves the original ordinary session again.
	public var interaction: BrowserPageInteractionClient {
		var client = ChromiumInteractionAdapter.client(
			isAvailable: { [runtime] in
				runtime.state == .running && runtime.supportsReferenceClick
			},
			sourceIsCurrent: { [weak self] source in
				self?.inspectionPage(for: source) != nil
			},
			click: { [weak self] request, source, authorize in
				guard
					let self,
					let page = self.inspectionPage(for: source)
				else {
					return .init(
						operationID: request.operationID,
						disposition: .notDispatched,
						failure: .staleReference
					)
				}

				return await self.runtime.clickInspectionReference(
					request,
					on: page,
					scope: source.scopeID,
					authorize: authorize
				)
			}
		)

		client.formIsAvailable = { [runtime] in
			runtime.state == .running && runtime.supportsReferenceFormActions
		}
		client.keypressIsAvailable = { [runtime] in
			runtime.state == .running && runtime.supportsReferenceKeypress
		}
		client.formAuthorized = ChromiumFormAdapter.action(
			isAvailable: client.formIsAvailable,
			keypressIsAvailable: client.keypressIsAvailable,
			sourceIsCurrent: { [weak self] source in
				self?.inspectionPage(for: source) != nil
			},
			perform: { [weak self] request, source, authorize in
				guard
					let self,
					let page = self.inspectionPage(for: source)
				else {
					return .init(
						operationID: request.operationID,
						disposition: .notDispatched,
						failure: .staleReference
					)
				}

				return await self.runtime.performInspectionFormAction(
					request,
					on: page,
					scope: source.scopeID,
					authorize: authorize
				)
			},
			upload: { [weak self] request, source, authorize in
				guard let page = self?.inspectionPage(for: source) else {
					return .init(operationID: request.operationID, disposition: .notDispatched, failure: .staleReference)
				}
				return ChromiumUploadAdapter.answer(request, page: page, authorize: authorize)
			}
		)

		client.scrollIsAvailable = { [runtime] in
			runtime.state == .running && runtime.supportsReferenceScroll
		}
		client.scrollAuthorized = ChromiumScrollAdapter.action(
			isAvailable: client.scrollIsAvailable,
			sourceIsCurrent: { [weak self] source in
				self?.inspectionPage(for: source) != nil
			},
			perform: { [weak self] request, source, authorize in
				guard
					let self,
					let page = self.inspectionPage(for: source)
				else {
					return .init(
						operationID: request.operationID,
						disposition: .notDispatched,
						failure: .staleReference
					)
				}

				return await self.runtime.scrollInspectionReference(
					request,
					on: page,
					scope: source.scopeID,
					authorize: authorize
				)
			}
		)
		return client
	}

	private func inspectionPage(for source: PageInspectionSource) -> ChromiumPage? {
		guard
			runtime.state == .running,
			let page = pages[source.tabID],
			!page.isPrivate,
			!page.isClosed,
			pageProfiles[source.tabID] == source.profileID,
			sessionRevisions[source.tabID] == source.sessionRevision,
			source.documentRevision > 0,
			runtime.documentRevision(for: page) == source.documentRevision
		else { return nil }

		return page
	}

	public var pageWait: BrowserPageWaitClient {
		ChromiumWaitAdapter.client(
			isAvailable: { [weak self] in
				guard let self else { return false }

				return runtime.state == .running
				&& runtime.supportsAuthorizedClosing
			},
			capture: { [weak self] target in
				guard
					let self,
					let page = pages[target.tabID],
					!page.isPrivate,
					!page.isClosed,
					pageProfiles[target.tabID] == target.profileID,
					let liveEpoch = runtime.documentRevision(for: page)
				else { throw AutomationFailure.staleTarget }

				guard runtime.publishedDocumentRevision(for: page) == liveEpoch
				else { throw AutomationFailure.notReady }

				guard liveEpoch == target.documentRevision
				else { throw AutomationFailure.staleTarget }

				let source = PageWaitSource(target: target, pageID: page.identifier)

				return .init(
					source: source,
					read: { [weak self, page] in
						guard
							let self,
							pages[target.tabID] === page,
							waitSourceIsCurrent(source),
							let snapshot = client.snapshot(target.tabID),
							let url = snapshot.navigation.url,
							url.hasWebScheme,
							url.host != nil
						else { throw AutomationFailure.staleTarget }

						return snapshot
					},
					subscribe: { [weak self] in
						guard let self else {
							return .init(events: .finished, cancel: {})
						}

						return waitSubscription(target.tabID)
					}
				)
			},
			sourceIsCurrent: { [weak self] in self?.waitSourceIsCurrent($0) == true }
		)
	}

	private func waitSourceIsCurrent(_ source: PageWaitSource) -> Bool {
		let target = source.target

		guard
			runtime.state == .running,
			let page = pages[target.tabID],
			!page.isPrivate,
			!page.isClosed,
			page.identifier == source.pageID,
			pageProfiles[target.tabID] == target.profileID,
			target.documentRevision > 0,
			runtime.documentRevision(for: page) == target.documentRevision,
			runtime.publishedDocumentRevision(for: page) == target.documentRevision
		else { return false }

		return true
	}

#if DEBUG
	/// Whether Hide Element would start on the tab's page now: its profile's content blocker is
	/// running and filters the page's site. A new profile's blocker restarts once soon after its
	/// first launch, and until it's back the command does nothing; the hand-check smoke waits
	/// for this before pressing it.
	public func canHideElementsFixture(_ tabID: Tab.ID) -> Bool {
		pages[tabID].map { runtime.canHideElements(on: $0) } ?? false
	}

	/// Owned app acceptance uses the actual source view for native event delivery.
	public func contentHostFixtureView(_ tabID: Tab.ID) -> NSView? {
		guard
			enableContentHosting,
			let page = pages[tabID],
			let host = hosts[tabID]?.view,
			page.view.superview === host,
			host.window != nil
		else { return nil }

		return page.view
	}
#endif

	/// ABI42: the tab's DevTools view while it's docked in the page's host (DEV-733).
	public func dockedDeveloperToolsView(_ id: Tab.ID) -> NSView? {
		dockedDeveloperTools[id]
	}

	/// The live native view hosting a session, for host layout such as headless viewports.
	public func hostView(_ id: Tab.ID) -> NSView? {
		pages[id]?.view
	}

	internal static func hoveredLinkTarget(_ target: ChromiumHoveredLink.Target) -> BrowserHoveredLink.Target {
		switch target {
		case .unknown: .unknown
		case .mainFrame: .mainFrame
		case .subframe: .subframe
		case .newContext: .newContext
		}
	}

	/// DEV-1118: pages report hovered links (``onLinkHover``) only while the app shows the link
	/// status, since each report runs a script in the page's frames.
	public func setLinkHoverReports(_ enabled: Bool) {
		runtime.setLinkHoverReports(enabled)
	}

	/// DEV-1111: the page view a tab's link status shows over, while the page is open.
	public func linkStatusView(_ id: Tab.ID) -> NSView? {
		guard let page = pages[id], !page.isClosed else { return nil }
		return page.view
	}
}
