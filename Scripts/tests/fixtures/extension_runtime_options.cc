#include <cassert>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <utility>
#include <cstdint>
#define DCHECK_CURRENTLY_ON(x) ((void)0)
namespace base {
template<class T> using OnceCallback=std::function<T>;
// Production calls std::move(callback).Run(); use the same callable contract.
template<class> struct Callback;
template<class R,class...A> struct Callback<R(A...)> {
 std::function<R(A...)> fn;
 Callback()=default;template<class F> Callback(F f):fn(std::move(f)){}
 explicit operator bool()const{return bool(fn);}
 R Run(A... args){auto taken=std::move(fn);return taken(std::forward<A>(args)...);}
};
template<class T> struct WeakPtr {T* owner;bool* valid;explicit operator bool()const{return *valid;}T* operator->()const{return owner;}};
template<class F,class...A> auto BindOnce(F f,A... args){return [=]()mutable{std::invoke(f,std::move(args)...);};}
struct ScopedClosureRunner {std::function<void()> fn;explicit ScopedClosureRunner(std::function<void()> f):fn(std::move(f)){}~ScopedClosureRunner(){fn();}};
}
// Use the production callback spelling below with an exactly-once fake peer.
#define OnceCallback Callback
namespace content {struct BrowserThread {enum {UI};};struct BrowserContext {virtual ~BrowserContext()=default;};}
struct GURL {std::string value;};
struct Profile:content::BrowserContext {
 std::string key;bool current=true,private_=false,escalated=false,acquire=true;int keepalives=0;
 static Profile* FromBrowserContext(content::BrowserContext* context){return static_cast<Profile*>(context);}
};
namespace extensions {
struct Extension {std::string id_="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";int version=3,location_=1;bool options=true;int manifest_version()const{return version;}int location()const{return location_;}const std::string& id()const{return id_;}};
struct Enabled {const Extension* extension=nullptr;const Extension* GetByID(const std::string&)const{return extension;}};
struct ExtensionRegistry {
 static inline std::map<Profile*,ExtensionRegistry*> values;Enabled enabled;
 static ExtensionRegistry* Get(Profile* p){return values.at(p);}const Enabled& enabled_extensions()const{return enabled;}
};
struct Manifest {static bool IsComponentLocation(int value){return value==2;}};
struct ExtensionPrefs {Profile* profile;static ExtensionPrefs* Get(Profile* p){static ExtensionPrefs f;f.profile=p;return &f;}bool DidExtensionEscalatePermissions(const std::string&)const{return profile->escalated;}};
struct OptionsPageInfo {static bool HasOptionsPage(const Extension* p){return p->options;}static GURL GetOptionsPage(const Extension* p){return {"chrome-extension://"+p->id()+"/options.html"};}};
}
template<class T> struct scoped_refptr {T* value;scoped_refptr(T* p):value(p){}T* get()const{return value;}T* operator->()const{return value;}explicit operator bool()const{return value;}};
enum class ProfileKeepAliveOrigin {kBrowserWindow};
struct ScopedProfileKeepAlive {
 Profile* profile;explicit ScopedProfileKeepAlive(Profile* p):profile(p){++profile->keepalives;}~ScopedProfileKeepAlive(){--profile->keepalives;}
 static std::unique_ptr<ScopedProfileKeepAlive> TryAcquire(Profile* p,ProfileKeepAliveOrigin){return p->acquire?std::make_unique<ScopedProfileKeepAlive>(p):nullptr;}
};
std::optional<std::string> CurrentExtensionProfileKey(Profile* p){if(!p||!p->current||p->private_)return {};return p->key;}
bool ExtensionProfileIsCurrent(Profile* p,const std::string& key){return p->current&&!p->private_&&p->key==key;}
std::function<bool(Profile*,const std::string&,const extensions::Extension*,const GURL&)> adopt;
bool AdoptRuntimeExtensionOptions(Profile* p,const std::string& key,const extensions::Extension* e,const GURL& url){return adopt(p,key,e,url);}
class Extensions {
 public:
 struct Factory {Extensions* owner;base::WeakPtr<Extensions> GetWeakPtr(){return {owner,&owner->valid};}}weak_factory_{this};
 bool enabled_=true,valid=true;std::set<std::string> runtime_options_profiles_;
 // OPEN_RUNTIME
};
int main(){
 Profile profile;profile.key="profile";extensions::Extension extension,replacement;extensions::ExtensionRegistry registry;registry.enabled.extension=&extension;extensions::ExtensionRegistry::values[&profile]=&registry;Extensions bridge;
 int adopted=0,completed=0;bool result=false;
 adopt=[&](Profile* p,const std::string& key,const extensions::Extension* e,const GURL& url){++adopted;assert(p==&profile&&key==profile.key&&e==&extension);assert(url.value=="chrome-extension://"+extension.id()+"/options.html");assert(profile.keepalives==1&&bridge.runtime_options_profiles_.contains(profile.key));return true;};
 auto complete=[&](bool value){++completed;result=value;assert(profile.keepalives==1&&bridge.runtime_options_profiles_.contains(profile.key));};
 bridge.OpenRuntimeOptions(&extension,&profile,complete);assert(completed==1&&result&&adopted==1&&profile.keepalives==0&&bridge.runtime_options_profiles_.empty());
 for(int reason=0;reason<9;++reason){
  bridge.enabled_=reason!=0;profile.current=reason!=1;profile.private_=reason==2;extension.version=reason==3?2:3;registry.enabled.extension=reason==4?&replacement:&extension;extension.location_=reason==5?2:1;profile.escalated=reason==6;extension.options=reason!=7;profile.acquire=reason!=8;
  completed=0;bridge.OpenRuntimeOptions(&extension,&profile,[&](bool value){assert(!value);++completed;});assert(completed==1&&adopted==1&&profile.keepalives==0&&bridge.runtime_options_profiles_.empty());
 }
 bridge.enabled_=profile.current=profile.acquire=extension.options=true;profile.private_=profile.escalated=false;extension.version=3;extension.location_=1;registry.enabled.extension=&extension;
 completed=0;
 adopt=[&](Profile*,const std::string&,const extensions::Extension*,const GURL&){bridge.OpenRuntimeOptions(&extension,&profile,[&](bool value){assert(!value);++completed;});assert(profile.keepalives==1);return false;};
 bridge.OpenRuntimeOptions(&extension,&profile,complete);assert(completed==2&&!result&&profile.keepalives==0&&bridge.runtime_options_profiles_.empty());
 // Exact enabled instance changes during publication: completion cannot borrow it.
 adopt=[&](Profile*,const std::string&,const extensions::Extension*,const GURL&){registry.enabled.extension=&replacement;return true;};completed=0;
 bridge.OpenRuntimeOptions(&extension,&profile,complete);assert(completed==1&&!result&&profile.keepalives==0);
 registry.enabled.extension=&extension;adopt=[](Profile*,const std::string&,const extensions::Extension*,const GURL&){return true;};
 // Reentrant shutdown invalidates logical work while the local physical profile
 // hold still protects the actual Chrome reply and its stack.
 bridge.OpenRuntimeOptions(&extension,&profile,[&](bool value){assert(value&&profile.keepalives==1);bridge.enabled_=false;bridge.valid=false;bridge.runtime_options_profiles_.clear();});
 assert(profile.keepalives==0&&bridge.runtime_options_profiles_.empty());
}
