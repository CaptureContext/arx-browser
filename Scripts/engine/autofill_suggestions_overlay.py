"""Arx draws Chromium's autofill suggestions itself (DEV-875, DEV-893).

- `ChromeAutofillClient` hands every suggestion list (saved passwords,
  addresses, payment cards) to an embedder before Chrome's Views popup. Arx has
  no Chrome browser window to attach that popup to, so without the hook a
  focused sign-in or checkout field offers nothing.
- With an embedder installed, Chrome's address and local card save bubbles
  are answered "ignored": Arx adds addresses and cards in Settings and never
  shows a Chrome bubble outside a Chrome window.

Each patch anchors on an upstream line only.
"""

from .overlay import replace_once

CLIENT_HEADER = "chrome/browser/ui/autofill/chrome_autofill_client.h"
CLIENT_SOURCE = "chrome/browser/ui/autofill/chrome_autofill_client.cc"
PAYMENTS_SOURCE = "chrome/browser/ui/autofill/payments/chrome_payments_autofill_client.cc"

SHOW_SIGNATURE = (
    "AutofillClient::SuggestionUiSessionId\n"
    "ChromeAutofillClient::ShowAutofillSuggestions(\n"
    "    const PopupOpenArgs& open_args,\n"
    "    base::WeakPtr<AutofillSuggestionDelegate> delegate) {\n")
SUGGESTIONS_SIGNATURE = (
    "base::span<const Suggestion> ChromeAutofillClient::GetAutofillSuggestions()\n"
    "    const {\n")
SESSION_SIGNATURE = (
    "std::optional<AutofillClient::SuggestionUiSessionId>\n"
    "ChromeAutofillClient::GetSessionIdForCurrentAutofillSuggestions() const {\n")
UPDATE_SIGNATURE = (
    "void ChromeAutofillClient::UpdateAutofillSuggestions(\n"
    "    const std::vector<Suggestion>& suggestions,\n"
    "    FillingProduct main_filling_product,\n"
    "    AutofillSuggestionTriggerSource trigger_source,\n"
    "    AutofillSuggestionsIgnoreFocusLoss ignore_focus_loss) {\n")
HIDE_SIGNATURE = (
    "void ChromeAutofillClient::HideSuggestions(\n"
    "    SuggestionHidingReason reason,\n"
    "    std::optional<FillingProduct> product) {\n")
SAVE_ADDRESS_SIGNATURE = (
    "void ChromeAutofillClient::ConfirmSaveAddressProfile(\n"
    "    const AutofillProfile& profile,\n"
    "    const AutofillProfile* original_profile,\n"
    "    SaveAddressBubbleType save_address_bubble_type,\n"
    "    AddressProfileSavePromptCallback callback) {\n")
SAVE_CARD_SIGNATURE = (
    "void ChromePaymentsAutofillClient::ShowSaveCreditCardLocally(\n"
    "    const CreditCard& card,\n"
    "    SaveCreditCardOptions options,\n"
    "    LocalSaveCardPromptCallback callback) {\n")

EMBEDDER = """  // Arx (DEV-875): an embedder that draws suggestions itself, for every
  // ChromeAutofillClient. It must outlive its installation. Show returns true
  // to take the suggestions, and then reports them and their session until
  // Hide; Chrome's popup stays closed.
  class EmbedderSuggestions {
   public:
    virtual ~EmbedderSuggestions() = default;
    virtual bool Show(content::WebContents* contents,
                      SuggestionUiSessionId session,
                      const PopupOpenArgs& args,
                      base::WeakPtr<AutofillSuggestionDelegate> delegate) = 0;
    // True when the embedder shows suggestions for `contents` and took these.
    virtual bool Update(content::WebContents* contents,
                        const std::vector<Suggestion>& suggestions,
                        FillingProduct product) = 0;
    virtual void Hide(content::WebContents* contents,
                      SuggestionHidingReason reason,
                      std::optional<FillingProduct> product) = 0;
    virtual std::optional<SuggestionUiSessionId> Session(
        const content::WebContents* contents) const = 0;
    virtual base::span<const Suggestion> Suggestions(
        const content::WebContents* contents) const = 0;
  };
  static void SetEmbedderSuggestions(EmbedderSuggestions* embedder);
  static EmbedderSuggestions* GetEmbedderSuggestions();
"""


