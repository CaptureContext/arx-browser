import { Action, ActionPanel, closeMainWindow, Form, showToast, Toast } from "@raycast/api";
import { usePromise } from "@raycast/utils";
import { listSpaces, openInSpace, webAddress } from "./arx";

interface Values {
  url: string;
  space: string;
}

export default function OpenInSpace() {
  const { data: spaces, isLoading } = usePromise(listSpaces);

  async function submit(values: Values) {
    const url = webAddress(values.url);
    if (!url) {
      await showToast({ style: Toast.Style.Failure, title: "Arx opens only web pages" });
      return;
    }
    await openInSpace(url, values.space || undefined);
    await closeMainWindow();
  }

  return (
    <Form
      isLoading={isLoading}
      actions={
        <ActionPanel>
          <Action.SubmitForm title="Open in Arx" onSubmit={submit} />
        </ActionPanel>
      }
    >
      <Form.TextField id="url" title="Page" placeholder="example.com" />
      <Form.Dropdown id="space" title="Space">
        <Form.Dropdown.Item value="" title="Where Air Traffic Control sends it" />
        {(spaces ?? []).map((space) => (
          <Form.Dropdown.Item key={space.id} value={space.id} title={`${space.name} (${space.profile})`} />
        ))}
      </Form.Dropdown>
    </Form>
  );
}
