#include <cassert>
#include <string>
#include "extension_install_authority.h"
#define DCHECK_CURRENTLY_ON(...)
#define DCHECK_NE(a,b) assert(a != b)
#define DCHECK(a) assert(a)
namespace base {
template <typename... T> int BindOnce(T...) { return 0; }
}
struct Extension {
  std::string id() const { return "verified-id"; }
  int location() const { return 7; }
};
struct ExtensionRegistry {
  const Extension* installed = nullptr;
  static ExtensionRegistry registry;
  static ExtensionRegistry* Get(void*) { return &registry; }
  const Extension* GetInstalledExtension(std::string) { return installed; }
};
ExtensionRegistry ExtensionRegistry::registry;
struct ExtensionInstallPromptClient {
  enum class Result { ACCEPTED, ACCEPTED_WITH_WITHHELD_PERMISSIONS, USER_CANCELED, ABORTED };
  struct DoneCallbackPayload { Result result; };
  int prompts = 0;
  void ConfirmInstall(int, const Extension*) { ++prompts; }
};
enum class CrxInstallErrorType { OTHER };
enum class CrxInstallErrorDetail { USER_CANCELED, USER_ABORTED };
struct CrxInstallError { CrxInstallError(CrxInstallErrorType, CrxInstallErrorDetail) {} };
struct Registrar {
  int grants = 0;
  void GrantPermissionsAndEnableExtension(const Extension&) { ++grants; }
};
class CrxInstaller {
 public:
  enum OffStoreInstallAllowReason { OffStoreInstallDisallowed, OffStoreInstallAllowedFromSettingsPage };
  enum WithholdingBehavior { kWithholdPermissions, kDontWithholdPermissions };
  void* browser_context_ = this;
  OffStoreInstallAllowReason off_store_install_allow_reason_ = OffStoreInstallAllowedFromSettingsPage;
  bool update_from_settings_page_ = false;
  std::string expected_id_;
  int install_source_ = 0;
  bool approved_ = false;
  ExtensionInstallPromptClient prompt;
  ExtensionInstallPromptClient* client_ = &prompt;
  Extension candidate;
  Registrar registrar;
  Registrar* registrar_ = &registrar;
  int commits = 0, references = 0, completed_cancellation = 0, failures = 0, cleanups = 0;
  bool was_triggered_by_user_download() { return false; }
  void ReportFailureFromUIThread(CrxInstallError) { ++failures; }
// HEADER
  const Extension* extension() { return &candidate; }
  void AddRef() { ++references; }
  void Release() { --references; }
  void UpdateCreationFlagsAndCompleteInstall(WithholdingBehavior) { ++commits; }
  void NotifyCrxInstallComplete(CrxInstallError) { ++completed_cancellation; }
  void CleanupTempFiles() { ++cleanups; }
  void CheckUpdateFromSettingsPage();
  void ConfirmInstall();
  void OnInstallPromptDone(ExtensionInstallPromptClient::DoneCallbackPayload);
};
// METHODS
int main() {
  Extension installed;
  ExtensionRegistry::registry.installed = &installed;
  CrxInstaller ordinary;
  ordinary.allow_silent_install_ = false;
  ordinary.CheckUpdateFromSettingsPage();
  ordinary.ConfirmInstall();
  assert(ordinary.update_from_settings_page_);
  assert(ordinary.commits == 1 && ordinary.prompt.prompts == 0);
  assert(ordinary.expected_id_ == "verified-id" && ordinary.install_source_ == 7);

  for (auto result : {ExtensionInstallPromptClient::Result::USER_CANCELED,
                      ExtensionInstallPromptClient::Result::ABORTED,
                      ExtensionInstallPromptClient::Result::ACCEPTED}) {
    CrxInstaller explicit_update;
    explicit_update.allow_silent_install_ = false;
    explicit_update.set_require_verified_install_prompt(true);
    explicit_update.CheckUpdateFromSettingsPage();
    explicit_update.ConfirmInstall();
    assert(!explicit_update.update_from_settings_page_);
    assert(explicit_update.commits == 0 && explicit_update.prompt.prompts == 1);
    assert(explicit_update.expected_id_ == "verified-id" && explicit_update.install_source_ == 7);
    explicit_update.OnInstallPromptDone({result});
    assert(explicit_update.references == 0 && explicit_update.registrar.grants == 0);
    assert(explicit_update.commits == (result == ExtensionInstallPromptClient::Result::ACCEPTED ? 1 : 0));
    assert(explicit_update.completed_cancellation == (result == ExtensionInstallPromptClient::Result::ACCEPTED ? 0 : 1));
    assert(explicit_update.cleanups == (result == ExtensionInstallPromptClient::Result::ACCEPTED ? 0 : 1));
  }
  for (bool approved : {false, true}) {
    CrxInstaller no_client;
    no_client.set_allow_silent_install(true);
    no_client.set_require_verified_install_prompt(true);
    no_client.approved_ = approved;
    no_client.client_ = nullptr;
    no_client.CheckUpdateFromSettingsPage();
    no_client.ConfirmInstall();
    assert(no_client.commits == 0 && no_client.failures == 1);
  }
  CrxInstaller preapproved;
  preapproved.set_allow_silent_install(true);
  preapproved.set_require_verified_install_prompt(true);
  preapproved.approved_ = true;
  preapproved.CheckUpdateFromSettingsPage();
  preapproved.ConfirmInstall();
  assert(preapproved.commits == 0 && preapproved.prompt.prompts == 1);
  preapproved.OnInstallPromptDone({ExtensionInstallPromptClient::Result::USER_CANCELED});

  // Every captured field participates in the actual production one-use policy.
  for (int field = 0; field != 6; ++field) {
    arx::ExtensionInstallAuthority proof("profile", 7, "sha256", "id", "2.0", 11);
    assert(!proof.Consume(field == 0 ? "other" : "profile", field == 1 ? 8 : 7,
        field == 2 ? "other" : "sha256", field == 3 ? "other" : "id",
        field == 4 ? "other" : "2.0", field == 5 ? 12 : 11));
    if (field != 5) assert(!proof.Consume("profile", 7, "sha256", "id", "2.0", 11));
  }
  arx::ExtensionInstallAuthority proof("profile", 7, "sha256", "id", "2.0", 11);
  assert(proof.Consume("profile", 7, "sha256", "id", "2.0", 11));
  assert(!proof.Consume("profile", 7, "sha256", "id", "2.0", 11));
  arx::ExtensionInstallAuthority dismissed("profile", 7, "sha256", "id", "2.0", 12);
  dismissed.Invalidate();
  assert(!dismissed.Consume("profile", 7, "sha256", "id", "2.0", 12));
}
