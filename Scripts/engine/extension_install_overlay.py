"""Require a verified candidate prompt before Arx's explicit CRX updates.

Chrome's Settings update path otherwise installs first and asks only about
re-enabling increased permissions. The opt-in retains the same CRX3 verifier,
policy checks, expected ID and installed location, but uses the existing normal
pre-install client callback. Ordinary Settings and automatic updates are unchanged.
"""

from .overlay import replace_once


def patches():
    return (
        ("extensions/browser/crx_installer.h",
         "  void set_allow_silent_install(bool val) { allow_silent_install_ = val; }",
         "  void set_allow_silent_install(bool val) { allow_silent_install_ = val; }\n\n"
         "  // An explicit embedder CRX update must ask about the verified candidate\n"
         "  // before replacing the installed package, not only re-enable afterward.\n"
         "  void set_require_verified_install_prompt(bool val) {\n"
         "    require_verified_install_prompt_ = val;\n"
         "  }"),
        ("extensions/browser/crx_installer.h",
         "  bool allow_silent_install_;",
         "  bool allow_silent_install_;\n"
         "  bool require_verified_install_prompt_ = false;"),
        ("extensions/browser/crx_installer.cc",
         "  if (was_triggered_by_user_download() && !client_ && !approved_) {",
         "  if ((require_verified_install_prompt_ ||\n"
         "       (was_triggered_by_user_download() && !approved_)) && !client_) {"),
        ("extensions/browser/crx_installer.cc",
         "  if (client_ && (!allow_silent_install_ || !approved_) &&\n"
         "      !update_from_settings_page_) {",
         "  if (client_ && (require_verified_install_prompt_ || !allow_silent_install_ || !approved_) &&\n"
         "      !update_from_settings_page_) {"),
        ("extensions/browser/crx_installer.cc",
         "    update_from_settings_page_ = true;\n"
         "    expected_id_ = installed_extension->id();",
         "    // Preserve identity/location below while opting into ConfirmInstall's\n"
         "    // normal pre-install consent and cancellation path for this embedder.\n"
         "    update_from_settings_page_ = !require_verified_install_prompt_;\n"
         "    expected_id_ = installed_extension->id();"),
        ("extensions/browser/crx_installer.cc",
         "        NotifyCrxInstallComplete(CrxInstallError(\n"
         "            CrxInstallErrorType::OTHER, CrxInstallErrorDetail::USER_CANCELED));",
         "        NotifyCrxInstallComplete(CrxInstallError(\n"
         "            CrxInstallErrorType::OTHER, CrxInstallErrorDetail::USER_CANCELED));\n"
         "        if (require_verified_install_prompt_) CleanupTempFiles();"),
        ("extensions/browser/crx_installer.cc",
         "        NotifyCrxInstallComplete(CrxInstallError(\n"
         "            CrxInstallErrorType::OTHER, CrxInstallErrorDetail::USER_ABORTED));",
         "        NotifyCrxInstallComplete(CrxInstallError(\n"
         "            CrxInstallErrorType::OTHER, CrxInstallErrorDetail::USER_ABORTED));\n"
         "        if (require_verified_install_prompt_) CleanupTempFiles();"),
    )


def apply(source):
    for relative, before, after in patches():
        replace_once(source / relative, before, after)
