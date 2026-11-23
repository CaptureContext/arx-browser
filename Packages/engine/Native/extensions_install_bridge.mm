#include "chrome/browser/arx/extensions_install_bridge.h"

#include <algorithm>
#include <limits>
#include <map>
#include <memory>
#include <optional>
#include <utility>
#include <vector>

#include "base/files/file.h"
#include "base/files/file_util.h"
#include "base/files/scoped_temp_dir.h"
#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/json/json_writer.h"
#include "base/memory/ref_counted_delete_on_sequence.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "base/timer/timer.h"
#include "base/values.h"
#include "chrome/browser/arx/extension_install_authority.h"
#include "chrome/browser/profiles/keep_alive/profile_keep_alive_types.h"
#include "chrome/browser/profiles/keep_alive/scoped_profile_keep_alive.h"
#include "chrome/browser/profiles/profile.h"
#include "components/crx_file/id_util.h"
#include "content/public/browser/browser_thread.h"
#include "crypto/hash.h"
#include "extensions/browser/crx_installer.h"
#include "extensions/browser/extension_file_task_runner.h"
#include "extensions/browser/extension_install_prompt_client.h"
#include "extensions/browser/extension_prefs.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/browser/install/crx_install_error.h"
#include "extensions/common/extension.h"
#include "extensions/common/manifest.h"
#include "extensions/common/manifest_handlers/permissions_parser.h"
#include "extensions/common/permissions/permission_message_provider.h"
#include "extensions/common/permissions/permission_set.h"

