"""Unread badges from the Badging API (DEV-907).

Chromium keeps `navigator.setAppBadge()` for installed web apps: a page that
isn't one reaches `BadgeManager::SetBadge`, finds no app to badge, and the call
does nothing. This hands every frame's report to Arx first, which shows it on
the page's tab and Favorite. Installed-app badging is unchanged. Service
worker contexts have no tab and report nothing. Anchors fail closed against the
pinned Chromium.
"""
from .overlay import replace_once

HEADER = "chrome/browser/badging/badge_manager.h"
SOURCE = "chrome/browser/badging/badge_manager.cc"


def patches():
    yield HEADER, """    virtual std::vector<std::tuple<webapps::AppId, GURL>>
    GetAppIdsAndUrlsForBadging() const = 0;
  };""", """    virtual std::vector<std::tuple<webapps::AppId, GURL>>
    GetAppIdsAndUrlsForBadging() const = 0;

    // Arx: hands a badge report to the embedder for its frame's tab. nullopt
    // clears the badge; a value as SetBadge takes it.
    virtual void ArxReportBadge(std::optional<BadgeValue> value) const {}
  };"""
    yield HEADER, """    std::vector<std::tuple<webapps::AppId, GURL>> GetAppIdsAndUrlsForBadging()
        const override;

   private:
    const content::GlobalRenderFrameHostId frame_id_;""", """    std::vector<std::tuple<webapps::AppId, GURL>> GetAppIdsAndUrlsForBadging()
        const override;
    void ArxReportBadge(std::optional<BadgeValue> value) const override;

   private:
    const content::GlobalRenderFrameHostId frame_id_;"""
    yield SOURCE, '#include "chrome/browser/badging/badge_manager_factory.h"', (
        '#include "chrome/browser/badging/badge_manager_factory.h"\n'
        '#include "chrome/browser/arx/engine_bridge.h"\n'
        '#include "content/public/browser/web_contents.h"')
    yield SOURCE, """  // Convert the mojo badge representation into a BadgeManager::BadgeValue.
  BadgeValue value = mojo_value->is_flag()
                         ? std::nullopt
                         : std::make_optional(mojo_value->get_number());
""", """  // Convert the mojo badge representation into a BadgeManager::BadgeValue.
  BadgeValue value = mojo_value->is_flag()
                         ? std::nullopt
                         : std::make_optional(mojo_value->get_number());
  receivers_.current_context()->ArxReportBadge(std::make_optional(value));
"""
    yield SOURCE, """void BadgeManager::ClearBadge() {
  const std::vector<std::tuple<webapps::AppId, GURL>> app_ids_and_urls =
      receivers_.current_context()->GetAppIdsAndUrlsForBadging();
""", """void BadgeManager::ClearBadge() {
  receivers_.current_context()->ArxReportBadge(std::nullopt);
  const std::vector<std::tuple<webapps::AppId, GURL>> app_ids_and_urls =
      receivers_.current_context()->GetAppIdsAndUrlsForBadging();
"""
    yield SOURCE, """std::vector<std::tuple<webapps::AppId, GURL>>
BadgeManager::FrameBindingContext::GetAppIdsAndUrlsForBadging() const {""", """void BadgeManager::FrameBindingContext::ArxReportBadge(
    std::optional<BadgeValue> value) const {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  content::RenderFrameHost* frame = content::RenderFrameHost::FromID(frame_id_);
  // Only a tab's own main document speaks for it.
  if (!frame || frame->GetParentOrOuterDocument() ||
      frame->GetStorageKey().IsThirdPartyContext()) {
    return;
  }
  if (auto* contents = content::WebContents::FromRenderFrameHost(frame)) {
    arx::PageBadgeChanged(contents, value.has_value(),
                          value.has_value() ? value->value_or(0) : 0,
                          value.has_value() && !value->has_value());
  }
}

std::vector<std::tuple<webapps::AppId, GURL>>
BadgeManager::FrameBindingContext::GetAppIdsAndUrlsForBadging() const {"""


def apply(source):
    for relative, before, after in patches():
        replace_once(source / relative, before, after)
