"""Switch off Helium's omnibox !bangs; Arx resolves bangs itself from a bundled list.

Helium's `add-native-bangs.patch` makes every TemplateURLService load start
`Bangs::BangManager`, which (since Helium 0.21) loads
`<Helium services>/bangs.json` through a shared `BangCache` SimpleURLLoader
whenever `helium::ShouldFetchBangs` allows it, and retries failures. Arx never
uses Chromium's omnibox, so `LoadBangs` now always takes Helium's own
"don't fetch" branch: it answers at once with an empty catalogue, so no loader
is made, nothing is requested or cached, no retry is scheduled (retries follow
only a failed load) and TemplateURLService adds no bang keywords. The rest of Helium's
bang code stays and compiles. If the anchor changes, the build stops instead
of shipping the fetch.
"""
from .overlay import replace_once

MANAGER = "components/search_engines/template_url_bang_manager.cc"

LOAD = """  if (!helium::ShouldFetchBangs(*prefs_)) {
    OnBangsLoaded(base::MakeRefCounted<Catalogue>(std::vector<Bang>()));
    return;
  }

  StartFetch();
}
"""

ARX_LOAD = """  // Arx: the embedding app resolves !bangs from its own bundled list and never
  // uses this omnibox catalogue. Answer at once with no bangs; no loader is
  // created and nothing is requested from Helium's services.
  OnBangsLoaded(base::MakeRefCounted<Catalogue>(std::vector<Bang>()));
}
"""


def patches():
    yield MANAGER, LOAD, ARX_LOAD


def apply(source):
    for relative, before, after in patches():
        replace_once(source / relative, before, after)