namespace arx {
namespace {
constexpr size_t kMaximumCRXBytes = 32 * 1024 * 1024;
constexpr size_t kMaximumPhysicalInstalls = 2;
constexpr size_t kMaximumPromptBytes = 1024 * 1024;
constexpr size_t kMaximumStrings = 512;
constexpr size_t kMaximumStringBytes = 4096;

class StagedCRX final : public base::RefCountedDeleteOnSequence<StagedCRX> {
 public:
  explicit StagedCRX(scoped_refptr<base::SequencedTaskRunner> runner)
      : base::RefCountedDeleteOnSequence<StagedCRX>(std::move(runner)) {}
  static scoped_refptr<StagedCRX> Write(std::vector<uint8_t> bytes) {
    auto result = base::MakeRefCounted<StagedCRX>(extensions::GetExtensionFileTaskRunner());
    if (bytes.empty() || bytes.size() > kMaximumCRXBytes ||
        !result->directory_.CreateUniqueTempDir(FILE_PATH_LITERAL("arx-verified-crx-")) ||
        !base::SetPosixFilePermissions(result->directory_.GetPath(), 0700)) return nullptr;
    result->path_ = result->directory_.GetPath().AppendASCII("candidate.crx");
    base::File file(result->path_, base::File::FLAG_CREATE | base::File::FLAG_WRITE);
    if (!file.IsValid() || !base::SetPosixFilePermissions(result->path_, 0600) ||
        !file.WriteAtCurrentPosAndCheck(bytes) || !file.Flush()) return nullptr;
    file.Close();
    if (!base::SetPosixFilePermissions(result->path_, 0400)) return nullptr;
    result->digest_ = base::HexEncodeLower(crypto::hash::Sha256(bytes));
    return result;
  }
  const base::FilePath& path() const { return path_; }
  const std::string& digest() const { return digest_; }
 private:
  friend class base::RefCountedDeleteOnSequence<StagedCRX>;
  friend class base::DeleteHelper<StagedCRX>;
  ~StagedCRX() = default;
  base::ScopedTempDir directory_;
  base::FilePath path_;
  std::string digest_;
};

class Installs;
class PromptClient final : public extensions::ExtensionInstallPromptClient {
 public:
  PromptClient(base::WeakPtr<Installs> owner, uint64_t request)
      : owner_(std::move(owner)), request_(request) {}
  void OnInstallSuccess(scoped_refptr<const extensions::Extension>, SkBitmap*) override {}
  void OnInstallFailure(const extensions::CrxInstallError&) override {}
  void SetUseAppInstalledBubble(bool) override {}
  void SetSkipPostInstallUI(bool) override {}
  void ConfirmInstall(DoneCallback callback, const extensions::Extension* extension) override;
  void ConfirmReEnable(DoneCallback callback, const extensions::Extension*, content::BrowserContext*) override {
    std::move(callback).Run(DoneCallbackPayload(Result::ABORTED));
  }
  void ConfirmPermissions(DoneCallback callback, const extensions::Extension*,
                          std::unique_ptr<const extensions::PermissionSet>) override {
    std::move(callback).Run(DoneCallbackPayload(Result::ABORTED));
  }
  void ShowInstallDialog(DoneCallback callback, const extensions::Extension* extension, const SkBitmap*) override {
    ConfirmInstall(std::move(callback), extension);
  }
 private:
  const base::WeakPtr<Installs> owner_;
  const uint64_t request_;
};

// DEV-968. The manifest's author: a non-empty name, or the email of an MV3
// author object. At most 256 bytes, with no control characters.
std::optional<std::string> ManifestAuthor(const extensions::Extension& extension) {
  const base::Value* author = extension.manifest()->FindKey("author");
  const std::string* text = !author ? nullptr
      : author->is_string() ? &author->GetString()
      : author->is_dict() ? author->GetDict().FindString("email") : nullptr;
  if (!text) return std::nullopt;
  std::string value(base::TrimWhitespaceASCII(*text, base::TRIM_ALL));
  if (value.empty() || value.size() > 256 || !base::IsStringUTF8(value) ||
      std::any_of(value.begin(), value.end(), [](char c) {
        return static_cast<unsigned char>(c) < 32 || c == 127;
      })) return std::nullopt;
  return value;
}

bool StringBudget(const std::string& text, size_t& remaining) {
  if (text.size() > kMaximumStringBytes || !base::IsStringUTF8(text) ||
      text.find('\0') != std::string::npos || text.size() * 6 + 3 > remaining) return false;
  remaining -= text.size() * 6 + 3;
  return true;
}

std::optional<base::DictValue> PermissionJSON(const extensions::PermissionSet& permissions,
                                             size_t& remaining) {
  base::DictValue result;
  base::ListValue apis, hosts;
  const auto names = permissions.GetAPIsAsStrings();
  if (names.size() > kMaximumStrings || permissions.effective_hosts().size() > kMaximumStrings) return std::nullopt;
  for (const auto& name : names) {
    if (!StringBudget(name, remaining)) return std::nullopt;
    apis.Append(name);
  }
  for (const auto& host : permissions.effective_hosts()) {
    auto value = host.GetAsString();
    if (!StringBudget(value, remaining)) return std::nullopt;
    hosts.Append(std::move(value));
  }
  result.Set("apis", std::move(apis));
  result.Set("hosts", std::move(hosts));
  return result;
}

class Installs final {
 public:
  bool Begin(Profile* profile, const std::string& key, uint64_t request,
             uint64_t revision, const std::string& expected_id,
             const std::string& webstore_id, const std::string& basename,
             base::span<const uint8_t> bytes, const ArxEngineCallbacks& callbacks,
             ExtensionInstallValidation validate, ExtensionInstallCompletion complete) {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
    if (!profile || profile->IsOffTheRecord() || !callbacks.extension_install_prompt ||
        !request || !revision || bytes.empty() || bytes.size() > kMaximumCRXBytes ||
        !validate.Run(profile, key, revision) || operations_.contains(request) ||
        operations_.size() >= kMaximumPhysicalInstalls || Retains(key) ||
        (!expected_id.empty() && !crx_file::id_util::IdIsValid(expected_id)) ||
        (!webstore_id.empty() && ((!expected_id.empty() && expected_id != webstore_id) ||
                                  !crx_file::id_util::IdIsValid(webstore_id))) ||
        basename.empty() || basename.size() > 255 || !base::IsStringUTF8(basename) ||
        basename.find_first_of("/\\\0", 0, 3) != std::string::npos) return false;
    for (unsigned char byte : basename) if (byte < 32 || byte == 127) return false;
    auto keepalive = ScopedProfileKeepAlive::TryAcquire(profile, ProfileKeepAliveOrigin::kExtensionUpdater);
    if (!keepalive) return false;
    auto operation = std::make_unique<Operation>();
    operation->profile = profile->GetWeakPtr();
    operation->key = key;
    operation->revision = revision;
    operation->expected_id = expected_id;
    operation->webstore_id = webstore_id;
    operation->basename = basename;
    operation->callbacks = callbacks;
    operation->validate = std::move(validate);
    operation->complete = std::move(complete);
    operation->keepalive = std::move(keepalive);
    operation->timer.Start(FROM_HERE, base::Minutes(2), base::BindOnce(
        &Installs::Expire, weak_factory_.GetWeakPtr(), request));
    operations_.emplace(request, std::move(operation));
    if (!extensions::GetExtensionFileTaskRunner()->PostTaskAndReplyWithResult(FROM_HERE,
        base::BindOnce(&StagedCRX::Write, std::vector<uint8_t>(bytes.begin(), bytes.end())),
        base::BindOnce(&Installs::Staged, weak_factory_.GetWeakPtr(), request))) {
      // No task was accepted, so neither staging nor Chromium owns work. Undo
      // only this insertion; a drain failure later must retain physical work.
      operations_.erase(request);
      return false;
    }
    return true;
  }

