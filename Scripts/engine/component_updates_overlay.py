"""Keep certificate revocation data and other security components updating (DEV-874).

Helium routes component update checks through its own services and returns a
dummy host until the person consents on Helium's onboarding page, which Arx
never shows, so the CRLSet and PKI metadata never updated after a build. Arx
checks Google's component update service directly instead, for the components
in `chrome/browser/arx/component_updates.h` only:

* only those components register, and the update service asks for no other
  even if one registers some other way;
* responses are CUP-signed again (ungoogled-chromium turned signing off), and
  downloads stay CRX3 files checked against each component's key;
* no pings, no background downloader, and each update check is cut down to the
  fields in `kComponentRequestKeys` and `kComponentAppKeys` before it is signed.
"""
from .overlay import replace_once

INSTALLER = "components/component_updater/component_installer.cc"
SERVICE = "components/component_updater/component_updater_service.cc"
CONFIGURATOR = "chrome/browser/component_updater/chrome_component_updater_configurator.cc"
COMPONENTS_PAGE = "chrome/browser/ui/webui/components/components_handler.cc"

INCLUDE = '#include "chrome/browser/arx/component_updates.h"  // nogncheck\n'

SERIALIZER = '''// Arx (DEV-874): an update check carries only the fields in
// arx::kComponentRequestKeys and arx::kComponentAppKeys. The request is cut
// down here, before CUP signs it. A request that can't be parsed is not sent.
template <size_t N>
void ArxKeepOnly(base::DictValue& dict,
                 const std::array<std::string_view, N>& kept) {
  std::vector<std::string> removed;
  for (const auto entry : dict) {
    if (std::ranges::find(kept, std::string_view(entry.first)) == kept.end()) {
      removed.push_back(entry.first);
    }
  }
  for (const std::string& key : removed) {
    dict.Remove(key);
  }
}

class ArxComponentRequestSerializer final
    : public update_client::ProtocolSerializer {
 public:
  ArxComponentRequestSerializer()
      : json_(update_client::ProtocolHandlerFactoryJSON().CreateSerializer()) {}

  std::string Serialize(
      const update_client::protocol_request::Request& request) const override {
    std::optional<base::DictValue> root = base::JSONReader::ReadDict(
        json_->Serialize(request), base::JSON_PARSE_RFC);
    if (!root) {
      return std::string();
    }
    // Pruned before `body` points into it: removing entries moves the rest.
    ArxKeepOnly(*root, std::to_array<std::string_view>({"request"}));
    base::DictValue* body = root->FindDict("request");
    if (!body) {
      return std::string();
    }
    ArxKeepOnly(*body, arx::kComponentRequestKeys);
    if (base::ListValue* apps = body->FindList("apps")) {
      for (base::Value& app : *apps) {
        if (base::DictValue* fields = app.GetIfDict()) {
          ArxKeepOnly(*fields, arx::kComponentAppKeys);
        }
      }
    }
    return base::WriteJson(*root).value_or(std::string());
  }

 private:
  std::unique_ptr<update_client::ProtocolSerializer> json_;
};

class ArxComponentProtocolHandlerFactory final
    : public update_client::ProtocolHandlerFactory {
 public:
  std::unique_ptr<update_client::ProtocolParser> CreateParser() const override {
    return update_client::ProtocolHandlerFactoryJSON().CreateParser();
  }

  std::unique_ptr<update_client::ProtocolSerializer> CreateSerializer()
      const override {
    return std::make_unique<ArxComponentRequestSerializer>();
  }
};

class ChromeConfigurator : public update_client::Configurator {
'''


