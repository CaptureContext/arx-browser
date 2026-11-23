"""A page that can't play its protected media reaches Arx, and a likely bot check doesn't
(DEV-877, DEV-1144, DEV-1205, DEV-1211)."""

from pathlib import Path
import tempfile
import unittest

from Scripts.engine import protected_media_overlay as overlay


def prepare(root):
    for relative, old, _ in overlay.patches():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a") as stream:
            stream.write(old + "\n")


def prepare_upstream(root):
    """`prepare`, plus the upstream lines earlier versions inserted text at and this one doesn't."""
    prepare(root)
    for relative, line in ((overlay.SOURCE, overlay.FIRST_QUESTION_ANCHOR),
                           (overlay.CLIENT, overlay.DEV_1144_CLIENT_ANCHOR)):
        with (root / relative).open("a") as stream:
            stream.write(line + "\n")


def snapshot(root):
    return {path.relative_to(root): path.read_bytes() for path in root.rglob("*") if path.is_file()}


def downgrade(root, upgrades):
    """Turns a step's text back into the text before it, its last change first."""
    for relative, previous, current in reversed(upgrades):
        path = root / relative
        text = path.read_text()
        assert text.count(current) == 1, (relative, current[:80])
        path.write_text(text.replace(current, previous, 1))


def remove_patches(root, patches):
    """Takes out text a version added at upstream lines: each (relative, inserted, line)."""
    for relative, after, before in patches:
        path = root / relative
        text = path.read_text()
        assert text.count(after) == 1, (relative, after[:80])
        path.write_text(text.replace(after, before, 1))


def section(text, start, end):
    return text[text.index(start):text.index(end, text.index(start))]


