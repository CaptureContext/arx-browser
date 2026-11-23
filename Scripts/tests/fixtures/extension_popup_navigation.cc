#include <cassert>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <tuple>
#include <utility>
#include <vector>
#include <algorithm>
#include <cstdint>
#include <type_traits>
#include "extension_action_policy.h"
namespace base {
template<class> class OnceCallback;
template<class R,class...A> class OnceCallback<R(A...)> {
 struct Erased { virtual ~Erased()=default;virtual R Call(A...)=0; };
 template<class F> struct Model final:Erased {
  F f;explicit Model(F value):f(std::move(value)){};
  R Call(A...a)override{return std::move(f)(std::forward<A>(a)...);}
 };
 public:
  OnceCallback()=default;
  OnceCallback(OnceCallback&&)=default;
  OnceCallback& operator=(OnceCallback&&)=default;
  template<class F> requires(!std::is_same_v<std::decay_t<F>,OnceCallback>)
  OnceCallback(F&& f):f_(std::make_unique<Model<std::decay_t<F>>>(std::forward<F>(f))){}
  explicit operator bool() const { return bool(f_); }
  R Run(A...a) { auto f=std::move(f_);return f->Call(std::forward<A>(a)...); }
 private: std::unique_ptr<Erased> f_;
};
using OnceClosure=OnceCallback<void()>;
template<class> class RepeatingCallback;
template<class R,class...A> class RepeatingCallback<R(A...)> {
 public:
  template<class F> requires(!std::is_same_v<std::decay_t<F>,RepeatingCallback>)
  RepeatingCallback(F&& f):f_(std::forward<F>(f)){}
  RepeatingCallback(const RepeatingCallback&)=default;
  R Run(A...a) const { return f_(std::forward<A>(a)...); }
 private: std::function<R(A...)> f_;
};
template<class T> T* Unretained(T* value) { return value; }
template<class F,class...A> OnceClosure BindOnce(F f,A...args) {
 return [f=std::move(f),args=std::make_tuple(std::move(args)...)]() mutable {
  std::apply([&](auto&&... values){std::invoke(f,std::forward<decltype(values)>(values)...);},std::move(args));
 };
}
template<class T> struct WeakPtr {
 T* ptr=nullptr; std::weak_ptr<bool> life;
 T* get() const { auto alive=life.lock(); return alive&&*alive?ptr:nullptr; }
 T* operator->() const { return get(); }
 explicit operator bool() const { return get(); }
};
struct SingleThreadTaskRunner {
 static inline std::vector<OnceClosure> tasks;
 static SingleThreadTaskRunner* GetCurrentDefault(){static SingleThreadTaskRunner r;return &r;}
 void PostTask(int,OnceClosure task){tasks.push_back(std::move(task));}
 static void Drain(){auto pending=std::move(tasks);tasks.clear();for(auto& f:pending)f.Run();}
};
}
#define FROM_HERE 0
struct GURL {
 std::string value;
 bool is_valid() const{return value.find("://")!=std::string::npos;}
 bool SchemeIsHTTPOrHTTPS()const{return SchemeIs("http")||SchemeIs("https");}
 bool SchemeIs(const char* scheme)const{return value.starts_with(std::string(scheme)+"://");}
 std::string host()const {auto p=value.find("://");if(p==std::string::npos)return {};auto h=value.substr(p+3);return h.substr(0,h.find('/'));}
 bool has_username()const{return value.find('@')!=std::string::npos;}
 bool has_password()const{return has_username();}
 const std::string& spec()const{return value;}
};
enum class WindowOpenDisposition {CURRENT_TAB,NEW_FOREGROUND_TAB,NEW_BACKGROUND_TAB,NEW_WINDOW,NEW_POPUP,OFF_THE_RECORD};
namespace blink::mojom {struct WindowFeatures {};}
namespace content {
struct BrowserContext{};
struct WebContents;
struct NavigationHandle{};
struct RenderFrameHost;
struct WeakDocumentPtr {RenderFrameHost* frame=nullptr;std::weak_ptr<bool> life;RenderFrameHost* AsRenderFrameHostIfValid()const{auto p=life.lock();return p&&*p?frame:nullptr;}};
struct GlobalRenderFrameHostId{RenderFrameHost* frame;};
struct GlobalRenderFrameHostToken{int process;RenderFrameHost* frame;};
struct RenderFrameHost {
 WebContents* owner;std::shared_ptr<bool> doc=std::make_shared<bool>(true);bool active=true,live=true;
 bool IsActive()const{return active;}bool IsRenderFrameLive()const{return live;}
 RenderFrameHost* GetOutermostMainFrame(){return this;}
 WeakDocumentPtr GetWeakDocumentPtr(){return {this,doc};}
 GlobalRenderFrameHostId GetGlobalId(){return {this};}
 int GetSiteInstance(){return 4;}
 static RenderFrameHost* FromID(GlobalRenderFrameHostId id){return id.frame;}
 static RenderFrameHost* FromFrameToken(GlobalRenderFrameHostToken token){return token.frame;}
};
struct OpenURLParams {GURL url;WindowOpenDisposition disposition=WindowOpenDisposition::NEW_FOREGROUND_TAB;RenderFrameHost** initiator_frame_token=nullptr;int initiator_process_id=0;std::string referrer;};
struct NavigationController {
 struct LoadURLParams {OpenURLParams captured;explicit LoadURLParams(OpenURLParams p):captured(std::move(p)){};};
 std::string last_referrer;GURL last_url;NavigationHandle handle;
 NavigationHandle* LoadURLWithParams(LoadURLParams p){last_referrer=p.captured.referrer;last_url=p.captured.url;return &handle;}
};
struct WebContents {
 struct CreateParams {BrowserContext* context;int site;GlobalRenderFrameHostId opener_id{nullptr};bool opened_by_another_window=false,initially_hidden=false;CreateParams(BrowserContext* c,int s):context(c),site(s){}};
 static inline int destroyed=0;
 BrowserContext* context;RenderFrameHost primary{this};GURL url{"chrome-extension://fixture/popup.html"};bool visible=true;int resumed=0;NavigationController controller;std::shared_ptr<bool> life=std::make_shared<bool>(true);GlobalRenderFrameHostId opener{nullptr};
 explicit WebContents(BrowserContext* c):context(c){}
 ~WebContents(){*life=false;*primary.doc=false;++destroyed;}
 static std::unique_ptr<WebContents> Create(CreateParams p){auto child=std::make_unique<WebContents>(p.context);child->opener=p.opener_id;return child;}
 BrowserContext* GetBrowserContext(){return context;}
 RenderFrameHost* GetPrimaryMainFrame(){return &primary;}
 const GURL& GetLastCommittedURL(){return url;}
 base::WeakPtr<WebContents> GetWeakPtr(){return {this,life};}
 NavigationController& GetController(){return controller;}
 void ResumeLoadingCreatedWebContents(){++resumed;}
 static WebContents* FromRenderFrameHost(RenderFrameHost* frame){return frame->owner;}
};
}
namespace extensions {struct Extension{};}
class ConsentExtensionViewHost {
 public:
 struct Delegate{};
 ConsentExtensionViewHost(const extensions::Extension*,content::BrowserContext* context,const GURL&,std::unique_ptr<Delegate>,base::RepeatingCallback<bool()>):contents_(context){}
 virtual ~ConsentExtensionViewHost()=default;
 content::WebContents* host_contents()const{return const_cast<content::WebContents*>(&contents_);}
 std::string extension_id()const{return "fixture";}
 virtual content::WebContents* OpenURLFromTab(content::WebContents*,const content::OpenURLParams&,base::OnceCallback<void(content::NavigationHandle&)>){return nullptr;}
 virtual bool ShouldResumeRequestsForCreatedWindow(){return true;}
 virtual void WebContentsCreated(content::WebContents*,const content::GlobalRenderFrameHostId&,const std::string&,const GURL&,content::WebContents*){}
 virtual content::WebContents* AddNewContents(content::WebContents*,std::unique_ptr<content::WebContents>,const GURL&,WindowOpenDisposition,const blink::mojom::WindowFeatures&,bool,bool*){return nullptr;}
 private:content::WebContents contents_;
};
struct ExtensionActionHost {
 using RunScoped=base::RepeatingCallback<void(base::OnceClosure)>;
 using Offer=base::RepeatingCallback<content::WebContents*(std::unique_ptr<content::WebContents>,const GURL&,WindowOpenDisposition)>;
};
bool Visible(content::WebContents* contents){return contents->visible;}
// PRODUCTION_HOST
struct CallOwner {
 struct Factory {
  CallOwner* owner;
  base::WeakPtr<CallOwner> GetWeakPtr(){return {owner,owner->life};}
 } weak_factory_{this};
 std::shared_ptr<bool> life=std::make_shared<bool>(true);
 struct Popup {uint64_t id_=1;bool close_pending_=false;arx::ExtensionPopupEpoch epoch_;};
 bool current=true;unsigned popup_call_depth_=0;int closes=0,posted=0;
 std::vector<std::unique_ptr<Popup>> popups_;
 ExtensionActionHost::RunScoped run_{[](base::OnceClosure task){task.Run();}};
 Popup* FindPopup(uint64_t id){for(auto& popup:popups_)if(popup->id_==id)return popup.get();return nullptr;}
 bool PopupCurrent(const Popup&){return current;}
 void PostClose(Popup&){++posted;}
 // CALL_SCOPE
 // CLOSE_PREFIX
  ++closes;
 }
};
int main(){
 CallOwner owner;
 owner.popups_.push_back(std::make_unique<CallOwner::Popup>());
 auto& popup=*owner.popups_.back();
 owner.RunPopupScoped(1,[&]{assert(owner.popup_call_depth_==1);owner.ClosePopup(popup);assert(owner.closes==0&&popup.close_pending_);});
 assert(owner.posted==1&&owner.popup_call_depth_==0&&!popup.close_pending_);
 owner.ClosePopup(popup);assert(owner.closes==1);
 owner.RunPopupScoped(2,[&]{assert(false);});
 owner.current=false;owner.RunPopupScoped(1,[&]{assert(false);});
 content::BrowserContext context,foreign;bool current=true,accept=true;int offers=0;std::unique_ptr<content::WebContents> accepted;
 auto offer=[&](std::unique_ptr<content::WebContents> child,const GURL&,WindowOpenDisposition){++offers;assert(child->context==&context);if(!accept)return (content::WebContents*)nullptr;accepted=std::move(child);return accepted.get();};
 NavigableExtensionViewHost host(nullptr,&context,{},std::make_unique<ConsentExtensionViewHost::Delegate>(),[&]{return current;},[](base::OnceClosure task){task.Run();},offer);
 auto* source=host.host_contents();auto* frame=source->GetPrimaryMainFrame();
 content::OpenURLParams params;params.url={"https://example.test/child"};params.initiator_frame_token=&frame;params.referrer="https://referrer.test/exact";
 int navigations=0;
 assert(host.OpenURLFromTab(source,params,[&](content::NavigationHandle&){++navigations;})==accepted.get());
 assert(offers==1&&navigations==1&&accepted->controller.last_referrer==params.referrer&&accepted->opener.frame==frame);
 assert(!host.ShouldResumeRequestsForCreatedWindow());
 for(int reason=0;reason<6;++reason){
  auto bad=params;
  current=reason!=0;source->visible=reason!=1;
  if(reason==2)bad.url={"javascript:alert(1)"};
  if(reason==3)bad.url={"https://user:pass@example.test/"};
  if(reason==4)bad.disposition=WindowOpenDisposition::OFF_THE_RECORD;
  if(reason==5)bad.initiator_frame_token=nullptr;
  assert(!host.OpenURLFromTab(source,bad,{}));assert(offers==1);
 }
 current=true;source->visible=true;
 bool blocked=false;
 auto created=[&](content::BrowserContext* c){auto child=std::make_unique<content::WebContents>(c);host.WebContentsCreated(source,frame->GetGlobalId(),"",params.url,child.get());return child;};
 auto child=created(&context);auto* exact=child.get();
 assert(host.AddNewContents(source,std::move(child),params.url,params.disposition,{},true,&blocked)==exact);
 assert(!blocked&&offers==2&&!exact->resumed);base::SingleThreadTaskRunner::Drain();assert(exact->resumed==1);
 child=created(&context);*frame->doc=false;frame->doc=std::make_shared<bool>(true);
 assert(!host.AddNewContents(source,std::move(child),params.url,params.disposition,{},true,&blocked));assert(blocked&&offers==2);
 child=created(&foreign);assert(!host.AddNewContents(source,std::move(child),params.url,params.disposition,{},true,&blocked));assert(offers==2);
 child=std::make_unique<content::WebContents>(&context);assert(!host.AddNewContents(source,std::move(child),params.url,params.disposition,{},true,&blocked));assert(offers==2);
 child=created(&context);accept=false;const int before=content::WebContents::destroyed;
 assert(!host.AddNewContents(source,std::move(child),params.url,params.disposition,{},true,&blocked));assert(blocked&&content::WebContents::destroyed==before+1);
 accept=true;child=created(&context);assert(host.AddNewContents(source,std::move(child),params.url,params.disposition,{},true,&blocked));accepted.reset();base::SingleThreadTaskRunner::Drain(); // closing accepted child before resume is safe
}
