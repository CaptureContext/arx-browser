// Copyright 2012 The Chromium Authors
// Use of this source code is governed by a BSD-style license.
// Pinned upstream: Chromium 156.0.8078.47, commit 9aa975a56de8c2376d7c22f71da564b9426cda5f.
void ExternalProtocolDialog::OnDialogAccepted() {
  const bool remember = message_box_view_->IsCheckBoxSelected();
  ExternalProtocolHandler::RecordHandleStateMetrics(
      remember, ExternalProtocolHandler::DONT_BLOCK);

  if (!web_contents_) {
    // Dialog outlasted the WebContents.
    return;
  }

  if (remember) {
    DCHECK(initiating_origin_);
    Profile* profile =
        Profile::FromBrowserContext(web_contents_->GetBrowserContext());

    ExternalProtocolHandler::SetBlockState(
        url_.GetScheme(), *initiating_origin_,
        ExternalProtocolHandler::DONT_BLOCK, profile);
  }

  ExternalProtocolHandler::LaunchUrlWithoutSecurityCheck(
      url_, web_contents_.get(), initiator_document_);
}
