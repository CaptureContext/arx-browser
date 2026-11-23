"""Pinned keypress defaults retain exact control/selection after author callbacks."""

from .config import PACKAGE

GUARD = '#include "third_party/blink/renderer/core/input/arx_keypress_guard.h"\n'


def patches():
    files = (
        "dom/events/event_dispatcher.cc", "editing/editor_key_bindings.cc",
        "editing/commands/editor_command.cc", "editing/commands/typing_command.cc",
        "editing/frame_selection.cc", "html/forms/html_input_element.cc", "input/keyboard_event_manager.cc",
    )
    prefix = "third_party/blink/renderer/core/"
    result = [(prefix + name, '#include "' + prefix + ("editing/editor" if name == "editing/editor_key_bindings.cc" else name[:-3]) + '.h"',
               '#include "' + prefix + ("editing/editor" if name == "editing/editor_key_bindings.cc" else name[:-3]) + '.h"\n' + GUARD) for name in files]
    # Author script is intentionally outside default-action authority, including
    # nested events raised by a key/beforeinput/textInput listener.
    result += [
        (prefix + files[0], "DispatchEventResult EventDispatcher::Dispatch() {",
         "DispatchEventResult EventDispatcher::Dispatch() {\n"
         "  ArxKeypressGuard::AuthorDispatch arx_author_dispatch;"),
        (prefix + files[0], "  // Call default event handlers. While the DOM does have a concept of\n",
         "  ArxKeypressGuard::DefaultAction arx_default(event_);\n"
         "  if (!arx_default.allowed()) event_->SetDefaultHandled();\n"
         "  // Call default event handlers. While the DOM does have a concept of\n"),
        (prefix + files[0], "        Node& node = path[i].GetNode();\n"
         "        node.DefaultEventHandler(*event_);",
         "        if (!ArxKeypressGuard::BeforeDefault(event_)) {\n"
         "          event_->SetDefaultHandled();\n"
         "          break;\n"
         "        }\n"
         "        Node& node = path[i].GetNode();\n"
         "        node.DefaultEventHandler(*event_);"),
        (prefix + files[1], "  if (frame_->Client()->HandleCurrentKeyboardEvent() ||",
         "  if ((!ArxKeypressGuard::IsGuardedEvent(evt) &&\n"
         "       frame_->Client()->HandleCurrentKeyboardEvent()) ||"),
        (prefix + files[1], "  return InsertText(key_event->text.data(), evt);",
         "  if (!ArxKeypressGuard::BeforeEdit()) return true;\n"
         "  return InsertText(key_event->text.data(), evt);"),
        (prefix + files[2], "  return command_->execute(*frame_, triggering_event, source_, parameter);",
         "  if (!ArxKeypressGuard::BeforeEdit()) return true;\n"
         "  return command_->execute(*frame_, triggering_event, source_, parameter);"),
        (prefix + files[3], "  const PlainTextRange selection_offsets = GetSelectionOffsets(\n",
         "  ABORT_EDITING_COMMAND_IF(!ArxKeypressGuard::BeforeEdit());\n"
         "  const PlainTextRange selection_offsets = GetSelectionOffsets(\n"),
        (prefix + files[3], "  // event/filtering may invalidate frame or selection\n",
         "  if (!ArxKeypressGuard::BeforeEdit()) {\n"
         "    editing_state->Abort();\n"
         "    return false;\n"
         "  }\n"
         "  // event/filtering may invalidate frame or selection\n"),
        (prefix + files[4], "  // |DispatchSelectStart()| can change document hosted by |frame_|.\n",
         "  if (!ArxKeypressGuard::BeforeEdit()) return false;\n"
         "  // |DispatchSelectStart()| can change document hosted by |frame_|.\n"),
        (prefix + files[5], "    HTMLFormElement* form_for_submission =\n",
         "    if (!ArxKeypressGuard::BeforeEdit()) {\n"
         "      evt.SetDefaultHandled();\n"
         "      return;\n"
         "    }\n"
         "    HTMLFormElement* form_for_submission =\n"),
        (prefix + files[6], "    // Do not perform the default action when inside a IME composition context.\n",
         "    // An explicit field key never acquires page/focus navigation fallback.\n"
         "    if (ArxKeypressGuard::IsGuardedEvent(event)) {\n"
         "      ArxKeypressGuard::MarkFallbackHandled(event);\n"
         "      event->SetDefaultHandled();\n"
         "      return;\n"
         "    }\n"
         "    // Do not perform the default action when inside a IME composition context.\n"),
        (prefix + files[6], "    if (event->key() == keywords::kCapitalEnter) {\n"
         "      DefaultEnterEventHandler(event);\n"
         "    } else if (event->charCode() == ' ') {",
         "    if (ArxKeypressGuard::IsGuardedEvent(event)) {\n"
         "      ArxKeypressGuard::MarkFallbackHandled(event);\n"
         "      event->SetDefaultHandled();\n"
         "      return;\n"
         "    }\n"
         "    if (event->key() == keywords::kCapitalEnter) {\n"
         "      DefaultEnterEventHandler(event);\n"
         "    } else if (event->charCode() == ' ') {"),
        (prefix + "input/build.gni", '  "keyboard_event_manager.cc",',
         '  "arx_keypress_guard.cc",\n  "arx_keypress_guard.h",\n  "keyboard_event_manager.cc",'),
    ]
    relative = prefix + "exported/web_form_control_element.cc"
    result += [
        (relative, '#include "third_party/blink/renderer/core/html/forms/html_form_control_element.h"',
         '#include "third_party/blink/renderer/core/html/forms/html_form_control_element.h"\n'
         '#include "third_party/blink/public/web/arx_keypress_actions.h"\n' + GUARD +
         '#include "third_party/blink/public/common/input/web_keyboard_event.h"\n'
         '#include "third_party/blink/renderer/core/events/keyboard_event.h"\n'
         '#include "third_party/blink/renderer/core/editing/editing_utilities.h"\n'
         '#include "third_party/blink/renderer/core/editing/frame_selection.h"\n'
         '#include "third_party/blink/renderer/core/editing/selection_template.h"\n'
         '#include "third_party/blink/renderer/core/page/spatial_navigation.h"\n'
         '#include "third_party/blink/renderer/core/editing/ime/input_method_controller.h"\n'
         '#include "ui/events/keycodes/dom/dom_key.h"\n'
         '#include "ui/events/keycodes/keyboard_codes.h"\n'),
        (relative, "void WebFormControlElement::DispatchFocusEvent() {",
         (PACKAGE / "Native/inspection/keypress_action_helper.inc").read_text()
         + "void WebFormControlElement::DispatchFocusEvent() {"),
        ("third_party/blink/public/BUILD.gn", '    "web/web_input_element.h",',
         '    "web/web_input_element.h",\n    "web/arx_keypress_actions.h",'),
    ]
    return result