class ProtectedMediaOverlayTests(unittest.TestCase):
    def test_apply_is_repeatable_and_hooks_the_observer(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            overlay.apply(root)
            first = snapshot(root)
            overlay.apply(root)
            self.assertEqual(first, snapshot(root))

            source = (root / overlay.SOURCE).read_text()
            self.assertIn('#include "chrome/browser/arx/protected_media_hooks.h"  // nogncheck', source)
            self.assertEqual(source.count("void arx::SetProtectedMediaObserver("), 1)
            # The setter is defined outside content's namespace; one place calls the observer.
            self.assertLess(source.index("void arx::SetProtectedMediaObserver("),
                            source.index("namespace content {"))
            self.assertEqual(source.count("g_arx_protected_media_observer(\n"), 1)

    def test_the_first_question_never_reports(self):
        # DEV-1211: with the Widevine answer off, a refusal follows the rule that answers it,
        # not the first question, which every bot check asks.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare_upstream(root)
            overlay.apply(root)
            source = (root / overlay.SOURCE).read_text()
            self.assertNotIn("the frame's first Encrypted Media Extensions request", source)
            self.assertIn(overlay.FIRST_QUESTION_ANCHOR + "\n", source)

    def test_failed_keys_are_recorded_on_their_document(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            overlay.apply(root)
            source = (root / overlay.SOURCE).read_text()
            report = section(source, "void arx::ReportProtectedMediaFailure(", "namespace content {")
            self.assertIn("content::KeySystemSupportImpl::GetOrCreateForCurrentDocument(frame)\n"
                          "        ->ArxNoteKeysFailed();", report)
            self.assertNotIn("g_arx_protected_media_observer", report)
            noted = section(source, "void KeySystemSupportImpl::ArxNoteKeysFailed() {",
                            "void KeySystemSupportImpl::ArxRejectionUnanswered() {")
            # Keys without media until a media element wants keys. Each failed creation reports
            # again: the app may not have shown the first (a background tab, another prompt).
            self.assertIn("arx_keys_failed_ = true;", noted)
            # Both guards clear: failed playback reported from media in an iframe since removed
            # mustn't keep a later failed creation, now keys without media, from reporting.
            self.assertIn("  arx_reported_playback_failure_ = false;\n"
                          "  arx_reported_keys_without_media_ = false;\n"
                          "  ArxReport(/*playback_failed=*/ArxPageMediaWantsKeys());", noted)
            header = (root / overlay.SUPPORT_HEADER).read_text()
            self.assertIn("  void ArxReportMediaWantsKeys() final;\n", header)
            self.assertIn("  void ArxNoteKeysFailed();\n", header)

    def test_media_that_wants_keys_turns_failed_keys_into_failed_playback(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            overlay.apply(root)
            source = (root / overlay.SOURCE).read_text()
            wants = section(source, "void KeySystemSupportImpl::ArxPageMediaWantsKeysNow() {",
                            "bool KeySystemSupportImpl::ArxPageMediaWantsKeys() {")
            self.assertIn("  if (arx_keys_failed_ || (arx_rejection_unanswered_ && !arx_granted_access_)) {\n"
                          "    ArxReport(/*playback_failed=*/true);", wants)
            self.assertIn("  ArxReportMediaWantsKeys();\n", (root / overlay.MOJOM).read_text())

    def test_media_in_a_same_origin_frame_of_the_page_counts(self):
        # A player may keep its video in an iframe and make its keys in the parent, or the other
        # way round: each document keeps its own state and reports, and media in any same-origin
        # document of the page counts for it.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            overlay.apply(root)
            source = (root / overlay.SOURCE).read_text()
            told = section(source, "void KeySystemSupportImpl::ArxReportMediaWantsKeys() {",
                           "void KeySystemSupportImpl::ArxPageMediaWantsKeysNow() {")
            self.assertIn("arx_media_wants_keys_ = true;", told)
            self.assertIn("render_frame_host().GetOutermostMainFrame()->ForEachRenderFrameHost(", told)
            self.assertIn("if (!frame->GetLastCommittedOrigin().IsSameOriginWith(origin)) {\n          return;", told)
            self.assertIn("KeySystemSupportImpl::GetForCurrentDocument(frame)", told)
            self.assertIn("support->ArxPageMediaWantsKeysNow();", told)
            # The reporting document's own state decides; GetForCurrentDocument never creates one.
            self.assertNotIn("GetOrCreateForCurrentDocument", told)
            asked = section(source, "bool KeySystemSupportImpl::ArxPageMediaWantsKeys() {",
                            "void KeySystemSupportImpl::ArxNoteKeysFailed() {")
            self.assertIn("if (arx_media_wants_keys_) {\n    return true;\n  }", asked)
            self.assertIn("wants || !frame->GetLastCommittedOrigin().IsSameOriginWith(origin)", asked)
            self.assertIn("wants = support && support->arx_media_wants_keys_;", asked)
            header = (root / overlay.SUPPORT_HEADER).read_text()
            self.assertIn("  bool ArxPageMediaWantsKeys();\n  void ArxPageMediaWantsKeysNow();\n", header)

    def test_a_refusal_waits_for_a_grant_and_needs_media_with_the_answer_off(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            overlay.apply(root)
            header = (root / overlay.SUPPORT_HEADER).read_text()
            self.assertIn("  base::OneShotTimer arx_rejection_timer_;", header)
            self.assertIn('#include "base/timer/timer.h"', header)

            source = (root / overlay.SOURCE).read_text()
            rejected = section(source, "void KeySystemSupportImpl::ArxReportAccessRejected() {",
                               "void KeySystemSupportImpl::ArxReportAccessGranted() {")
            # Both with the answer on and off, after a wait with no grant.
            self.assertNotIn("kArxWidevineAnswer", rejected)
            self.assertIn("FROM_HERE, base::Seconds(3),", rejected)
            self.assertNotIn("ArxReport(", rejected)
            # A refusal after an earlier wait ended (its report dropped while the document was in
            # the back/forward cache, say) waits again; reported reasons don't report twice.
            self.assertIn("if (arx_granted_access_ || arx_reported_playback_failure_ ||\n"
                          "      arx_rejection_timer_.IsRunning()) {\n    return;\n  }", rejected)
            self.assertNotIn("arx_rejection_unanswered_", rejected)
            granted = section(source, "void KeySystemSupportImpl::ArxReportAccessGranted() {",
                              "void KeySystemSupportImpl::ArxReportMediaWantsKeys() {")
            self.assertIn("arx_granted_access_ = true;\n  arx_rejection_timer_.Stop();", granted)
            unanswered = section(source, "void KeySystemSupportImpl::ArxRejectionUnanswered() {",
                                 "void KeySystemSupportImpl::ArxReport(bool playback_failed) {")
            # With the answer on, a document granted nothing can't play (DEV-1205); with it off,
            # only media that wants keys says so (DEV-1211).
            self.assertIn("if (arx_granted_access_) {\n    return;\n  }\n  arx_rejection_unanswered_ = true;",
                          unanswered)
            self.assertIn("ArxReport(/*playback_failed=*/\n"
                          "            base::FeatureList::IsEnabled(media::kArxWidevineAnswer) ||\n"
                          "            ArxPageMediaWantsKeys());", unanswered)
            # The report connection joins the first, which may still carry SetObserver when a
            # media element meets encrypted media before the page's first EME request: the
            # first is never replaced, or the page's key systems never arrive.
            bind = section(source, "  // Arx (DEV-1144, DEV-1211): the frame keeps a second connection",
                           "  // Only one receiver is allowed.")
            self.assertIn("  if (key_system_support_receiver_.is_bound()) {\n"
                          "    arx_key_system_support_receivers_.Add(this, std::move(receiver));\n"
                          "    return;\n  }\n", bind)
            self.assertNotIn("key_system_support_receiver_.reset();", source)
            self.assertIn("  mojo::ReceiverSet<KeySystemSupport> arx_key_system_support_receivers_;\n", header)
            self.assertIn('#include "mojo/public/cpp/bindings/receiver_set.h"', header)

    def test_each_reason_reports_once_and_failed_playback_ends_them(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            overlay.apply(root)
            source = (root / overlay.SOURCE).read_text()
            report = section(source, "void KeySystemSupportImpl::ArxReport(bool playback_failed) {",
                             "void KeySystemSupportImpl::SetObserver(")
            self.assertIn("if (arx_reported_playback_failure_ ||\n"
                          "      (!playback_failed && arx_reported_keys_without_media_)) {\n    return;\n  }",
                          report)
            self.assertIn("playback_failed ? arx::ProtectedMediaReason::kPlaybackFailed\n"
                          "                        : arx::ProtectedMediaReason::kKeysWithoutMedia", report)

    def test_a_document_that_isnt_shown_reports_nothing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            overlay.apply(root)
            source = (root / overlay.SOURCE).read_text()
            report = section(source, "void KeySystemSupportImpl::ArxReport(bool playback_failed) {",
                             "void KeySystemSupportImpl::SetObserver(")
            # The timer outlives a document in the back/forward cache: the check is when it
            # reports, before the reason counts as reported, so it may report once shown again.
            inactive = report.index("  if (!render_frame_host().IsActive()) {\n    return;\n  }\n")
            self.assertLess(report.index("if (arx_reported_playback_failure_ ||"), inactive)
            self.assertLess(inactive, report.index("arx_reported_playback_failure_ = true;"))
            self.assertLess(inactive, report.index("g_arx_protected_media_observer(\n"))
            # Checking never evicts the cached page.
            self.assertNotIn("IsInactiveAndDisallowActivation", source)
            # The reports go in before upstream's SetObserver, not after Arx's own text.
            anchors = [before for relative, before, after in overlay.patches()
                       if relative == overlay.SOURCE and "ArxReport(bool playback_failed)" in after]
            self.assertEqual(anchors, ["void KeySystemSupportImpl::SetObserver(\n"])

    def test_a_media_element_that_wants_keys_reports_it(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            overlay.apply(root)
            element = (root / overlay.MEDIA_ELEMENT).read_text()
            self.assertIn("static void ArxReportMediaWantsKeys(HTMLMediaElement& element) {", element)
            self.assertLess(element.index("static void ArxReportMediaWantsKeys("),
                            element.index(overlay.MEDIA_ELEMENT_REPORT_ANCHOR))
            # setMediaKeys with keys, not with null, which detaches them.
            self.assertIn("  this_element.is_attaching_media_keys_ = true;\n"
                          "  // Arx (DEV-1211): the page gives the element keys to play with.\n"
                          "  if (media_keys) {\n    ArxReportMediaWantsKeys(element);\n  }\n", element)
            # The encrypted event, and playback waiting for a key.
            self.assertIn("  GetSupplementable()->ScheduleEvent(event);\n"
                          "  // Arx (DEV-1211): the element met encrypted media.\n"
                          "  ArxReportMediaWantsKeys(*GetSupplementable());\n}\n", element)
            self.assertIn("  is_waiting_for_key_ = true;\n"
                          "  // Arx (DEV-1211): playback waits for a key.\n"
                          "  ArxReportMediaWantsKeys(*GetSupplementable());\n", element)
            for include in ("third_party/blink/public/platform/web_encrypted_media_client.h",
                            "third_party/blink/renderer/core/dom/document.h",
                            "third_party/blink/renderer/core/frame/local_dom_window.h"):
                self.assertIn('#include "' + include + '"', element)

            # The frame passes it on, on the connection its other reports use.
            self.assertIn("virtual void ArxReportMediaWantsKeys() {}", (root / overlay.PUBLIC_CLIENT).read_text())
            self.assertIn("  void ArxReportMediaWantsKeys() override;\n", (root / overlay.CLIENT_HEADER).read_text())
            self.assertIn("key_system_config_selector_.ArxReportMediaWantsKeys();", (root / overlay.CLIENT).read_text())
            selector = (root / overlay.SELECTOR_HEADER).read_text()
            self.assertIn("virtual void ArxReportMediaWantsKeys() {}", selector)
            self.assertIn("web_frame_delegate_->ArxReportMediaWantsKeys();", selector)
            factory = (root / overlay.MEDIA_FACTORY).read_text()
            delegate = section(factory, "  void ArxReportMediaWantsKeys() override {", "  ~LocalFrameDelegate()")
            self.assertIn("if (media::mojom::KeySystemSupport* support = ArxKeySystemSupport()) {\n"
                          "      support->ArxReportMediaWantsKeys();", delegate)

    def test_only_request_media_key_system_access_reports_a_refusal(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            with (root / overlay.CLIENT).open("a") as stream:
                stream.write(overlay.DEV_1144_CLIENT_ANCHOR + "\n")
            overlay.apply(root)
            # MediaCapabilities.decodingInfo goes through the same client: the client no longer
            # reports a refusal itself.
            client = (root / overlay.CLIENT).read_text()
            refused = client.index("request.RequestNotSupported(kUnsupportedKeySystemOrConfigMessage);")
            self.assertNotIn("ArxReportAccessRejected", client[refused:])
            self.assertEqual(client.count("key_system_config_selector_.ArxReportAccessRejected();"), 1)
            self.assertIn("void WebEncryptedMediaClientImpl::ArxReportAccessRefused(", client)

            request = (root / overlay.REQUEST_ACCESS).read_text()
            rejected = request.index("DOMExceptionCode::kNotSupportedError, error_message));")
            reported = request.index("media_client->ArxReportAccessRefused(KeySystem());")
            self.assertLess(rejected, reported)
            self.assertIn("virtual void ArxReportAccessRefused(const WebString& key_system) {}",
                          (root / overlay.PUBLIC_CLIENT).read_text())
            self.assertIn("void ArxReportAccessRefused(const WebString& key_system) override;",
                          (root / overlay.CLIENT_HEADER).read_text())

    def test_every_grant_of_a_protected_key_system_is_reported(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            overlay.apply(root)
            client = (root / overlay.CLIENT).read_text()
            granted = client.index("key_system_config_selector_.ArxReportAccessGranted();")
            self.assertLess(granted, client.index("  request.RequestSucceeded("))
            # Clear Key isn't protected media, under any of its names.
            self.assertIn("return !media::IsClearKey(name) && !media::IsExternalClearKey(name) &&\n"
                          '         name != "webkit-org.w3.clearkey";', client)
            self.assertIn("if (ArxIsProtectedKeySystem(request.KeySystem())) {", client)
            self.assertIn("if (ArxIsProtectedKeySystem(key_system)) {", client)

            selector = (root / overlay.SELECTOR_HEADER).read_text()
            # Other delegates, tests' included, needn't implement them.
            self.assertIn("virtual void ArxReportAccessRejected() {}", selector)
            self.assertIn("virtual void ArxReportAccessGranted() {}", selector)
            self.assertIn("web_frame_delegate_->ArxReportAccessRejected();", selector)
            self.assertIn("web_frame_delegate_->ArxReportAccessGranted();", selector)

            factory = (root / overlay.MEDIA_FACTORY).read_text()
            delegate = factory[factory.index("  void ArxReportAccessRejected() override {"):
                               factory.index("  ~LocalFrameDelegate() override = default;")]
            # One kept connection, so a refusal and a grant arrive in order.
            self.assertIn("support->ArxReportAccessRejected();", delegate)
            self.assertIn("support->ArxReportAccessGranted();", delegate)
            self.assertIn("arx_key_system_support_.BindNewPipeAndPassReceiver());", delegate)
            self.assertIn("  mojo::Remote<media::mojom::KeySystemSupport> arx_key_system_support_;\n};",
                          factory)
            self.assertIn('#include "mojo/public/cpp/bindings/remote.h"', factory)

    def test_trees_prepared_with_earlier_versions_are_upgraded(self):
        with tempfile.TemporaryDirectory() as fresh_directory:
            fresh = Path(fresh_directory)
            prepare_upstream(fresh)
            overlay.apply(fresh)

            # DEV-1205's tree: its inserted text, and none of DEV-1211's.
            dev_1211_only = [(relative, after, before) for relative, before, after in overlay.patches()
                             if relative == overlay.MEDIA_ELEMENT]
            # DEV-1144's: none of DEV-1205's either.
            dev_1205_only = [
                (overlay.SUPPORT_HEADER, overlay.SUPPORT_INCLUDE_ANCHOR + '#include "base/timer/timer.h"\n',
                 overlay.SUPPORT_INCLUDE_ANCHOR),
                (overlay.PUBLIC_CLIENT, overlay.PUBLIC_CLIENT_INCLUDE_ANCHOR
                 + '#include "third_party/blink/public/platform/web_string.h"\n', overlay.PUBLIC_CLIENT_INCLUDE_ANCHOR),
                (overlay.PUBLIC_CLIENT, overlay.DEV_1205_PUBLIC_CLIENT_HOOK, overlay.PUBLIC_CLIENT_ANCHOR),
                (overlay.CLIENT_HEADER, overlay.DEV_1205_CLIENT_HEADER_HOOK, overlay.CLIENT_HEADER_ANCHOR),
                (overlay.CLIENT, overlay.DEV_1205_CLIENT_REFUSED + overlay.CLIENT_REFUSED_ANCHOR,
                 overlay.CLIENT_REFUSED_ANCHOR),
                (overlay.CLIENT, overlay.CLIENT_GRANTED + overlay.CLIENT_GRANTED_ANCHOR, overlay.CLIENT_GRANTED_ANCHOR),
                (overlay.REQUEST_ACCESS, overlay.REQUEST_ACCESS_REFUSED, overlay.REQUEST_ACCESS_ANCHOR),
                (overlay.MEDIA_FACTORY, overlay.DELEGATE_MEMBER, overlay.DELEGATE_MEMBER_ANCHOR),
            ]
            versions = {
                "DEV-1205": (overlay.DEV_1205_UPGRADES, dev_1211_only),
                "DEV-1205's first version": (overlay.DEV_1205_UPGRADES + overlay.DEV_1205_FIRST_VERSION_UPGRADES,
                                             dev_1211_only),
                "DEV-1144": (overlay.DEV_1144_UPGRADES + overlay.DEV_1205_UPGRADES, dev_1211_only + dev_1205_only),
                # Engine batch 9's first build: media counted only in its own document.
                "DEV-1211's first version": (overlay.DEV_1211_FIRST_VERSION_UPGRADES, []),
            }
            for version, (steps, added) in versions.items():
                with self.subTest(version=version), tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    prepare_upstream(root)
                    overlay.apply(root)
                    # Undone in the order they apply, last first.
                    order = list(overlay.UPGRADES)
                    downgrade(root, sorted(steps, key=order.index))
                    remove_patches(root, added)
                    self.assertNotEqual(snapshot(fresh), snapshot(root))

                    overlay.apply(root)
                    self.assertEqual(snapshot(fresh), snapshot(root))

    def test_a_tree_prepared_with_the_dev_877_version_is_upgraded(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare_upstream(root)
            path = root / overlay.SOURCE
            text = path.read_text()
            # DEV-877's version of the overlay, as a prepared tree keeps it.
            text = text.replace('#include "content/browser/media/key_system_support_impl.h"\n',
                                '#include "content/browser/media/key_system_support_impl.h"\n\n'
                                '#include "chrome/browser/arx/protected_media_hooks.h"  // nogncheck\n\n', 1)
            text = text.replace("namespace content {\n", "namespace {\n"
                                "arx::ProtectedMediaObserver g_arx_protected_media_observer = nullptr;\n"
                                "}  // namespace\n\n" + overlay.SETTER + "\nnamespace content {\n", 1)
            text = text.replace(overlay.FIRST_QUESTION_ANCHOR,
                                overlay.FIRST_QUESTION_ANCHOR + "\n" + overlay.DEV_877_UPGRADES[2][1]
                                + "    g_arx_protected_media_observer(&render_frame_host());\n  }\n", 1)
            path.write_text(text)
            overlay.apply(root)
            upgraded = path.read_text()
            self.assertEqual(upgraded.count("g_arx_protected_media_observer = nullptr;"), 1)
            self.assertEqual(upgraded.count("void arx::SetProtectedMediaObserver("), 1)
            self.assertEqual(upgraded.count("void arx::ReportProtectedMediaFailure("), 1)
            self.assertEqual(upgraded.count("protected_media_hooks.h"), 1)
            # Only ArxReport calls the observer: the first question's call is gone.
            self.assertEqual(upgraded.count("g_arx_protected_media_observer(\n"), 1)
            self.assertNotIn("g_arx_protected_media_observer(&render_frame_host());", upgraded)

    def test_every_changed_anchor_fails_closed(self):
        for index, (relative, old, _) in enumerate(overlay.patches()):
            with self.subTest(index=index), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                prepare(root)
                path = root / relative
                path.write_text(path.read_text().replace(old, "changed upstream\n"))
                with self.assertRaisesRegex(ValueError, "overlay anchor changed"):
                    overlay.apply(root)


if __name__ == "__main__":
    unittest.main()
