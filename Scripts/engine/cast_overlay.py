"""Turn Chrome's Cast back on and give it Arx's picker (DEV-927).

Helium builds without mDNS and service discovery (`enable_mdns=false`,
`enable_service_discovery=false` in its `flags.gn`), so the Media Router finds
no Cast devices. `build.py` turns both GN args back on; these edits undo the
ungoogled-chromium patches that only exist to build without them, and nothing
else:

* `fix-building-without-mdns-and-service-discovery.patch` empties
  `DnsSdDeviceLister` and drops the registry's service discovery client, so
  mDNS (`_googlecast._tcp`) would find nothing even with the flags on. Its
  removed lines are put back as upstream Chromium has them.
* `disable-dial-repeating-discovery.patch` stops DIAL's SSDP search before it
  starts. Upstream's first search and its periodic repeat are put back.
* Domain substitution rewrote the Google and YouTube origins the Cast and DIAL
  providers compare a page's origin with, and the legacy Cast presentation URL
  prefix, so they match nothing. Only the production origins are restored (the
  hosts are in `allowed-hosts.json`); none is fetched.

Chrome's Cast dialog is a views bubble on a Chrome browser window, which Arx
pages don't have. `chrome_browser_main_extra_parts_views.cc` keeps installing
Chrome's dialog controller, but asks Arx first through `cast_hooks.h`; Arx's
controller (`Native/cast_bridge.mm`) hands the Media Router's devices to the
app's picker.
"""
from .overlay import replace_once

MDNS = "chrome/browser/media/router/discovery/mdns"
LISTER = f"{MDNS}/dns_sd_device_lister.cc"
REGISTRY = f"{MDNS}/dns_sd_registry.cc"
REGISTRY_HEADER = f"{MDNS}/dns_sd_registry.h"
DIAL = "chrome/browser/media/router/discovery/dial/dial_registry.cc"
MEDIA_SOURCE = "components/media_router/common/media_source.h"
CAST_PROVIDER = "chrome/browser/media/router/providers/cast/cast_media_route_provider.cc"
DIAL_PROVIDER = "chrome/browser/media/router/providers/dial/dial_media_route_provider.cc"
VIEWS_PARTS = "chrome/browser/ui/views/chrome_browser_main_extra_parts_views.cc"


def mdns():
    yield LISTER, """void DnsSdDeviceLister::Discover() {
}

void DnsSdDeviceLister::Reset() {
}

void DnsSdDeviceLister::OnDeviceChanged(
    const std::string& service_type,
    bool added,
    const ServiceDescription& service_description) {
}

void DnsSdDeviceLister::OnDeviceRemoved(const std::string& service_type,
                                        const std::string& service_name) {
}

void DnsSdDeviceLister::OnDeviceCacheFlushed(const std::string& service_type) {
}
""", """void DnsSdDeviceLister::Discover() {
#if BUILDFLAG(ENABLE_SERVICE_DISCOVERY)
  if (!device_lister_) {
    device_lister_ = local_discovery::ServiceDiscoveryDeviceLister::Create(
        this, service_discovery_client_, service_type_);
    device_lister_->Start();
  }
  device_lister_->DiscoverNewDevices();
#endif
}

void DnsSdDeviceLister::Reset() {
  device_lister_.reset();
}

void DnsSdDeviceLister::OnDeviceChanged(
    const std::string& service_type,
    bool added,
    const ServiceDescription& service_description) {
  DnsSdService service;
  FillServiceInfo(service_description, &service);
  delegate_->ServiceChanged(device_lister_->service_type(), added, service);
}

void DnsSdDeviceLister::OnDeviceRemoved(const std::string& service_type,
                                        const std::string& service_name) {
  delegate_->ServiceRemoved(service_type, service_name);
}

void DnsSdDeviceLister::OnDeviceCacheFlushed(const std::string& service_type) {
  delegate_->ServicesFlushed(device_lister_->service_type());
  device_lister_->DiscoverNewDevices();
}
"""

    yield REGISTRY, """DnsSdRegistry::~DnsSdRegistry() {
  DCHECK(thread_checker_.CalledOnValidThread());
}
""", """DnsSdRegistry::DnsSdRegistry(
    local_discovery::ServiceDiscoverySharedClient* client) {
  service_discovery_client_ = client;
}

DnsSdRegistry::~DnsSdRegistry() {
  DCHECK(thread_checker_.CalledOnValidThread());
}
"""
    yield REGISTRY, """DnsSdDeviceLister* DnsSdRegistry::CreateDnsSdDeviceLister(
    DnsSdDelegate* delegate,
    const std::string& service_type) {
  return new DnsSdDeviceLister(nullptr, delegate, service_type);
}""", """DnsSdDeviceLister* DnsSdRegistry::CreateDnsSdDeviceLister(
    DnsSdDelegate* delegate,
    const std::string& service_type,
    local_discovery::ServiceDiscoverySharedClient* discovery_client) {
  return new DnsSdDeviceLister(discovery_client, delegate, service_type);
}"""
    yield REGISTRY, """      CreateDnsSdDeviceLister(this, service_type));""", \
        """      CreateDnsSdDeviceLister(this, service_type,
                              service_discovery_client_.get()));"""
    yield REGISTRY, """void DnsSdRegistry::ResetForTest() {
  service_data_map_.clear();
}""", """void DnsSdRegistry::ResetForTest() {
  service_data_map_.clear();
  service_discovery_client_.reset();
}"""

    yield REGISTRY_HEADER, """#include "chrome/browser/media/router/discovery/mdns/dns_sd_delegate.h"

namespace media_router {
""", """#include "chrome/browser/media/router/discovery/mdns/dns_sd_delegate.h"

namespace local_discovery {
class ServiceDiscoverySharedClient;
}

namespace media_router {
"""
    yield REGISTRY_HEADER, """  virtual DnsSdDeviceLister* CreateDnsSdDeviceLister(
      DnsSdDelegate* delegate,
      const std::string& service_type);""", """  virtual DnsSdDeviceLister* CreateDnsSdDeviceLister(
      DnsSdDelegate* delegate,
      const std::string& service_type,
      local_discovery::ServiceDiscoverySharedClient* discovery_client);"""
    yield REGISTRY_HEADER, """  DnsSdRegistry();
  virtual ~DnsSdRegistry();
""", """  DnsSdRegistry();
  explicit DnsSdRegistry(local_discovery::ServiceDiscoverySharedClient* client);
  virtual ~DnsSdRegistry();
"""
    yield REGISTRY_HEADER, """  base::ObserverList<DnsSdObserver>::Unchecked observers_;
  base::ThreadChecker thread_checker_;
};""", """  scoped_refptr<local_discovery::ServiceDiscoverySharedClient>
      service_discovery_client_;
  base::ObserverList<DnsSdObserver>::Unchecked observers_;
  base::ThreadChecker thread_checker_;
};"""


