"""Render and write workspace references without changing user workspace settings."""

import xml.etree.ElementTree as XML


def contents(groups):
    workspace = XML.Element("Workspace", version="1.0")
    for path in groups:
        XML.SubElement(workspace, "FileRef", location=f"group:{path}")
    XML.indent(workspace, space="  ")
    return XML.tostring(workspace, encoding="UTF-8", xml_declaration=True) + b"\n"


def generate(root, *, name, groups):
    destination = root / f"{name}.xcworkspace/contents.xcworkspacedata"
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(contents(groups))