def patches():
    yield (CLIENT_HEADER,
           "  static void CreateForWebContents(content::WebContents* web_contents);\n",
           "  static void CreateForWebContents(content::WebContents* web_contents);\n\n" + EMBEDDER)
    yield (CLIENT_SOURCE, SHOW_SIGNATURE,
           "namespace {\n"
           "ChromeAutofillClient::EmbedderSuggestions* g_arx_embedder_suggestions = nullptr;\n"
           "}  // namespace\n\n"
           "// static\n"
           "void ChromeAutofillClient::SetEmbedderSuggestions(EmbedderSuggestions* embedder) {\n"
           "  g_arx_embedder_suggestions = embedder;\n"
           "}\n\n"
           "// static\n"
           "ChromeAutofillClient::EmbedderSuggestions*\n"
           "ChromeAutofillClient::GetEmbedderSuggestions() {\n"
           "  return g_arx_embedder_suggestions;\n"
           "}\n\n" +
           SHOW_SIGNATURE +
           "  if (g_arx_embedder_suggestions) {\n"
           "    const SuggestionUiSessionId arx_session =\n"
           "        AutofillSuggestionController::GenerateSuggestionUiSessionId();\n"
           "    if (g_arx_embedder_suggestions->Show(web_contents(), arx_session, open_args,\n"
           "                                         delegate)) {\n"
           "      if (suggestion_controller_) {\n"
           "        suggestion_controller_->Hide(SuggestionHidingReason::kViewDestroyed);\n"
           "      }\n"
           "      return arx_session;\n"
           "    }\n"
           "  }\n")
    yield (CLIENT_SOURCE, SUGGESTIONS_SIGNATURE,
           SUGGESTIONS_SIGNATURE +
           "  if (g_arx_embedder_suggestions &&\n"
           "      g_arx_embedder_suggestions->Session(web_contents())) {\n"
           "    return g_arx_embedder_suggestions->Suggestions(web_contents());\n"
           "  }\n")
    yield (CLIENT_SOURCE, SESSION_SIGNATURE,
           SESSION_SIGNATURE +
           "  if (g_arx_embedder_suggestions) {\n"
           "    if (auto arx_session = g_arx_embedder_suggestions->Session(web_contents())) {\n"
           "      return arx_session;\n"
           "    }\n"
           "  }\n")
    yield (CLIENT_SOURCE, UPDATE_SIGNATURE,
           UPDATE_SIGNATURE +
           "  if (g_arx_embedder_suggestions &&\n"
           "      g_arx_embedder_suggestions->Update(web_contents(), suggestions,\n"
           "                                         main_filling_product)) {\n"
           "    return;\n"
           "  }\n")
    yield (CLIENT_SOURCE, HIDE_SIGNATURE,
           HIDE_SIGNATURE +
           "  if (g_arx_embedder_suggestions) {\n"
           "    g_arx_embedder_suggestions->Hide(web_contents(), reason, product);\n"
           "  }\n")
    yield (CLIENT_SOURCE, SAVE_ADDRESS_SIGNATURE,
           SAVE_ADDRESS_SIGNATURE +
           "  // Arx (DEV-893): no Chrome bubble; addresses are added in Settings.\n"
           "  if (GetEmbedderSuggestions()) {\n"
           "    std::move(callback).Run(AddressPromptUserDecision::kIgnored, std::nullopt);\n"
           "    return;\n"
           "  }\n")
    yield (PAYMENTS_SOURCE,
           '#include "chrome/browser/ui/autofill/payments/chrome_payments_autofill_client.h"\n',
           '#include "chrome/browser/ui/autofill/payments/chrome_payments_autofill_client.h"\n'
           '#include "chrome/browser/ui/autofill/chrome_autofill_client.h"\n')
    yield (PAYMENTS_SOURCE, SAVE_CARD_SIGNATURE,
           SAVE_CARD_SIGNATURE +
           "  // Arx (DEV-893): no Chrome bubble; cards are added in Settings.\n"
           "  if (ChromeAutofillClient::GetEmbedderSuggestions()) {\n"
           "    std::move(callback).Run(SaveCardOfferUserDecision::kIgnored);\n"
           "    return;\n"
           "  }\n")


def apply(source):
    for relative, old, new in patches():
        replace_once(source / relative, old, new)