def dial():
    yield DIAL, """  dial_ = CreateDialService();
  // Always send the current device list with the next discovery request.""", \
        """  dial_ = CreateDialService();
  DoDiscovery();
  repeating_timer_ = std::make_unique<base::RepeatingTimer>();
  repeating_timer_->Start(FROM_HERE, refresh_interval_delta_, this,
                          &DialRegistry::DoDiscovery);
  // Always send the current device list with the next discovery request."""
    yield DIAL, """  if (!dial_) {
    return;
  }

  ClearDialService();
}""", """  if (!dial_) {
    return;
  }

  repeating_timer_->Stop();
  repeating_timer_.reset();
  ClearDialService();
}"""


def origins():
    yield MEDIA_SOURCE, '    "https://9oo91e.qjz9zk/cast#__castAppId__=";', \
        '    "https://google.com/cast#__castAppId__=";'
    yield CAST_PROVIDER, """    "https://docs.9oo91e.qjz9zk",
    "https://meet.9oo91e.qjz9zk",
    "https://music.y0u1ub3.qjz9zk",""", """    "https://docs.google.com",
    "https://meet.google.com",
    "https://music.youtube.com","""
    yield DIAL_PROVIDER, '            {CreateOrigin("https://music.y0u1ub3.qjz9zk/"),', \
        '            {CreateOrigin("https://music.youtube.com/"),'
    yield DIAL_PROVIDER, '             CreateOrigin("https://tv.y0u1ub3.qjz9zk"),', \
        '             CreateOrigin("https://tv.youtube.com"),'
    yield DIAL_PROVIDER, '             CreateOrigin("https://www.y0u1ub3.qjz9zk")}},', \
        '             CreateOrigin("https://www.youtube.com")}},'


def picker():
    yield VIEWS_PARTS, '#include "components/media_router/browser/media_router_dialog_controller.h"\n', \
        '#include "components/media_router/browser/media_router_dialog_controller.h"\n' \
        '''#include "build/build_config.h"
#if BUILDFLAG(IS_MAC)
#include "chrome/browser/arx/cast_hooks.h"  // nogncheck

namespace arx {
namespace {
CastDialogFactory& CastDialogFactoryHook() {
  static CastDialogFactory factory = nullptr;
  return factory;
}
}  // namespace

void SetCastDialogFactory(CastDialogFactory factory) {
  CastDialogFactoryHook() = factory;
}
}  // namespace arx
#endif
'''
    yield VIEWS_PARTS, """      base::BindRepeating([](content::WebContents* web_contents) {
        DCHECK(web_contents);
        media_router::MediaRouterDialogController* controller = nullptr;""", \
        """      base::BindRepeating([](content::WebContents* web_contents) {
        DCHECK(web_contents);
#if BUILDFLAG(IS_MAC)
        // Arx (DEV-927) shows its own Cast picker; Chrome's would need a
        // Chrome browser window.
        if (const arx::CastDialogFactory factory =
                arx::CastDialogFactoryHook()) {
          return factory(web_contents);
        }
#endif
        media_router::MediaRouterDialogController* controller = nullptr;"""


def patches():
    yield from mdns()
    yield from dial()
    yield from origins()
    yield from picker()


def apply(source):
    for relative, before, after in patches():
        replace_once(source / relative, before, after)
