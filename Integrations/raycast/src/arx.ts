import { open } from "@raycast/api";
import { runAppleScript } from "@raycast/utils";

/** One tab as Arx's AppleScript dictionary lists it. */
export interface ArxTab {
  id: string;
  title: string;
  url: string;
  space: string;
  profile: string;
  pinned: boolean;
  active: boolean;
}

export interface ArxSpace {
  id: string;
  name: string;
  profile: string;
}

const separator = "\u001f";
const lineSeparator = "\u001e";

/** Reads every tab Arx lists (never a private window's), one record per line. */
export async function listTabs(): Promise<ArxTab[]> {
  const output = await runAppleScript(`
    set output to ""
    tell application "Arx"
      repeat with t in tabs
        set output to output & (id of t) & "${separator}" & (title of t) & "${separator}" & (URL of t) & "${separator}" & (space of t) & "${separator}" & (profile of t) & "${separator}" & (pinned of t) & "${separator}" & (active of t) & "${lineSeparator}"
      end repeat
    end tell
    return output
  `);
  return records(output).map(([id, title, url, space, profile, pinned, active]) => ({
    id,
    title,
    url,
    space,
    profile,
    pinned: pinned === "true",
    active: active === "true",
  }));
}

export async function listSpaces(): Promise<ArxSpace[]> {
  const output = await runAppleScript(`
    set output to ""
    tell application "Arx"
      repeat with s in spaces
        set output to output & (id of s) & "${separator}" & (name of s) & "${separator}" & (profile of s) & "${lineSeparator}"
      end repeat
    end tell
    return output
  `);
  return records(output).map(([id, name, profile]) => ({ id, name, profile }));
}

/** Brings Arx forward with the tab, in its space. */
export async function showTab(id: string): Promise<void> {
  await runAppleScript(`tell application "Arx" to show tab (tab id ${quoted(id)})`);
}

/** Opens a page in a space through Arx's arx:// link. */
export async function openInSpace(url: string, space?: string): Promise<void> {
  const query = new URLSearchParams({ url });
  if (space) query.set("space", space);
  await open(`arx://open?${query.toString()}`);
}

export async function openLittleArx(url?: string): Promise<void> {
  const query = url ? `?${new URLSearchParams({ url }).toString()}` : "";
  await open(`arx://little${query}`);
}

/** A typed page as an http(s) address: "example.com" becomes "https://example.com". */
export function webAddress(text: string): string | undefined {
  const trimmed = text.trim();
  if (!trimmed) return undefined;
  const candidate = /^[a-z][a-z0-9+.-]*:/i.test(trimmed) ? trimmed : `https://${trimmed}`;
  try {
    const url = new URL(candidate);
    return url.protocol === "http:" || url.protocol === "https:" ? url.toString() : undefined;
  } catch {
    return undefined;
  }
}

function records(output: string): string[][] {
  return output
    .split(lineSeparator)
    .filter((line) => line.length > 0)
    .map((line) => line.split(separator));
}

function quoted(text: string): string {
  return `"${text.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
}
