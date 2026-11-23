import { LaunchProps, showHUD } from "@raycast/api";
import { openLittleArx, webAddress } from "./arx";

export default async function NewLittleArx(props: LaunchProps<{ arguments: { url?: string } }>) {
  const typed = props.arguments.url ?? "";
  const url = webAddress(typed);
  if (typed.trim() && !url) {
    await showHUD("Arx opens only web pages");
    return;
  }
  await openLittleArx(url);
}
