#include "chrome/browser/arx/private_download_prefs.h"

#include <stdint.h>

#include <map>
#include <memory>

#include "base/functional/bind.h"
#include "base/memory/raw_ptr.h"
#include "base/no_destructor.h"
#include "base/scoped_multi_source_observation.h"
#include "base/task/single_thread_task_runner.h"
#include "chrome/browser/download/download_prefs.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_observer.h"
#include "chrome/common/pref_names.h"
#include "components/prefs/pref_change_registrar.h"
#include "components/prefs/pref_service.h"
#include "content/public/browser/browser_thread.h"

namespace arx {
namespace {
class Link;
std::map<Profile*, std::unique_ptr<Link>>& Links() {
  static base::NoDestructor<std::map<Profile*, std::unique_ptr<Link>>> links;
  return *links;
}

uint64_t NextIdentity() {
  static uint64_t next = 0;
  return ++next;
}

void Erase(uint64_t identity);

bool Managed(PrefService* prefs, const char* name) {
  const auto* preference = prefs->FindPreference(name);
  return preference && preference->IsManaged();
}

class Link final : public ProfileObserver {
 public:
  Link(Profile* private_profile, Profile* opener)
      : identity_(NextIdentity()), private_profile_(private_profile), opener_(opener) {
    observations_.AddObservation(private_profile);
    observations_.AddObservation(opener);
    registrar_.Init(opener->GetPrefs());
    const auto copy = base::BindRepeating(&Link::Copy, base::Unretained(this));
    registrar_.Add(prefs::kDownloadDefaultDirectory, copy);
    registrar_.Add(prefs::kSaveFileDefaultDirectory, copy);
    registrar_.Add(prefs::kPromptForDownload, copy);
    Copy();
  }

  void Copy() {
    if (!private_profile_ || !opener_) return;
    auto* source = DownloadPrefs::FromBrowserContext(opener_);
    auto* prefs = private_profile_->GetPrefs();
    if (!source || !prefs) return;
    // Policy decides these for every profile; a managed value already applies.
    if (!Managed(prefs, prefs::kDownloadDefaultDirectory))
      prefs->SetFilePath(prefs::kDownloadDefaultDirectory, source->DownloadPath());
    if (!Managed(prefs, prefs::kSaveFileDefaultDirectory))
      prefs->SetFilePath(prefs::kSaveFileDefaultDirectory, source->SaveFilePath());
    if (!Managed(prefs, prefs::kPromptForDownload))
      prefs->SetBoolean(prefs::kPromptForDownload, source->PromptForDownload());
  }

  // Either profile is going away: stop reading the opener's prefs at once,
  // then drop the link off this observer call.
  void OnProfileWillBeDestroyed(Profile*) override { Detach(); }

  void Detach() {
    registrar_.RemoveAll();
    observations_.RemoveAllObservations();
    if (!private_profile_) return;
    private_profile_ = nullptr;
    opener_ = nullptr;
    // Only the identity is bound: the profile may be gone when this runs.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce(&Erase, identity_));
  }

  uint64_t identity() const { return identity_; }

 private:
  const uint64_t identity_;
  raw_ptr<Profile> private_profile_;
  raw_ptr<Profile> opener_;
  PrefChangeRegistrar registrar_;
  base::ScopedMultiSourceObservation<Profile, ProfileObserver> observations_{this};
};

void Erase(uint64_t identity) {
  auto& links = Links();
  for (auto link = links.begin(); link != links.end(); ++link) {
    if (link->second->identity() != identity) continue;
    links.erase(link);
    return;
  }
}
}  // namespace

void FollowOpenerDownloadPreferences(Profile* private_profile, Profile* opener) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!private_profile || !opener || !private_profile->IsOffTheRecord() ||
      opener->IsOffTheRecord()) return;
  StopFollowingOpenerDownloadPreferences(private_profile);
  Links()[private_profile] = std::make_unique<Link>(private_profile, opener);
}

void StopFollowingOpenerDownloadPreferences(Profile* private_profile) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto found = Links().find(private_profile);
  if (found == Links().end()) return;
  auto link = std::move(found->second);
  Links().erase(found);
  link->Detach();
  // Detach posted an erase for this link's identity; a newer link for the
  // same profile has another one and stays.
}
}  // namespace arx
