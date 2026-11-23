#include <cassert>
#include <string>

#include "keyboard_policy.h"

using namespace arx::inspection;

int main() {
  uint32_t modifiers = 99;
  std::string key;
  assert(IsKeyboardKind(kTypeKind) && IsKeyboardKind(kKeyChordKind) && !IsKeyboardKind(4));
  assert(ParseKeyChord("0:Tab", &modifiers, &key) && modifiers == 0 && key == "Tab");
  assert(ParseKeyChord("15:k", &modifiers, &key) && modifiers == 15 && key == "k");
  assert(ParseKeyChord("3::", &modifiers, &key) && key == ":");
  assert(!ParseKeyChord("16:k", &modifiers, &key));
  assert(!ParseKeyChord("03:k", &modifiers, &key));
  assert(!ParseKeyChord("100:k", &modifiers, &key));
  assert(!ParseKeyChord(":k", &modifiers, &key));
  assert(!ParseKeyChord("1:", &modifiers, &key));
  assert(!ParseKeyChord("1k", &modifiers, &key));
  assert(!ParseKeyChord("a:k", &modifiers, &key));
  assert(!ParseKeyChord("1:" + std::string(39, 'k'), &modifiers, &key));
  return 0;
}
