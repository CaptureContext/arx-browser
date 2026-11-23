"""Dark pages: the Blink insertions DEV-1077's first overlay made (20285589).

A tree prepared with that overlay has these in place of the upstream lines.
`dark_pages_overlay.apply` turns them back into the upstream lines before
applying the current insertions (DEV-1094, DEV-1095). Data only.
"""

# (file, upstream lines, the lines DEV-1077 left there)
INSERTIONS = [
    ('third_party/blink/renderer/core/css/style_engine.h',
     '  void ColorSchemeChanged();\n',
     "  void ColorSchemeChanged();\n  // Arx (DEV-1077): the document's own styles asked for a dark color scheme\n  // (prefers-color-scheme: dark), so it has a dark theme of its own and forced\n  // darkening doesn't go over it.\n  void NoteOwnDarkTheme();\n"),
    ('third_party/blink/renderer/core/css/style_engine.h',
     '  bool force_dark_mode_enabled_{false};\n',
     '  bool force_dark_mode_enabled_{false};\n  // Arx (DEV-1077).\n  bool has_own_dark_theme_{false};\n  void UpdateOwnDarkTheme();\n'),
    ('third_party/blink/renderer/core/css/style_engine.cc',
     '#include "base/functional/function_ref.h"\n',
     '#include "base/functional/function_ref.h"\n#include "base/task/single_thread_task_runner.h"\n#include "third_party/blink/public/platform/task_type.h"\n#include "third_party/blink/renderer/platform/heap/persistent.h"\n#include "third_party/blink/renderer/platform/wtf/functional.h"\n'),
    ('third_party/blink/renderer/core/css/style_engine.cc',
     '  force_dark_mode_enabled_ = settings->GetForceDarkModeEnabled();\n',
     '  force_dark_mode_enabled_ = settings->GetForceDarkModeEnabled();\n  // Arx (DEV-1077): a document with its own dark theme gets just that theme.\n  if (has_own_dark_theme_) {\n    force_dark_mode_enabled_ = false;\n  }\n'),
    ('third_party/blink/renderer/core/css/style_engine.cc',
     'void StyleEngine::ColorSchemeChanged() {\n  UpdateColorScheme();\n}\n',
     'void StyleEngine::ColorSchemeChanged() {\n  UpdateColorScheme();\n}\n\n// Arx (DEV-1077). Media queries are evaluated in the middle of style updates,\n// so the color scheme changes after the one this was found in.\nvoid StyleEngine::NoteOwnDarkTheme() {\n  if (has_own_dark_theme_) {\n    return;\n  }\n  has_own_dark_theme_ = true;\n  if (!force_dark_mode_enabled_ || !GetDocument().IsActive()) {\n    return;\n  }\n  GetDocument()\n      .GetTaskRunner(TaskType::kInternalDefault)\n      ->PostTask(FROM_HERE, BindOnce(&StyleEngine::UpdateOwnDarkTheme,\n                                     WrapWeakPersistent(this)));\n}\n\nvoid StyleEngine::UpdateOwnDarkTheme() {\n  if (GetDocument().IsActive()) {\n    UpdateColorScheme();\n  }\n}\n'),
    ('third_party/blink/renderer/core/css/media_query_evaluator.cc',
     '#include "third_party/blink/renderer/core/frame/local_frame.h"\n',
     '#include "third_party/blink/renderer/core/css/style_engine.h"\n#include "third_party/blink/renderer/core/dom/document.h"\n#include "third_party/blink/renderer/core/frame/local_frame.h"\n'),
    ('third_party/blink/renderer/core/css/media_query_evaluator.cc',
     'namespace blink {\n',
     'namespace blink {\n\n// Arx (DEV-1077): a prefers-color-scheme: dark feature matched in the media\n// query being evaluated. Per thread, since the preload scanner evaluates too.\nconstinit thread_local bool arx_dark_scheme_matched = false;\n'),
    ('third_party/blink/renderer/core/css/media_query_evaluator.cc',
     '  for (wtf_size_t i = 0; i < queries.size() && result != KleeneValue::kTrue;\n       ++i) {\n    result = Eval(*queries[i], result_flags, custom_medias);\n  }\n',
     "  for (wtf_size_t i = 0; i < queries.size() && result != KleeneValue::kTrue;\n       ++i) {\n    // Arx (DEV-1077): a whole query that matches with a dark color scheme\n    // feature in it means the document has a dark theme of its own; a dark\n    // feature in a query that doesn't match as a whole doesn't count.\n    const bool outer_dark_scheme_matched = arx_dark_scheme_matched;\n    arx_dark_scheme_matched = false;\n    result = Eval(*queries[i], result_flags, custom_medias);\n    if (result == KleeneValue::kTrue && arx_dark_scheme_matched) {\n      if (Document* document = media_values_->GetDocument()) {\n        document->GetStyleEngine().NoteOwnDarkTheme();\n      }\n    }\n    arx_dark_scheme_matched = outer_dark_scheme_matched;\n  }\n"),
    ('third_party/blink/renderer/core/css/media_query_evaluator.cc',
     '  if (!value.IsId()) {\n    return false;\n  }\n\n  return (preferred_scheme == mojom::blink::PreferredColorScheme::kDark &&\n          value.Id() == CSSValueID::kDark) ||\n',
     '  if (!value.IsId()) {\n    return false;\n  }\n\n  // Arx (DEV-1077): the query set around this decides whether it counts.\n  if (preferred_scheme == mojom::blink::PreferredColorScheme::kDark &&\n      value.Id() == CSSValueID::kDark) {\n    arx_dark_scheme_matched = true;\n  }\n\n  return (preferred_scheme == mojom::blink::PreferredColorScheme::kDark &&\n          value.Id() == CSSValueID::kDark) ||\n'),
]
