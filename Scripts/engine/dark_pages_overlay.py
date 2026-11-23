"""Dark pages (DEV-1020): Blink's forced darkening for Arx's pages, per site.

`ChromeContentBrowserClient` computes every page's web preferences, the color
scheme included, in `OverrideWebPreferences`, and again after each navigation
in `OverrideWebPreferencesAfterNavigation`, which Chrome's Android night mode
uses for the same purpose. Both end by asking `arx::ApplyDarkPages`, which
turns on `force_dark_mode_enabled` and a dark preferred color scheme for an Arx
page whose site should be dark, and leaves every other page as Chrome set it.

The code lives in `Native/dark_pages_bridge.mm`. Every insertion is guarded by
`BUILDFLAG(IS_MAC)` and anchored on upstream lines only.

DEV-1077, DEV-1094, DEV-1095: a document whose own active styles hold a dark
theme, a `@media (prefers-color-scheme: dark)` rule (or `@import` with that
query) that applies, gets just that theme. Forced darkening keeps the preferred
color scheme dark, so the theme applies, but Blink would still mark the page
forced dark and run its colors and images through the darkening filter as well.

- `MediaQueryEvaluator::Eval(const MediaQuerySet&, ...)` notes, per thread,
  whether the query set it just evaluated has a whole query with a matching
  `prefers-color-scheme: dark` feature that matches, looking past the query
  that decided the result; a partly matching query or an empty set doesn't.
- `RuleSet::MatchMediaForAddRules` asks right after its evaluation and marks the
  rule set as holding a dark theme. Rules under a media rule that doesn't apply
  are never added, so a dark query nested in one is never evaluated there.
- A cached rule set is rebuilt when its answer changes even though every
  query set kept its result (`RuleSet::DidMediaQueryResultsChange`).
- After every active style sheet update, `StyleEngine` asks the active rule
  sets of the document, its shadow trees (adopted sheets included) and its
  user-origin sheets (an extension's insertCSS), and a sheet's own media
  (`<link media>`, `<style media>`). A media query in a CSS `@function` or
  `if()` counts while it applies: `EvaluateFunctionalMediaQuery` notes it, and
  the functional results are asked again before Blink drops them. When the answer changes, a posted task updates the color
  scheme, and `UpdateColorScheme` drops `force_dark_mode_enabled_` while it
  holds. A theme added later, removed later, or brought in or out by a media
  change (rule sets are rebuilt then) is followed without a reload. A script's
  `matchMedia` doesn't count: only styles that apply do.

- A mixin's media dependencies, which `RuleSet::ApplyMixin` takes on, count
  for the marker as they do for the cache check.
- A tree prepared with DEV-1077's first overlay (`dark_pages_dev1077.py`) has
  those insertions turned back into the upstream lines before these apply.

Blink is shared code without a Mac guard here; Arx builds only for the Mac.
"""
from .dark_pages_dev1077 import INSERTIONS as DEV1077_INSERTIONS
from .overlay import replace_once

CLIENT = "chrome/browser/chrome_content_browser_client.cc"
STYLE_ENGINE_H = "third_party/blink/renderer/core/css/style_engine.h"
STYLE_ENGINE = "third_party/blink/renderer/core/css/style_engine.cc"
MEDIA_QUERIES = "third_party/blink/renderer/core/css/media_query_evaluator.cc"
RULE_SET_H = "third_party/blink/renderer/core/css/rule_set.h"
RULE_SET = "third_party/blink/renderer/core/css/rule_set.cc"
INCLUDE = '#include "chrome/browser/arx/dark_pages_bridge.h"  // nogncheck\n'


