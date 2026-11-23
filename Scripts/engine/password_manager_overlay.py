"""Chromium's password manager for Arx's ordinary profiles (DEV-708).

- Helium's `DisabledPasswordManagerPolicyHandler` stops forcing
  `credentials_enable_service` off. It still forces passkeys off (DEV-558).
- Arx's native target may use `actor_login`'s delegate, which fills a saved
  password in the browser and renderer and returns only an outcome.
- `ChromePasswordManagerClient` hands save and update offers to an embedder
  hook. Arx has no Chrome password bubble, so without the hook nothing could
  ever be saved.

Each patch anchors on an upstream or Helium line only.
"""

from .overlay import replace_once

POLICY = "chrome/browser/policy/configuration_policy_handler_list_factory.cc"
ACTOR_LOGIN = "components/password_manager/core/browser/actor_login/internal/BUILD.gn"
CLIENT_HEADER = "chrome/browser/password_manager/chrome_password_manager_client.h"
CLIENT_SOURCE = "chrome/browser/password_manager/chrome_password_manager_client.cc"

SAVE_PROMPT_SIGNATURE = (
    "bool ChromePasswordManagerClient::PromptUserToSaveOrUpdatePassword(\n"
    "    std::unique_ptr<password_manager::PasswordFormManagerForUI> form_to_save,\n"
    "    bool update_password) {\n")


def patches():
    yield (POLICY,
           "    prefs->SetBoolean(password_manager::prefs::kCredentialsEnableService,\n"
           "                      false);\n",
           "    // Arx: passwords stay available per ordinary profile (DEV-708).\n")
    yield (ACTOR_LOGIN,
           '    "//components/password_manager/core/browser/actor_login:*",\n'
           '    "//components/password_manager/core/browser/actor_login/test:*",\n',
           '    "//components/password_manager/core/browser/actor_login:*",\n'
           '    "//components/password_manager/core/browser/actor_login/test:*",\n'
           '    "//chrome/browser/arx:*",\n')
    yield (CLIENT_HEADER,
           "  static void CreateForWebContents(content::WebContents* contents);\n",
           "  static void CreateForWebContents(content::WebContents* contents);\n"
           "  // Arx (DEV-708): an embedder without Chrome's password bubbles takes\n"
           "  // every save or update offer. It owns the form manager it is given.\n"
           "  using EmbedderSavePrompt = base::RepeatingCallback<bool(\n"
           "      content::WebContents*,\n"
           "      std::unique_ptr<password_manager::PasswordFormManagerForUI>,\n"
           "      bool)>;\n"
           "  static void SetEmbedderSavePrompt(EmbedderSavePrompt prompt);\n")
    yield (CLIENT_SOURCE,
           '#include "chrome/browser/password_manager/chrome_password_manager_client.h"\n',
           '#include "chrome/browser/password_manager/chrome_password_manager_client.h"\n'
           '#include "base/no_destructor.h"\n')
    yield (CLIENT_SOURCE, SAVE_PROMPT_SIGNATURE,
           "static ChromePasswordManagerClient::EmbedderSavePrompt& ArxEmbedderSavePrompt() {\n"
           "  static base::NoDestructor<ChromePasswordManagerClient::EmbedderSavePrompt> prompt;\n"
           "  return *prompt;\n"
           "}\n\n"
           "// static\n"
           "void ChromePasswordManagerClient::SetEmbedderSavePrompt(\n"
           "    EmbedderSavePrompt prompt) {\n"
           "  ArxEmbedderSavePrompt() = std::move(prompt);\n"
           "}\n\n" +
           SAVE_PROMPT_SIGNATURE +
           "  if (ArxEmbedderSavePrompt()) {\n"
           "    auto prompt = ArxEmbedderSavePrompt();\n"
           "    return prompt.Run(web_contents(), std::move(form_to_save),\n"
           "                      update_password);\n"
           "  }\n")


def apply(source):
    for relative, old, new in patches():
        replace_once(source / relative, old, new)
