// Copyright 2012 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the pinned Chromium LICENSE file.

// Pinned Chromium production methods used by the pre-install consent seam test.

void CrxInstaller::CheckUpdateFromSettingsPage() {
  DCHECK_CURRENTLY_ON(BrowserThread::UI);

  if (!browser_context_) {
    return;
  }

  if (off_store_install_allow_reason_ !=
      OffStoreInstallAllowedFromSettingsPage) {
    return;
  }

  const Extension* installed_extension =
      ExtensionRegistry::Get(browser_context_)
          ->GetInstalledExtension(extension()->id());
  if (installed_extension) {
    // Previous version of the extension exists.
    update_from_settings_page_ = true;
    expected_id_ = installed_extension->id();
    install_source_ = installed_extension->location();
  }
}

void CrxInstaller::ConfirmInstall() {
  DCHECK_CURRENTLY_ON(BrowserThread::UI);
  ReportInstallationStage(InstallationStage::kFinalizing);

  if (!browser_context_) {
    return;
  }

  if (KioskModeInfo::IsKioskOnly(extension())) {
    bool in_kiosk_mode = false;
#if BUILDFLAG(IS_CHROMEOS)
    user_manager::UserManager* user_manager = user_manager::UserManager::Get();
    in_kiosk_mode = user_manager && user_manager->IsLoggedInAsKioskChromeApp();
#endif
    if (!in_kiosk_mode) {
      ReportFailureFromUIThread(CrxInstallError(
          CrxInstallErrorType::DECLINED, CrxInstallErrorDetail::KIOSK_MODE_ONLY,
          l10n_util::GetStringUTF16(IDS_EXTENSION_INSTALL_KIOSK_MODE_ONLY)));
      return;
    }
  }

  // Check whether this install is initiated from the settings page to
  // update an existing extension or app.
  CheckUpdateFromSettingsPage();

  GURL overlapping_url;
  ExtensionRegistry* registry = ExtensionRegistry::Get(browser_context_);
  const Extension* overlapping_extension =
      registry->enabled_extensions().GetHostedAppByOverlappingWebExtent(
          extension()->web_extent());
  if (overlapping_extension &&
      overlapping_extension->id() != extension()->id()) {
    ReportFailureFromUIThread(
        CrxInstallError(CrxInstallErrorType::OTHER,
                        CrxInstallErrorDetail::OVERLAPPING_WEB_EXTENT,
                        l10n_util::GetStringFUTF16(
                            IDS_EXTENSION_OVERLAPPING_WEB_EXTENT,
                            base::UTF8ToUTF16(extension()->name()),
                            base::UTF8ToUTF16(overlapping_extension->name()))));
    return;
  }

  current_version_ = base::Version(ExtensionPrefs::Get(browser_context_)
                                       ->GetVersionString(extension()->id()));

  // User-downloaded installations require an install prompt client to confirm
  // permissions unless pre-approved (e.g. from the webstore). If no prompt
  // client is available (for example, if no browser window or tab is open),
  // abort the install to avoid installing the extension silently. Non-user
  // download flows (such as external providers) have their own separate
  // acknowledgment lifecycles and may use CreateSilent() without a client.
  if (was_triggered_by_user_download() && !client_ && !approved_) {
    ReportFailureFromUIThread(CrxInstallError(
        CrxInstallErrorType::OTHER, CrxInstallErrorDetail::USER_ABORTED));
    return;
  }

  if (client_ && (!allow_silent_install_ || !approved_) &&
      !update_from_settings_page_) {
    AddRef();  // Balanced in OnInstallPromptDone().
    client_->ConfirmInstall(
        base::BindOnce(&CrxInstaller::OnInstallPromptDone, this), extension());
  } else {
    UpdateCreationFlagsAndCompleteInstall(kDontWithholdPermissions);
  }
}

void CrxInstaller::OnInstallPromptDone(
    ExtensionInstallPromptClient::DoneCallbackPayload payload) {
  DCHECK_CURRENTLY_ON(BrowserThread::UI);

  // If update_from_settings_page_ boolean is true, this functions is
  // getting called in response to ExtensionInstallPrompt::ConfirmReEnable()
  // and if it is false, this function is called in response to
  // ExtensionInstallPrompt::ShowDialog().

  switch (payload.result) {
    case ExtensionInstallPromptClient::Result::ACCEPTED:
    case ExtensionInstallPromptClient::Result::
        ACCEPTED_WITH_WITHHELD_PERMISSIONS:
      if (!browser_context_) {
        return;
      }

      // Install (or re-enable) the extension with full permissions.
      if (update_from_settings_page_) {
        // TODO(crbug.com/40636075): Add support for withholding permissions on
        // the re-enable prompt here once we know how that should be handled.
        DCHECK_NE(payload.result, ExtensionInstallPromptClient::Result::
                                      ACCEPTED_WITH_WITHHELD_PERMISSIONS);
        registrar_->GrantPermissionsAndEnableExtension(*extension());
      } else {
        WithholdingBehavior withholding_behavior =
            payload.result == ExtensionInstallPromptClient::Result::
                                  ACCEPTED_WITH_WITHHELD_PERMISSIONS
                ? kWithholdPermissions
                : kDontWithholdPermissions;
        UpdateCreationFlagsAndCompleteInstall(withholding_behavior);
      }
      break;

    case ExtensionInstallPromptClient::Result::USER_CANCELED:
      if (!update_from_settings_page_) {
        NotifyCrxInstallComplete(CrxInstallError(
            CrxInstallErrorType::OTHER, CrxInstallErrorDetail::USER_CANCELED));
      }
      break;
    case ExtensionInstallPromptClient::Result::ABORTED:
      if (!update_from_settings_page_) {
        NotifyCrxInstallComplete(CrxInstallError(
            CrxInstallErrorType::OTHER, CrxInstallErrorDetail::USER_ABORTED));
      }
      break;
  }

  Release();  // balanced in ConfirmInstall() or ConfirmReEnable().
}