def patches():
    yield CLIENT, '#include "chrome/browser/battery/battery_saver.h"\n', \
        '#include "chrome/browser/battery/battery_saver.h"\n' \
        '#if BUILDFLAG(IS_MAC)\n' + INCLUDE + '#endif\n'
    yield CLIENT, """  for (auto& parts : extra_parts_) {
    parts->OverrideWebPreferences(web_contents, main_frame_site, web_prefs);
  }
""", """  for (auto& parts : extra_parts_) {
    parts->OverrideWebPreferences(web_contents, main_frame_site, web_prefs);
  }

#if BUILDFLAG(IS_MAC)
  // Arx (DEV-1020): dark pages, after the color scheme above.
  arx::ApplyDarkPages(web_contents, web_prefs);
#endif
"""
    yield CLIENT, """  return prefs_changed;
}

bool ChromeContentBrowserClient::
    WebPreferencesNeedUpdateForColorRelatedStateChanges(""", """#if BUILDFLAG(IS_MAC)
  // Arx (DEV-1020): the new site's dark pages decision.
  prefs_changed |= arx::ApplyDarkPages(web_contents, web_prefs);
#endif

  return prefs_changed;
}

bool ChromeContentBrowserClient::
    WebPreferencesNeedUpdateForColorRelatedStateChanges("""


    # DEV-1077, DEV-1094, DEV-1095: a document's own dark theme goes undarkened.
    yield STYLE_ENGINE_H, "  bool force_dark_mode_enabled_{false};\n", """  bool force_dark_mode_enabled_{false};
  // Arx (DEV-1077, DEV-1094, DEV-1095): the document's active rule sets hold
  // a dark theme of its own, so forced darkening doesn't go over it.
  bool has_own_dark_theme_{false};
  // A CSS function's or if()'s media query with a dark theme applies.
  bool has_functional_dark_theme_{false};
  void UpdateHasOwnDarkTheme();
  void UpdateOwnDarkTheme();
"""
    yield STYLE_ENGINE, '#include "base/functional/function_ref.h"\n', \
        '#include "base/functional/function_ref.h"\n' \
        '#include "base/task/single_thread_task_runner.h"\n' \
        '#include "third_party/blink/public/platform/task_type.h"\n' \
        '#include "third_party/blink/renderer/platform/heap/persistent.h"\n' \
        '#include "third_party/blink/renderer/platform/wtf/functional.h"\n'
    yield STYLE_ENGINE, "namespace blink {\n", """namespace blink {

// Arx (DEV-1094, DEV-1095), in media_query_evaluator.cc.
bool ArxQuerySetMatchedDarkScheme();
"""
    yield STYLE_ENGINE, "  force_dark_mode_enabled_ = settings->GetForceDarkModeEnabled();\n", \
        """  force_dark_mode_enabled_ = settings->GetForceDarkModeEnabled();
  // Arx (DEV-1077): a document with its own dark theme gets just that theme.
  if (has_own_dark_theme_) {
    force_dark_mode_enabled_ = false;
  }
"""
    yield STYLE_ENGINE, "  probe::ActiveStyleSheetsUpdated(document_);\n\n  dirty_tree_scopes_.clear();\n", \
        """  probe::ActiveStyleSheetsUpdated(document_);
  // Arx (DEV-1094, DEV-1095): from the rules that apply now.
  UpdateHasOwnDarkTheme();

  dirty_tree_scopes_.clear();
"""
    yield STYLE_ENGINE, "void StyleEngine::ColorSchemeChanged() {\n  UpdateColorScheme();\n}\n", \
        """void StyleEngine::ColorSchemeChanged() {
  UpdateColorScheme();
}

// Arx (DEV-1077, DEV-1094, DEV-1095). Active style sheets update in the middle
// of style updates, so the color scheme changes after the one this was found
// in.
void StyleEngine::UpdateHasOwnDarkTheme() {
  const MediaQueryEvaluator& medium = EnsureMediaQueryEvaluator();
  // A sheet's own rules, or the sheet's media (<link media>, <style media>).
  auto holds_dark_theme = [&](const ActiveStyleSheetVector& sheets) {
    for (const auto& active : sheets) {
      if (active.second && active.second->HasOwnDarkTheme()) {
        return true;
      }
      const MediaQuerySet* media =
          active.first ? active.first->MediaQueries() : nullptr;
      if (active.second && media && medium.Eval(*media) &&
          ArxQuerySetMatchedDarkScheme()) {
        return true;
      }
    }
    return false;
  };
  // Its shadow trees' sheets, adopted ones included.
  // The document's and extensions' user-origin sheets (insertCSS with
  // origin USER), and media queries in CSS functions and if().
  bool has_own_dark_theme =
      has_functional_dark_theme_ ||
      holds_dark_theme(GetDocumentStyleSheetCollection().ActiveStyleSheets()) ||
      holds_dark_theme(active_user_style_sheets_);
  for (TreeScope* tree_scope : active_tree_scopes_) {
    if (has_own_dark_theme) {
      break;
    }
    if (StyleSheetCollection* collection = StyleSheetCollectionFor(*tree_scope)) {
      has_own_dark_theme = holds_dark_theme(collection->ActiveStyleSheets());
    }
  }
  if (has_own_dark_theme == has_own_dark_theme_) {
    return;
  }
  has_own_dark_theme_ = has_own_dark_theme;
  GetDocument()
      .GetTaskRunner(TaskType::kInternalDefault)
      ->PostTask(FROM_HERE, BindOnce(&StyleEngine::UpdateOwnDarkTheme,
                                     WrapWeakPersistent(this)));
}

void StyleEngine::UpdateOwnDarkTheme() {
  if (GetDocument().IsActive()) {
    UpdateColorScheme();
  }
}
"""
    yield STYLE_ENGINE, """bool StyleEngine::EvaluateFunctionalMediaQuery(const MediaQuerySet& query_set) {
  bool result = EnsureMediaQueryEvaluator().Eval(
      query_set, &functional_media_query_result_flags_);
""", """bool StyleEngine::EvaluateFunctionalMediaQuery(const MediaQuerySet& query_set) {
  bool result = EnsureMediaQueryEvaluator().Eval(
      query_set, &functional_media_query_result_flags_);
  // Arx (DEV-1094): a dark theme from a CSS function's or if()'s media query.
  if (result && ArxQuerySetMatchedDarkScheme() && !has_functional_dark_theme_) {
    has_functional_dark_theme_ = true;
    UpdateHasOwnDarkTheme();
  }
"""
    yield STYLE_ENGINE, """    // or the Document/StyleEngine has been detached.
    return;
  }
  functional_media_query_results_.clear();
  functional_media_query_result_flags_.Clear();
""", """    // or the Document/StyleEngine has been detached.
    return;
  }
  // Arx (DEV-1094): asked again of the same queries before they go, so the
  // answer doesn't flip while the styles that use them are resolved again.
  bool has_functional_dark_theme = false;
  for (const auto& entry : functional_media_query_results_) {
    if (media_query_evaluator_->Eval(*entry.key) &&
        ArxQuerySetMatchedDarkScheme()) {
      has_functional_dark_theme = true;
      break;
    }
  }
  if (has_functional_dark_theme != has_functional_dark_theme_) {
    has_functional_dark_theme_ = has_functional_dark_theme;
    UpdateHasOwnDarkTheme();
  }
  functional_media_query_results_.clear();
  functional_media_query_result_flags_.Clear();
"""
    yield RULE_SET_H, "  bool HasCascadeLayers() const { return implicit_outer_layer_ != nullptr; }\n", \
        """  bool HasCascadeLayers() const { return implicit_outer_layer_ != nullptr; }
  // Arx (DEV-1094, DEV-1095): a media query with a matching
  // prefers-color-scheme: dark feature applied while the rules were added.
  bool HasOwnDarkTheme() const { return has_own_dark_theme_; }
"""
    yield RULE_SET_H, "  HeapVector<MediaQuerySetResult> media_query_set_results_;\n", \
        """  HeapVector<MediaQuerySetResult> media_query_set_results_;
  // Arx (DEV-1094, DEV-1095).
  bool has_own_dark_theme_ = false;
"""
    yield RULE_SET, """    features_.MutableMediaQueryResultFlags().Add(
        mixins.media_query_result_flags);
    media_query_set_results_.append_range(mixins.media_query_set_results);
""", """    features_.MutableMediaQueryResultFlags().Add(
        mixins.media_query_result_flags);
    media_query_set_results_.append_range(mixins.media_query_set_results);
    // Arx (DEV-1094): the mixins' media dependencies count as the cache check
    // counts them, so it doesn't see a change on every check.
    for (const MediaQuerySetResult& result : mixins.media_query_set_results) {
      if (!has_own_dark_theme_ && result.Result() &&
          medium.Eval(result.MediaQueries()) &&
          ArxQuerySetMatchedDarkScheme()) {
        has_own_dark_theme_ = true;
      }
    }
"""
    yield RULE_SET, "namespace blink {\n", """namespace blink {

// Arx (DEV-1094, DEV-1095), in media_query_evaluator.cc.
bool ArxQuerySetMatchedDarkScheme();
"""
    yield RULE_SET, """  bool match_media =
      evaluator.Eval(*media_queries, &features_.MutableMediaQueryResultFlags());
""", """  bool match_media =
      evaluator.Eval(*media_queries, &features_.MutableMediaQueryResultFlags());
  // Arx (DEV-1094, DEV-1095): only rules that apply get here, so a dark query
  // nested in a media rule that doesn't apply is never evaluated here.
  if (match_media && ArxQuerySetMatchedDarkScheme()) {
    has_own_dark_theme_ = true;
  }
"""
    yield RULE_SET, """bool RuleSet::DidMediaQueryResultsChange(
    const MediaQueryEvaluator& evaluator) const {
  return evaluator.DidResultsChange(media_query_set_results_);
}
""", """bool RuleSet::DidMediaQueryResultsChange(
    const MediaQueryEvaluator& evaluator) const {
  if (evaluator.DidResultsChange(media_query_set_results_)) {
    return true;
  }
  // Arx (DEV-1094): every set may keep its result while the query in it that
  // matched changes, such as (min-width: 600px), (prefers-color-scheme: dark)
  // in a window made narrow, so the dark theme is asked again.
  bool has_own_dark_theme = false;
  for (const MediaQuerySetResult& result : media_query_set_results_) {
    if (result.Result() && evaluator.Eval(result.MediaQueries()) &&
        ArxQuerySetMatchedDarkScheme()) {
      has_own_dark_theme = true;
      break;
    }
  }
  return has_own_dark_theme != has_own_dark_theme_;
}
"""
    yield MEDIA_QUERIES, "namespace blink {\n", """namespace blink {

// Arx (DEV-1077): a prefers-color-scheme: dark feature matched in the media
// query being evaluated, and the last query set evaluated matched through one.
// Per thread, since the preload scanner evaluates too.
constinit thread_local bool arx_dark_scheme_matched = false;
constinit thread_local bool arx_query_set_matched_dark_scheme = false;

// Arx (DEV-1094, DEV-1095): for RuleSet, right after its evaluation.
bool ArxQuerySetMatchedDarkScheme() {
  return arx_query_set_matched_dark_scheme;
}
"""
    yield MEDIA_QUERIES, """  const HeapVector<Member<const MediaQuery>>& queries = query_set.QueryVector();
  if (queries.empty()) {
    return true;  // An empty query list evaluates to true.
  }

  // Iterate over queries, stop if any of them eval to true (OR semantics).
  KleeneValue result = KleeneValue::kFalse;
  for (wtf_size_t i = 0; i < queries.size() && result != KleeneValue::kTrue;
       ++i) {
    result = Eval(*queries[i], result_flags, custom_medias);
  }
""", """  // Arx (DEV-1094): an empty set, a media-less @import's, isn't a dark theme.
  arx_query_set_matched_dark_scheme = false;
  const HeapVector<Member<const MediaQuery>>& queries = query_set.QueryVector();
  if (queries.empty()) {
    return true;  // An empty query list evaluates to true.
  }

  // Iterate over queries, stop if any of them eval to true (OR semantics).
  KleeneValue result = KleeneValue::kFalse;
  bool matched_dark_scheme = false;
  wtf_size_t i = 0;
  for (; i < queries.size() && result != KleeneValue::kTrue; ++i) {
    // Arx (DEV-1077): a whole query that matches with a dark color scheme
    // feature in it; a dark feature in a query that doesn't match as a whole
    // doesn't count.
    const bool outer_dark_scheme_matched = arx_dark_scheme_matched;
    arx_dark_scheme_matched = false;
    result = Eval(*queries[i], result_flags, custom_medias);
    matched_dark_scheme =
        result == KleeneValue::kTrue && arx_dark_scheme_matched;
    arx_dark_scheme_matched = outer_dark_scheme_matched;
  }
  // Arx (DEV-1094): a later query may be the dark one, such as
  // (min-width: 600px), (prefers-color-scheme: dark) in a wide window. Looked
  // at only to answer this; its dependencies join the flags, so a resize that
  // changes this answer is noticed, and the result stays as it was.
  for (; result == KleeneValue::kTrue && !matched_dark_scheme &&
         i < queries.size();
       ++i) {
    const bool outer_dark_scheme_matched = arx_dark_scheme_matched;
    arx_dark_scheme_matched = false;
    matched_dark_scheme =
        Eval(*queries[i], result_flags, custom_medias) == KleeneValue::kTrue &&
        arx_dark_scheme_matched;
    arx_dark_scheme_matched = outer_dark_scheme_matched;
  }
  arx_query_set_matched_dark_scheme = matched_dark_scheme;
"""
    yield MEDIA_QUERIES, """  if (!value.IsId()) {
    return false;
  }

  return (preferred_scheme == mojom::blink::PreferredColorScheme::kDark &&
          value.Id() == CSSValueID::kDark) ||
""", """  if (!value.IsId()) {
    return false;
  }

  // Arx (DEV-1077): the query set around this decides whether it counts.
  if (preferred_scheme == mojom::blink::PreferredColorScheme::kDark &&
      value.Id() == CSSValueID::kDark) {
    arx_dark_scheme_matched = true;
  }

  return (preferred_scheme == mojom::blink::PreferredColorScheme::kDark &&
          value.Id() == CSSValueID::kDark) ||
"""

def apply(source):
    # A tree prepared with DEV-1077's first overlay: its insertions go back to
    # the upstream lines, so the current ones apply in their place.
    for relative, upstream, earlier in reversed(DEV1077_INSERTIONS):
        path = source / relative
        if not path.exists():
            continue
        text = path.read_text()
        if text.count(earlier) == 1:
            path.write_text(text.replace(earlier, upstream, 1))
    for relative, before, after in patches():
        replace_once(source / relative, before, after)
