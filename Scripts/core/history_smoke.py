"""Verify app-owned history after the disposable signed browser has exited."""

import json
from pathlib import Path
import sqlite3
from urllib.parse import urljoin

# With the `ARX_SQLITE_WORKSPACE` feature flag on, the default since DEV-1143, history is kept in
# this database beside the workspace (DEV-984) and the JSON files are left as they were.
DATABASE = "arx-history.sqlite"


def database_urls(path: Path):
    """Every address the database keeps: this Mac's entries, and the visits mirrored for sync."""
    connection = sqlite3.connect(path)
    try:
        return [url for table in ("historyEntry", "historyVisit")
                for (url,) in connection.execute(f'SELECT "url" FROM "{table}"')]
    finally:
        connection.close()


def verify(profile: Path, base_url: str):
    files = list((profile / "History").glob("*.json"))
    database = profile / DATABASE
    if not files and not database.is_file():
        raise ValueError("Profile-history smoke did not persist an index")
    ordinary = base_url + "?arx_history_smoke=ordinary"
    # A Little Arx page is an ordinary page of its profile (DEV-728); its Peeks aren't.
    little = base_url + "?arx_history_smoke=temporary"
    forbidden = {
        base_url + "?arx_history_smoke=private",
        # A Full preview's page of its own (DEV-730).
        base_url + "?arx_hover_preview_smoke=full",
        base_url + "?peek=temporary",
        urljoin(base_url, "mcp-private.html"),
        urljoin(base_url, "little-peek.html?phase=dismiss"),
        urljoin(base_url, "little-peek.html?phase=promote-start"),
    }
    urls = []
    for file in files:
        document = json.loads(file.read_text())
        if document.get("version") != 1:
            raise ValueError("Unexpected profile-history format")
        urls.extend(entry["url"] for entry in document["snapshot"]["entries"])
    if database.is_file():
        urls.extend(database_urls(database))
    if ordinary not in urls:
        raise ValueError("Ordinary fixture visit is missing from persisted history")
    if little not in urls:
        raise ValueError("Little Arx fixture visit is missing from persisted history")
    if forbidden.intersection(urls):
        raise ValueError("Private or temporary fixture leaked into persisted history")
