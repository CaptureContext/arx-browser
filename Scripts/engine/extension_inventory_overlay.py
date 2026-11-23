"""Preserve precise extension-pref change keys without changing Chrome observers.

Unknown/legacy notifications retain their original fail-closed invalidation.
The additive default dispatch forwards existing observers exactly once.
"""

from .overlay import replace_once


def patches():
    observer = "extensions/browser/extension_prefs_observer.h"
    yield observer, '#include "base/observer_list_types.h"', '#include <string_view>\n\n#include "base/observer_list_types.h"'
    yield observer, '  virtual void OnExtensionPrefsUpdated(const ExtensionId& extension_id) {}', '''  virtual void OnExtensionPrefsUpdated(const ExtensionId& extension_id) {}

  // Precise internal writes supply the key. The default preserves existing
  // observers, including same-value writes, with exactly one notification.
  virtual void OnExtensionPrefUpdated(const ExtensionId& extension_id,
                                      std::string_view key) {
    OnExtensionPrefsUpdated(extension_id);
  }'''
    source = "extensions/browser/extension_prefs.cc"
    yield source, '''  update->Set(pref.name, std::move(data_value));
  for (auto& observer : observer_list_) {
    observer.OnExtensionPrefsUpdated(extension_id);
  }''', '''  update->Set(pref.name, std::move(data_value));
  for (auto& observer : observer_list_) {
    observer.OnExtensionPrefUpdated(extension_id, pref.name);
  }'''
    yield source, '''    update->Remove(key);
  }
  for (auto& observer : observer_list_) {
    observer.OnExtensionPrefsUpdated(extension_id);
  }''', '''    update->Remove(key);
  }
  for (auto& observer : observer_list_) {
    observer.OnExtensionPrefUpdated(extension_id, key);
  }'''


def apply(source):
    for relative, old, new in patches():
        replace_once(source / relative, old, new)
