#include <cassert>
#include <functional>
#include <string>
#include <utility>
#include <vector>
namespace content { struct WebContents { bool owned; }; }
struct GURL { bool exact; };
namespace base {
template<class> struct RepeatingCallback;
template<> struct RepeatingCallback<bool()> {
  std::function<bool()> callback;
  explicit operator bool() const { return bool(callback); }
  bool Run() const { return callback(); }
};
struct OnceClosure {
  std::function<void()> callback;
  void Run() { if (callback) std::exchange(callback, {})(); }
};
}
struct Fixture { int receipt = 1; std::u16string expected_program = u"exact owned display name.app"; };
Fixture& State() { static Fixture state; return state; }
std::vector<std::string> records;
void Record(const std::string& value) { records.push_back(value); }
bool ExactTarget(const GURL& target) { return target.exact; }
bool OwnedProfile(content::WebContents* contents) { return contents && contents->owned; }
// PRODUCTION_DIALOG_GUARD
int main() {
  for (unsigned mask = 0; mask != 32; ++mask) {
    records.clear(); int canceled = 0;
    content::WebContents child{bool(mask & 2)}, source{bool(mask & 4)};
    const auto program = mask & 8 ? State().expected_program : u"foreign handler";
    DialogShown(&child, &source, GURL{bool(mask & 1)}, program,
        {[mask] { return bool(mask & 16); }}, {}, {[&] { ++canceled; }}, {}, nullptr);
    if (mask == 31) { assert(records.empty() && canceled == 0); continue; }
    assert(canceled == 1 && records.size() == 2);
    assert(records[0] == "diagnostic:dialog-checks:" + std::to_string(mask) +
        ":program-app-suffix:0:program-length:" + std::to_string(std::u16string(program).size()));
    assert(records[1] == "FAIL:unexpected-dialog");
    assert(records[0].find("foreign") == std::string::npos);
    assert(records[0].find("owned") == std::string::npos);
  }
  records.clear(); int canceled = 0;
  content::WebContents contents{true};
  DialogShown(&contents, &contents, GURL{true}, u"Arx Owned External Handler.app",
      {[] { return true; }}, {}, {[&] { ++canceled; }}, {}, nullptr);
  assert(canceled == 1 && records[0].find(":program-app-suffix:1:") != std::string::npos);
  records.clear(); canceled = 0;
  DialogShown(&contents, &contents, GURL{true}, State().expected_program,
      {}, {}, {[&] { ++canceled; }}, {}, nullptr);
  assert(canceled == 1 && records[0].starts_with("diagnostic:dialog-checks:15:"));
  records.clear(); State().receipt = -1; canceled = 0;
  DialogShown(nullptr, nullptr, GURL{false}, {}, {}, {}, {[&] { ++canceled; }}, {}, nullptr);
  assert(records.empty() && canceled == 0);
}