  bool Retains(const std::string& key) const {
    for (const auto& [id, operation] : operations_) if (operation->key == key) return true;
    return false;
  }

  bool Resolve(Profile* profile, const std::string& key, uint64_t request,
               uint64_t token, bool accept) {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
    auto found = operations_.find(request);
    if (found == operations_.end()) return false;
    auto& operation = *found->second;
    if (operation.key != key || !operation.prompt || !operation.authority || !token) return false;
    const auto* candidate = operation.installer ? operation.installer->extension() : nullptr;
    const bool current = profile && operation.profile.get() == profile && !operation.cancelled &&
        operation.stage && candidate && operation.validate.Run(profile, key, operation.revision);
    const bool matches = operation.authority->Consume(key, current ? operation.revision : 0,
        operation.stage ? operation.stage->digest() : "", candidate ? candidate->id() : "",
        candidate ? candidate->version().GetString() : "", token);
    if (!matches) {
      operation.cancelled = ARX_EXTENSION_STALE;
      Abort(operation);
      return false;
    }
    operation.timer.Stop();
    if (!accept) operation.cancelled = ARX_EXTENSION_CANCELLED;
    operation.accepted = accept;
    auto callback = std::move(operation.prompt);
    std::move(callback).Run(extensions::ExtensionInstallPromptClient::DoneCallbackPayload(
        accept ? extensions::ExtensionInstallPromptClient::Result::ACCEPTED
               : extensions::ExtensionInstallPromptClient::Result::USER_CANCELED));
    return true;
  }

  bool Cancel(uint64_t request) {
    auto found = operations_.find(request);
    if (found == operations_.end()) return false;
    auto& operation = *found->second;
    // Acceptance linearizes explicit authority for this immutable package.
    // Chromium may already be committing; cancellation cannot claim rollback.
    if (!operation.accepted) {
      operation.cancelled = ARX_EXTENSION_CANCELLED;
      Abort(operation);
    }
    return true;
  }

  void Shutdown() {
    for (auto& [id, operation] : operations_) {
      operation->callbacks = {};
      operation->cancelled = ARX_EXTENSION_UNAVAILABLE;
      Abort(*operation);
    }
    // Do not delete staged files underneath an in-flight sandboxed unpacker.
    // Live operations retain physical ownership until Chromium drains or exits.
  }

