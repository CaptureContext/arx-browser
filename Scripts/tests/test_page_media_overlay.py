"""The page media bridge's renderer agent and browser binder are wired in (DEV-1144)."""

from pathlib import Path
import tempfile
import unittest

from Scripts.engine import page_media_overlay as overlay
from Scripts.engine.config import PACKAGE


def prepare(root):
    for relative, old, _ in overlay.patches():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a") as stream:
            stream.write(old + "\n")


def snapshot(root):
    return {path.relative_to(root): path.read_bytes() for path in root.rglob("*") if path.is_file()}


class PageMediaOverlayTests(unittest.TestCase):
    def test_apply_is_repeatable_and_copies_the_component(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            overlay.apply(root)
            first = snapshot(root)
            overlay.apply(root)
            self.assertEqual(first, snapshot(root))
            copied = sorted(path.name for path in (root / overlay.COMPONENT).iterdir())
            self.assertEqual(copied, ["BUILD.gn", "page_media.mojom", "page_media_agent.cc", "page_media_agent.h"])

    def test_only_top_level_frames_get_an_agent(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            overlay.apply(root)
            client = (root / overlay.RENDERER_CLIENT).read_text()
            self.assertIn("if (render_frame->IsMainFrame() && !render_frame->IsInFencedFrameTree()) {", client)
            self.assertLess(client.index("new arx::inspection::Inspector(render_frame);\n#endif\n"),
                            client.index("new arx::page_media::PageMediaAgent(render_frame);"))
            self.assertIn('"//components/arx_page_media:renderer",', (root / overlay.RENDERER_BUILD).read_text())

    def test_the_host_binder_is_registered_on_the_mac(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            overlay.apply(root)
            bindings = (root / overlay.RECEIVER_BINDINGS).read_text()
            register = bindings.index("arx::RegisterPageMediaBinders(render_frame_host, associated_registry);")
            self.assertGreater(register, bindings.index("#if BUILDFLAG(IS_MAC)\n  // DEV-1144"))
            self.assertLess(register, bindings.index("for (auto& ep : extra_parts_)"))

    def test_the_agent_runs_once_per_prepared_document(self):
        agent = (PACKAGE / "Native/page_media/page_media_agent.cc").read_text()
        # The preparation is spent on the document it names, and kept past others.
        self.assertIn("origin.IsOpaque() || origin.ToString().Utf8() != prepared_->origin) return;", agent)
        self.assertIn("pending_script_ = std::move(prepared_->script);\n  prepared_.reset();", agent)
        # It runs where script may run, not inside DidCreateDocumentElement's ScriptForbiddenScope.
        self.assertIn("agent->Run(script);", agent)
        # Messages for a document that's gone never reach the next one.
        self.assertIn("context != context_.Get(isolate)", agent)

    def test_a_queued_message_reaches_the_app_only_from_the_current_document(self):
        bridge = (PACKAGE / "Native/page_media_bridge.mm").read_text()
        self.assertIn("base::BindOnce(&DispatchToApp, page, number_, frame.GetWeakDocumentPtr(),", bridge)
        dispatch = bridge[bridge.index("  static void DispatchToApp("):bridge.index("  const uint64_t number_;")]
        # A navigation that commits before the task runs leaves the message behind.
        self.assertIn("weak_document.AsRenderFrameHostIfValid();", dispatch)
        self.assertIn("!frame->IsInPrimaryMainFrame()", dispatch)
        self.assertIn("content::WebContents::FromRenderFrameHost(frame) != contents", dispatch)
        self.assertIn("!bridge.Bridges(frame->GetLastCommittedOrigin())", dispatch)
        self.assertIn("if (!current || current->number() != document) return;", dispatch)
        self.assertLess(dispatch.index("current->number() != document"), dispatch.index("bridge.handler("))
        self.assertEqual(bridge.count("bridge.handler("), 1)

    def test_inspection_and_page_media_overlays_stay_repeatable_together(self):
        from Scripts.engine import inspection_overlay
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for relative, old, _ in inspection_overlay.patches():
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                with path.open("a") as stream:
                    stream.write(old + "\n")
            for relative, old, _ in overlay.upstream_patches():
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                with path.open("a") as stream:
                    stream.write(old + "\n")
            for _ in range(2):
                inspection_overlay.apply(root)
                overlay.apply(root)
            client = (root / overlay.RENDERER_CLIENT).read_text()
            self.assertEqual(client.count("new arx::inspection::Inspector(render_frame);"), 1)
            self.assertEqual(client.count("new arx::page_media::PageMediaAgent(render_frame);"), 1)
            self.assertEqual(client.count("arx::page_media::PageMediaAgent::RunAtDocumentStart(render_frame);"), 1)
            build = (root / overlay.RENDERER_BUILD).read_text()
            self.assertEqual(build.count('"//components/arx_page_media:renderer",'), 1)
            bindings = (root / overlay.RECEIVER_BINDINGS).read_text()
            self.assertIn('page_media_hooks.h"  // nogncheck\n#endif\n', bindings)

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