def upgrade_previous(source):
    """Replace complete installed blocks before their nested upstream anchors."""
    current_continuation = '''  const bool character_continuation = down == DispatchEventResult::kNotCanceled ||
      (down == DispatchEventResult::kCanceledByDefaultEventHandler && guard.fallback_handled());
  if ((key.character || key.virtual_key == ui::VKEY_RETURN) && character_continuation) {'''
    previous_continuation = '''  if ((key.character || key.virtual_key == ui::VKEY_RETURN) && down == DispatchEventResult::kNotCanceled) {'''
    upgrades = {}
    for relative, old, new in patches():
        if old == "void WebFormControlElement::DispatchFocusEvent() {":
            if new.count(current_continuation) != 1:
                raise ValueError("Keypress continuation upgrade contract changed")
            previous = new.replace(current_continuation, previous_continuation, 1)
            marker = "ArxKeypressResult PerformKeypressForArxInspection("
        elif relative.endswith("keyboard_event_manager.cc") and "SetDefaultHandled" in new:
            previous = new.replace("      ArxKeypressGuard::MarkFallbackHandled(event);\n", "")
            marker = "    if (ArxKeypressGuard::IsGuardedEvent(event)) {"
        else:
            continue
        upgrades.setdefault(relative, []).append((previous, new, marker))
    for relative, blocks in upgrades.items():
        path = source / relative
        contents = path.read_text()
        recognized = 0
        for previous, new, _ in blocks:
            count = contents.count(previous) + contents.count(new)
            if count > 1:
                raise ValueError(f"Engine overlay anchor changed: {path} (duplicate keypress block)")
            recognized += count
        # A pristine or interrupted fresh application may contain fewer blocks,
        # but every installed guard/helper must be one exact known version.
        if contents.count(blocks[0][2]) != recognized:
            raise ValueError(f"Engine overlay anchor changed: {path} (installed keypress block)")
        updated = contents
        for previous, new, _ in blocks:
            if previous in updated:
                updated = updated.replace(previous, new, 1)
        if updated != contents:
            path.write_text(updated)


def write_guard(source):
    directory = source / "third_party/blink/renderer/core/input"
    (directory / "arx_keypress_guard.h").write_text((PACKAGE / "Native/inspection/keypress_guard_contract.h").read_text())
    (directory / "arx_keypress_guard.cc").write_text(
        GUARD + '#include "third_party/blink/renderer/core/dom/events/event.h"\n'
        + (PACKAGE / "Native/inspection/keypress_guard_impl.inc").read_text())
    public = source / "third_party/blink/public/web/arx_keypress_actions.h"
    public.write_text((PACKAGE / "Native/inspection/keypress_action_contract.h").read_text())