  void Prompt(uint64_t request, extensions::ExtensionInstallPromptClient::DoneCallback callback,
              const extensions::Extension* candidate) {
    auto found = operations_.find(request);
    if (found == operations_.end()) {
      std::move(callback).Run(extensions::ExtensionInstallPromptClient::DoneCallbackPayload(
          extensions::ExtensionInstallPromptClient::Result::ABORTED));
      return;
    }
    auto& operation = *found->second;
    const auto* installed = operation.profile && candidate
        ? extensions::ExtensionRegistry::Get(operation.profile.get())->GetInstalledExtension(candidate->id()) : nullptr;
    // A store update (DEV-776) names the same ID twice: the installed store
    // extension it replaces and the store package it must be.
    const bool store_update = !operation.webstore_id.empty() && !operation.expected_id.empty();
    if (store_update && installed && candidate && installed->id() == operation.webstore_id &&
        candidate->id() == operation.webstore_id &&
        installed->version().CompareTo(candidate->version()) >= 0) {
      operation.cancelled = ARX_EXTENSION_UP_TO_DATE;
      std::move(callback).Run(extensions::ExtensionInstallPromptClient::DoneCallbackPayload(
          extensions::ExtensionInstallPromptClient::Result::ABORTED));
      return;
    }
    const bool target_matches = store_update
        ? installed && candidate && installed->id() == operation.webstore_id &&
            installed->from_webstore() && candidate->from_webstore() &&
            installed->version().CompareTo(candidate->version()) < 0
        : !operation.webstore_id.empty()
        ? installed == nullptr && candidate && candidate->id() == operation.webstore_id &&
            candidate->from_webstore()
        : operation.expected_id.empty() ? installed == nullptr
        : installed && candidate && installed->id() == operation.expected_id &&
            installed->version().CompareTo(candidate->version()) < 0;
    const bool current = target_matches && operation.profile && !operation.cancelled && !operation.prompt &&
        candidate && candidate->manifest_version() == 3 && candidate->is_extension() &&
        operation.stage && operation.callbacks.extension_install_prompt &&
        operation.validate.Run(operation.profile.get(), operation.key, operation.revision) &&
        (operation.expected_id.empty() || candidate->id() == operation.expected_id);
    if (!current || next_token_ == std::numeric_limits<uint64_t>::max()) {
      operation.cancelled = ARX_EXTENSION_STALE;
      std::move(callback).Run(extensions::ExtensionInstallPromptClient::DoneCallbackPayload(
          extensions::ExtensionInstallPromptClient::Result::ABORTED));
      return;
    }
    size_t remaining = kMaximumPromptBytes - 4096;
    const auto& required = extensions::PermissionsParser::GetRequiredPermissions(candidate);
    const auto& optional = extensions::PermissionsParser::GetOptionalPermissions(candidate);
    auto required_json = PermissionJSON(required, remaining);
    auto optional_json = PermissionJSON(optional, remaining);
    const auto version = candidate->version().GetString();
    if (!required_json || !optional_json || !StringBudget(candidate->name(), remaining) ||
        !StringBudget(version, remaining)) {
      operation.cancelled = ARX_EXTENSION_LIMIT_EXCEEDED;
      std::move(callback).Run(extensions::ExtensionInstallPromptClient::DoneCallbackPayload(
          extensions::ExtensionInstallPromptClient::Result::ABORTED));
      return;
    }
    const auto* provider = extensions::PermissionMessageProvider::Get();
    const auto messages = provider->GetPermissionMessages(provider->GetAllPermissionIDs(required, candidate->GetType()));
    base::ListValue warnings;
    if (messages.size() > kMaximumStrings) {
      operation.cancelled = ARX_EXTENSION_LIMIT_EXCEEDED;
      std::move(callback).Run(extensions::ExtensionInstallPromptClient::DoneCallbackPayload(
          extensions::ExtensionInstallPromptClient::Result::ABORTED));
      return;
    }
    for (const auto& message : messages) {
      if (message.message().size() > kMaximumStringBytes || message.submessages().size() > kMaximumStrings) {
        operation.cancelled = ARX_EXTENSION_LIMIT_EXCEEDED;
        break;
      }
      auto text = base::UTF16ToUTF8(message.message());
      base::ListValue details;
      if (!StringBudget(text, remaining)) {
        operation.cancelled = ARX_EXTENSION_LIMIT_EXCEEDED;
        break;
      }
      for (const auto& submessage : message.submessages()) {
        if (submessage.size() > kMaximumStringBytes) { operation.cancelled = ARX_EXTENSION_LIMIT_EXCEEDED; break; }
        auto detail = base::UTF16ToUTF8(submessage);
        if (!StringBudget(detail, remaining)) { operation.cancelled = ARX_EXTENSION_LIMIT_EXCEEDED; break; }
        details.Append(std::move(detail));
      }
      base::DictValue warning;
      warning.Set("message", std::move(text));
      warning.Set("details", std::move(details));
      warnings.Append(std::move(warning));
      if (operation.cancelled) break;
    }
    base::DictValue json;
    json.Set("id", candidate->id());
    json.Set("name", candidate->name());
    json.Set("version", version);
    json.Set("packageSHA256", operation.stage->digest());
    json.Set("sourceBasename", operation.basename);
    json.Set("isUpdate", !operation.expected_id.empty());
    // ABI56 (DEV-968): who publishes it, from the manifest's author when it names
    // one (a name, or an MV3 author object's email). Chromium's install data has
    // no publisher, and a store package carries none of its own.
    if (auto publisher = ManifestAuthor(*candidate); publisher && StringBudget(*publisher, remaining))
      json.Set("publisher", std::move(*publisher));
    if (installed) {
      // ABI45 (DEV-776). The app may take an update that asks for nothing new
      // without showing the sheet; one that asks for more always shows it.
      auto granted = extensions::ExtensionPrefs::Get(operation.profile.get())
          ->GetGrantedPermissions(installed->id());
      json.Set("permissionIncrease", !granted ||
          provider->IsPrivilegeIncrease(*granted, required, candidate->GetType()));
    }
    json.Set("requiredPermissions", std::move(*required_json));
    json.Set("optionalPermissions", std::move(*optional_json));
    json.Set("warnings", std::move(warnings));
    auto encoded = base::WriteJson(json);
    if (operation.cancelled || !encoded || encoded->size() > kMaximumPromptBytes) {
      operation.cancelled = ARX_EXTENSION_LIMIT_EXCEEDED;
      std::move(callback).Run(extensions::ExtensionInstallPromptClient::DoneCallbackPayload(
          extensions::ExtensionInstallPromptClient::Result::ABORTED));
      return;
    }
    const uint64_t token = next_token_++;
    operation.authority = std::make_unique<ExtensionInstallAuthority>(operation.key,
        operation.revision, operation.stage->digest(), candidate->id(), version, token);
    operation.prompt = std::move(callback);
    const auto callbacks = operation.callbacks;
    callbacks.extension_install_prompt(callbacks.context, request, operation.key.c_str(), token,
        reinterpret_cast<const uint8_t*>(encoded->data()), encoded->size());
  }

