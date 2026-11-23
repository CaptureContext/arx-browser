#include <cassert>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <utility>
struct GURL {std::string value;const std::string& spec()const{return value;}std::string host()const{return "extension";}};
struct Profile {bool current=true,enabled=true;};
namespace extensions {
struct Extension {std::string id_="extension";const std::string& id()const{return id_;}};
struct ExtensionRegistry {static inline const Extension* enabled;static ExtensionRegistry* Get(Profile*){static ExtensionRegistry value;return &value;}ExtensionRegistry& enabled_extensions(){return *this;}const Extension* GetByID(const std::string&){return enabled;}};
}
constexpr int ARX_EXTENSION_VIEW_OPTIONS=1;
struct Page {
 static inline int destroyed=0,published=0;uint64_t generation=1;Profile* profile;
 Page(uint64_t,Profile* p):profile(p){}~Page(){++destroyed;}
 bool ConfigureContentHosting(bool){return true;}bool Navigate(const GURL&){return true;}
 uint64_t CloseGeneration(){return generation;}void PublishNavigation(){++published;}
};
struct Callbacks {
 void* context=nullptr;
 std::function<bool(void*,uint64_t,const char*,const char*,uint64_t,const char*,size_t,int)> extension_view_created;
 std::function<bool(void*,const char*,const char*,uint64_t,const char*,size_t)> extension_options_requested;
 std::function<void(void*,const char*,const char*,uint64_t,uint64_t)> extension_options_revoked;
};
struct Runtime {bool running=true;uint64_t next_page=1;Callbacks callbacks;std::map<uint64_t,std::unique_ptr<Page>> pages;};
Runtime& State(){static Runtime state;return state;}void CheckThread(){}
Profile* current_profile;
Profile* ExtensionProfile(const char*){return current_profile&&current_profile->current?current_profile:nullptr;}
bool IsEnabledExtensionPage(Profile* p,const GURL&){return p->enabled;}
// PRODUCTION_PUBLICATION
int main(){
 Profile profile;current_profile=&profile;extensions::Extension extension,replacement;extensions::ExtensionRegistry::enabled=&extension;
 auto& state=State();const GURL url{"chrome-extension://extension/options.html"};int offers=0,revocations=0;bool swift_owned=false;uint64_t child=0;
 state.callbacks.extension_options_requested=[&](void*,const char*,const char*,uint64_t id,const char*,size_t){++offers;child=id;swift_owned=true;return true;};
 state.callbacks.extension_options_revoked=[&](void*,const char* key,const char* id,uint64_t offered,uint64_t generation){assert(std::string(key)=="profile"&&std::string(id)==extension.id());assert(offered==child&&generation==1&&state.pages.contains(child));++revocations;swift_owned=false;};
 assert(AdoptExtensionOptionsImpl(&profile,"profile",extension.id(),url,std::nullopt,&extension));assert(offers==1&&revocations==0&&swift_owned&&Page::published==1);state.pages.clear();swift_owned=false;
 for(int reason=0;reason<3;++reason){
  profile.current=profile.enabled=true;extensions::ExtensionRegistry::enabled=&extension;
  state.callbacks.extension_options_requested=[&](void*,const char*,const char*,uint64_t id,const char*,size_t){++offers;child=id;swift_owned=true;if(reason==0)profile.enabled=false;if(reason==1)extensions::ExtensionRegistry::enabled=&replacement;if(reason==2)profile.current=false;return true;};
  const int before=Page::destroyed;
  assert(!AdoptExtensionOptionsImpl(&profile,"profile",extension.id(),url,std::nullopt,&extension));assert(state.pages.empty()&&!swift_owned&&Page::destroyed==before+1);
 }
 assert(revocations==3);profile.current=profile.enabled=true;extensions::ExtensionRegistry::enabled=&extension;
 state.callbacks.extension_options_requested=[&](void*,const char*,const char*,uint64_t id,const char*,size_t){child=id;return false;};
 assert(!AdoptExtensionOptionsImpl(&profile,"profile",extension.id(),url,std::nullopt,&extension));assert(state.pages.empty()&&revocations==3);
 // Normal user close during publication already removes physical ownership.
 state.callbacks.extension_options_requested=[&](void*,const char*,const char*,uint64_t id,const char*,size_t){child=id;state.pages.erase(id);return true;};int before=Page::destroyed;
 assert(!AdoptExtensionOptionsImpl(&profile,"profile",extension.id(),url,std::nullopt,&extension));assert(Page::destroyed==before+1&&revocations==3);
 // A consumer's new navigation is a different generation and remains owned.
 state.callbacks.extension_options_requested=[&](void*,const char*,const char*,uint64_t id,const char*,size_t){child=id;swift_owned=true;++state.pages.at(id)->generation;profile.enabled=false;return true;};before=Page::destroyed;
 assert(!AdoptExtensionOptionsImpl(&profile,"profile",extension.id(),url,std::nullopt,&extension));assert(state.pages.contains(child)&&swift_owned&&Page::destroyed==before&&revocations==3);state.pages.clear();swift_owned=false;profile.enabled=true;
 // Reentrant user-close from the revoke callback cannot cause double destroy.
 state.callbacks.extension_options_requested=[&](void*,const char*,const char*,uint64_t id,const char*,size_t){child=id;swift_owned=true;profile.enabled=false;return true;};
 state.callbacks.extension_options_revoked=[&](void*,const char*,const char*,uint64_t id,uint64_t){++revocations;swift_owned=false;state.pages.erase(id);};before=Page::destroyed;
 assert(!AdoptExtensionOptionsImpl(&profile,"profile",extension.id(),url,std::nullopt,&extension));assert(Page::destroyed==before+1&&state.pages.empty()&&!swift_owned&&revocations==4);
 profile.enabled=true;state.callbacks.extension_options_revoked={};before=Page::destroyed;
 assert(!AdoptExtensionOptionsImpl(&profile,"profile",extension.id(),url,std::nullopt,&extension));assert(Page::destroyed==before&&state.pages.empty()); // No rollback-capable host, no offer.
}
