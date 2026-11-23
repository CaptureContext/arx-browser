import { Action, ActionPanel, Icon, List, showToast, Toast } from "@raycast/api";
import { getFavicon, usePromise } from "@raycast/utils";
import { ArxTab, listTabs, showTab } from "./arx";

export default function SearchTabs() {
  const { data: tabs, isLoading, error } = usePromise(listTabs);

  if (error) {
    showToast({ style: Toast.Style.Failure, title: "Arx isn't running", message: error.message });
  }

  return (
    <List isLoading={isLoading} searchBarPlaceholder="Search Arx tabs by title or address">
      {(tabs ?? []).map((tab) => (
        <List.Item
          key={tab.id}
          icon={getFavicon(tab.url, { fallback: Icon.Globe })}
          title={tab.title || tab.url}
          subtitle={tab.url}
          keywords={[tab.url, tab.space, tab.profile]}
          accessories={accessories(tab)}
          actions={
            <ActionPanel>
              <Action title="Show in Arx" icon={Icon.ArrowRight} onAction={() => showTab(tab.id)} />
              <Action.CopyToClipboard title="Copy Address" content={tab.url} />
            </ActionPanel>
          }
        />
      ))}
    </List>
  );
}

function accessories(tab: ArxTab): List.Item.Accessory[] {
  const items: List.Item.Accessory[] = [];
  if (tab.active) items.push({ icon: Icon.Eye, tooltip: "Shown" });
  if (tab.pinned) items.push({ icon: Icon.Pin, tooltip: "Pinned" });
  items.push({ text: tab.space || tab.profile });
  return items;
}