 private:
  struct Operation {
    base::WeakPtr<Profile> profile;
    std::string key;
    uint64_t revision = 0;
    std::string expected_id;
    std::string webstore_id;
    std::string basename;
    ArxEngineCallbacks callbacks = {};
    ExtensionInstallValidation validate;
    ExtensionInstallCompletion complete;
    std::unique_ptr<ScopedProfileKeepAlive> keepalive;
    scoped_refptr<StagedCRX> stage;
    scoped_refptr<extensions::CrxInstaller> installer;
    std::unique_ptr<ExtensionInstallAuthority> authority;
    extensions::ExtensionInstallPromptClient::DoneCallback prompt;
    base::OneShotTimer timer;
    std::optional<ArxExtensionStatus> cancelled;
    bool accepted = false;
  };

  void Abort(Operation& operation) {
    if (operation.authority) operation.authority->Invalidate();
    if (operation.prompt) {
      auto callback = std::move(operation.prompt);
      std::move(callback).Run(extensions::ExtensionInstallPromptClient::DoneCallbackPayload(
          extensions::ExtensionInstallPromptClient::Result::ABORTED));
    }
  }
  void Expire(uint64_t request) {
    auto found = operations_.find(request);
    if (found == operations_.end() || found->second->accepted) return;
    found->second->cancelled = ARX_EXTENSION_TIMEOUT;
    Abort(*found->second);
  }
  void Staged(uint64_t request, scoped_refptr<StagedCRX> stage) {
    auto found = operations_.find(request);
    if (found == operations_.end()) return;
    auto& operation = *found->second;
    operation.stage = std::move(stage);
    if (!operation.stage) { Drain(request, ARX_EXTENSION_FAILED); return; }
    if (!operation.profile || operation.cancelled ||
        !operation.validate.Run(operation.profile.get(), operation.key, operation.revision)) {
      Drain(request, operation.cancelled.value_or(ARX_EXTENSION_STALE));
      return;
    }
    auto installer = extensions::CrxInstaller::Create(operation.profile.get(),
        std::make_unique<PromptClient>(weak_factory_.GetWeakPtr(), request));
    installer->set_allow_silent_install(false);
    installer->set_require_verified_install_prompt(true);
    installer->set_error_on_unsupported_requirements(true);
    if (operation.webstore_id.empty()) {
      installer->set_off_store_install_allow_reason(extensions::CrxInstaller::OffStoreInstallAllowedFromSettingsPage);
    } else {
      // No off-store reason: CrxInstaller verifies with the Web Store's
      // publisher-proof format and marks the extension as from the store.
      installer->set_is_gallery_install(true);
      installer->set_expected_id(operation.webstore_id);
    }
    installer->set_was_triggered_by_user_download();
    installer->set_install_immediately(true);
    installer->set_do_not_sync(true);
    if (!operation.expected_id.empty()) installer->set_expected_id(operation.expected_id);
    installer->AddInstallerCallback(base::BindOnce(&Installs::Installed, weak_factory_.GetWeakPtr(), request));
    operation.installer = installer;
    installer->InstallCrx(operation.stage->path());
  }
  void Installed(uint64_t request, const std::optional<extensions::CrxInstallError>& error) {
    auto found = operations_.find(request);
    if (found == operations_.end()) return;
    ArxExtensionStatus status = ARX_EXTENSION_SUCCESS;
    if (found->second->cancelled) status = *found->second->cancelled;
    else if (error) {
      const bool unpacker_failure = error->type() == extensions::CrxInstallErrorType::SANDBOXED_UNPACKER_FAILURE;
      const auto detail = unpacker_failure ? extensions::CrxInstallErrorDetail::NONE : error->detail();
      const bool invalid = unpacker_failure || detail == extensions::CrxInstallErrorDetail::UNEXPECTED_ID ||
          detail == extensions::CrxInstallErrorDetail::UNEXPECTED_VERSION ||
          detail == extensions::CrxInstallErrorDetail::MANIFEST_INVALID;
      status = invalid ? ARX_EXTENSION_INVALID_PACKAGE : ARX_EXTENSION_FAILED;
    }
    else if (!found->second->accepted) status = ARX_EXTENSION_FAILED;
    // Chromium posts cleanup after invoking an error callback. First leave its
    // callback stack, then queue a barrier on that exact file sequence.
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce(&Installs::Drain, weak_factory_.GetWeakPtr(), request, status));
  }
  void Drain(uint64_t request, ArxExtensionStatus status) {
    auto found = operations_.find(request);
    if (found == operations_.end()) return;
    // Ref-counted stage destruction runs on this same file sequence, before the
    // barrier releases the physical slot and permits profile retirement.
    found->second->stage.reset();
    extensions::GetExtensionFileTaskRunner()->PostTaskAndReply(FROM_HERE, base::DoNothing(),
        base::BindOnce(&Installs::Finished, weak_factory_.GetWeakPtr(), request, status));
  }
  void Finished(uint64_t request, ArxExtensionStatus status) {
    auto found = operations_.find(request);
    if (found == operations_.end()) return;
    auto operation = std::move(found->second);
    operations_.erase(found);
    if (operation->complete) std::move(operation->complete).Run(status);
  }
  uint64_t next_token_ = 1;
  std::map<uint64_t, std::unique_ptr<Operation>> operations_;
  base::WeakPtrFactory<Installs> weak_factory_{this};
};
void PromptClient::ConfirmInstall(DoneCallback callback, const extensions::Extension* extension) {
  if (owner_) { owner_->Prompt(request_, std::move(callback), extension); return; }
  std::move(callback).Run(DoneCallbackPayload(Result::ABORTED));
}
Installs& Manager() { static base::NoDestructor<Installs> manager; return *manager; }
}  // namespace

bool BeginExtensionInstall(Profile* profile, const std::string& key, uint64_t request,
                           uint64_t revision, const std::string& expected_id,
                           const std::string& webstore_id,
                           const std::string& source_basename, base::span<const uint8_t> bytes,
                           const ArxEngineCallbacks& callbacks, ExtensionInstallValidation validate,
                           ExtensionInstallCompletion complete) {
  return Manager().Begin(profile, key, request, revision, expected_id, webstore_id, source_basename, bytes,
                         callbacks, std::move(validate), std::move(complete));
}
bool ResolveExtensionInstall(Profile* profile, const std::string& key, uint64_t request,
                             uint64_t token, bool accept) {
  return Manager().Resolve(profile, key, request, token, accept);
}
bool CancelExtensionInstall(uint64_t request) { return Manager().Cancel(request); }
bool HasExtensionInstallWork(const std::string& key) { return Manager().Retains(key); }
void ShutdownExtensionInstalls() { Manager().Shutdown(); }
}  // namespace arx
