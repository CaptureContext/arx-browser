"""Compile and run the production page-head icon policy with sanitizers."""
from pathlib import Path
import subprocess
import tempfile
import unittest

from Scripts.engine.config import PACKAGE

SOURCE = r'''#include "site_icon_links.h"
#include <cassert>
#include <string>
using namespace arx::site_icons;

int main() {
  // Declared icons in head order, ranked: a 32px icon first, unknown size
  // next, a small one after, and the touch icon only as a last resort.
  auto links = ParseIconLinks(R"(<!doctype html><HTML><head>
    <link rel="apple-touch-icon" href="/touch.png">
    <link rel="icon" href="/small.png" sizes="16x16">
    <LINK REL="Shortcut Icon" HREF='/legacy.ico'>
    <link rel=icon type=image/png sizes="32x32 48x48" href=/best.png?v=1&amp;x=2>
    <link rel="stylesheet" href="/style.css">
    </head><body><link rel="icon" href="/body.png"></body>)");
  assert(links.complete);
  assert(!links.base);
  assert(links.icons.size() == 4);
  auto ranked = RankIconLinks(links.icons);
  assert(ranked.size() == kMaximumCandidates);
  assert(ranked[0].href == "/best.png?v=1&x=2" && ranked[0].size == 48);
  assert(ranked[1].href == "/legacy.ico" && ranked[1].size == 0);
  assert(ranked[2].href == "/small.png");

  // A touch icon still beats nothing; mask and vector icons are dropped.
  links = ParseIconLinks(R"(<head><base href="https://cdn.example/assets/">
    <link rel="mask-icon" href="/mask.svg" color="#000">
    <link rel="icon" href="/vector.svg">
    <link rel="icon" type="image/svg+xml" href="/vector">
    <link rel="icon" sizes="any" href="/any.png">
    <link rel="icon" href="data:image/svg+xml,<svg/>">
    <link rel="apple-touch-icon-precomposed" sizes="180x180" href="touch.png">
    <body>)");
  assert(links.complete);
  assert(links.base && *links.base == "https://cdn.example/assets/");
  assert(links.icons.size() == 1 && links.icons[0].touch && links.icons[0].size == 180);

  // Comments, scripts, styles and templates cannot declare icons.
  links = ParseIconLinks(R"(<head><!-- <link rel="icon" href="/comment.png"> -->
    <script>document.write('<link rel="icon" href="/script.png"></head>')</script>
    <style>a::after { content: '<link rel=icon href=/style.png>' }</style>
    <template><link rel="icon" href="/template.png"></template>
    <link rel="icon" href="/real.png"></head>)");
  assert(links.complete && links.icons.size() == 1 && links.icons[0].href == "/real.png");

  // A head cut off mid-tag keeps what came before and is not complete.
  links = ParseIconLinks(R"(<head><link rel="icon" href="/first.png"><link rel="icon" href="/cut)");
  assert(!links.complete && links.icons.size() == 1);
  links = ParseIconLinks("<head><script>");
  assert(!links.complete && links.icons.empty());
  for (std::string truncated : {"<", "</", "<l", "<link", "<link rel", "<link rel=", "<!--", "<!-"})
    assert(ParseIconLinks(truncated).icons.empty());

  // Bounded input: nothing past the head limit is read.
  std::string huge = "<head>" + std::string(kMaximumHeadBytes, ' ') + "<link rel=icon href=/late.png>";
  links = ParseIconLinks(huge);
  assert(links.icons.empty() && !links.complete);

  // Malformed sizes fall back to unknown; empty and long hrefs are ignored.
  links = ParseIconLinks(R"(<link rel=icon sizes="0x0 x16 16x 999999x1 abc" href=/odd.png>
    <link rel=icon href="">
    <link rel=icon href=")" + std::string(kMaximumHrefBytes + 1, 'a') + R"(">)");
  assert(links.icons.size() == 1 && links.icons[0].size == 0);

  // Duplicate hrefs are tried once.
  ranked = RankIconLinks({{"/a.png", 32, false}, {"/a.png", 0, false}, {"/b.png", 64, true}});
  assert(ranked.size() == 2 && ranked[0].href == "/a.png" && ranked[1].href == "/b.png");

  // A root page speaks for its site only on the same host, with or without
  // "www.": a redirect to a sign-in page or another app's host doesn't
  // (DEV-1108).
  assert(SpeaksForHost("calendar.google.com", "calendar.google.com"));
  assert(SpeaksForHost("example.com", "www.example.com"));
  assert(SpeaksForHost("www.example.com", "EXAMPLE.com."));
  assert(SpeaksForHost("127.0.0.1", "127.0.0.1"));
  assert(!SpeaksForHost("calendar.google.com", "accounts.google.com"));
  assert(!SpeaksForHost("mail.google.com", "www.google.com"));
  assert(!SpeaksForHost("localhost", "127.0.0.1"));
  assert(!SpeaksForHost("example.com", "wwwexample.com"));
  assert(!SpeaksForHost("", ""));

  // The app's directory: the saved path's first segment when it's a plain name
  // and the path goes on past it, never more of the saved page (DEV-1108).
  assert(AppDirectory("/spreadsheets/d/abc/edit") == "/spreadsheets/");
  assert(AppDirectory("/mail/u/0/") == "/mail/");
  assert(AppDirectory("/calendar/u/0/r") == "/calendar/");
  assert(AppDirectory("/Owa.v2/x") == "/Owa.v2/");
  assert(AppDirectory("/mail/") == "");
  assert(AppDirectory("/unsubscribe") == "");
  assert(AppDirectory("/") == "");
  assert(AppDirectory("") == "");
  assert(AppDirectory("//x") == "");
  assert(AppDirectory("/123/x") == "");
  assert(AppDirectory("/%2e%2e/x") == "");
  assert(AppDirectory("/a b/x") == "");
  assert(AppDirectory("/" + std::string(33, 'a') + "/x") == "");
  assert(AppDirectory("relative/x") == "");

  // Icons are scaled down to fit, keeping their shape, and never up.
  assert((FitIcon(180, 180, 32) == std::pair<int, int>{32, 32}));
  assert((FitIcon(64, 32, 32) == std::pair<int, int>{32, 16}));
  assert((FitIcon(16, 16, 32) == std::pair<int, int>{16, 16}));
  assert((FitIcon(1000, 1, 16) == std::pair<int, int>{16, 1}));
  assert((FitIcon(0, 16, 32) == std::pair<int, int>{0, 0}));
}
'''


class SiteIconLinksTests(unittest.TestCase):
    def test_production_policy(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "test.cc").write_text(SOURCE)
            result = subprocess.run(["xcrun", "clang++", "-std=c++20", "-Wall", "-Werror",
                "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                "-I", str(PACKAGE / "Native"), str(root / "test.cc"), "-o", str(root / "test")],
                capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(root / "test")], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