def patches():
    # Register only Arx's components. This replaces Helium's allowlist, which
    # allowed the CRLSet and Widevine and nothing else.
    yield INSTALLER, '#include "base/containers/fixed_flat_set.h"\n', '#include "base/containers/fixed_flat_set.h"\n' + INCLUDE
    yield INSTALLER, '''  static constexpr auto kAllowedComponents =
      base::MakeFixedFlatSet<std::string_view>(
          base::sorted_unique,
          {
              "hfnkpimlhhgieaddgfemjhofmfblmnib",  // CRLSet
              "oimompecagnajdejgnnjijobebaeigek",  // WidevineCdm
          });
''', "  // Arx registers only the components it keeps updated (DEV-874).\n"
    yield INSTALLER, "  if (!kAllowedComponents.contains(registration_info->crx_id)) {\n", \
        "  if (!arx::IsNetworkUpdatedComponent(registration_info->crx_id)) {\n"

    # However a component was registered, an update check never names one
    # outside the allowlist.
    yield SERVICE, '#include "base/check.h"\n', '#include "base/check.h"\n' + INCLUDE
    yield SERVICE, '''    crxs.push_back(item ? std::optional<CrxComponent>{ToCrxComponent(*item)}
                        : std::nullopt);
''', '''    // Arx (DEV-874): only the components it keeps updated are ever requested.
    crxs.push_back(item && arx::IsNetworkUpdatedComponent(item->app_id)
                       ? std::optional<CrxComponent>{ToCrxComponent(*item)}
                       : std::nullopt);
'''

    yield CONFIGURATOR, '#include "components/component_updater/configurator_impl.h"\n', (
        '#include "components/component_updater/configurator_impl.h"\n'
        '#include "base/json/json_reader.h"\n'
        '#include "base/json/json_writer.h"\n'
        '#include "base/values.h"\n'
        '#include "components/update_client/protocol_parser.h"\n'
        '#include "components/update_client/protocol_serializer.h"\n' + INCLUDE)
    # Helium's consent lookup is no longer called.
    yield CONFIGURATOR, "PrefService* GetProfilePrefs() {\n", "[[maybe_unused]] PrefService* GetProfilePrefs() {\n"
    yield CONFIGURATOR, "class ChromeConfigurator : public update_client::Configurator {\n", SERIALIZER
    yield CONFIGURATOR, '''  return {helium::GetComponentUpdateURL(GetProfilePrefs())};
}

std::vector<GURL> ChromeConfigurator::PingUrl() const {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  return {helium::GetComponentUpdateURL(GetProfilePrefs())};
}
''', '''  // Arx (DEV-874): Google's service, without Helium's services consent.
  return {GURL(arx::kComponentUpdateURL)};
}

std::vector<GURL> ChromeConfigurator::PingUrl() const {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  // Arx sends no install or update pings.
  return {};
}
'''
    yield CONFIGURATOR, "  return configurator_impl_.EnabledBackgroundDownloader();\n", \
        "  // Arx downloads in process, through the same checked network path.\n  return false;\n"
    yield CONFIGURATOR, "  return configurator_impl_.EnabledCupSigning();\n", \
        "  // Arx checks the signature on every update response.\n  return true;\n"
    yield CONFIGURATOR, "  return configurator_impl_.GetProtocolHandlerFactory();\n", \
        "  return std::make_unique<ArxComponentProtocolHandlerFactory>();\n"

    # Helium's components page blamed every update error on services consent,
    # which no longer gates component updates.
    yield COMPONENTS_PAGE, '''
  if (state == update_client::ComponentState::kUpdateError) {
    Profile* profile = Profile::FromBrowserContext(
        web_ui()->GetWebContents()->GetBrowserContext());

    if (profile) {
      PrefService* prefs = profile->GetPrefs();
      if (prefs && !helium::ShouldAccessComponentUpdateService(*prefs)) {
        return l10n_util::GetStringUTF16(
          IDS_COMPONENTS_SVC_STATUS_ERROR_HELIUM_SERVICES);
      }
    }
  }

''', "  // Arx: component updates don't depend on Helium's services (DEV-874).\n"


def apply(source):
    for relative, before, after in patches():
        replace_once(source / relative, before, after)
