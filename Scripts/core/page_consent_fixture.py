"""Owned permission UI pages; no captured media, location data, or external launch.

The native host must explicitly configure content hosting on each source. Pages
exercise renderer permission APIs. They never automatically approve native or OS
prompts and report only bounded outcome categories, not device/location values.
"""
from urllib.parse import urlsplit

TITLE = 'Arx page consent fixture'
HTML = r'''<!doctype html><meta charset="utf-8"><title>Arx page consent loading</title>
<style>body{font:16px system-ui;margin:24px;max-width:760px;padding-top:64px}#idle{position:fixed;left:16px;top:16px;width:232px;height:42px;z-index:1}button{display:block;margin:12px;padding:12px}iframe{width:680px;height:330px;border:2px solid #999}output{display:block;white-space:pre-wrap}</style>
<h1>Arx page consent fixture</h1>
<p>Use disposable fixture storage. Allow or block the native website prompt. macOS can ask separately. Captured tracks stop immediately; no media or coordinates are recorded.</p>
<button id="idle">Request idle-detection permission only</button>
<button id="geo">Request location</button>
<button id="notifications">Request notifications</button>
<button id="audio">Request microphone</button>
<button id="video">Request camera</button>
<button id="screen">Request screen sharing</button>
<button id="navigate">Request then navigate before deciding</button>
<button id="replace">Request in frame then replace source frame</button>
<button id="frame">Show cross-origin permission source</button>
<output id="result" aria-live="polite">ready</output>
<iframe id="source" title="Permission source" allow="geolocation; microphone; camera"></iframe>
<script>
const result=document.getElementById('result');
function show(kind,outcome){result.textContent=kind+':'+outcome;document.title='Arx consent '+kind+' '+outcome;}
function geo(){navigator.geolocation.getCurrentPosition(()=>show('location','allowed'),e=>show('location',e.code===1?'denied':'unavailable'),{timeout:10000,maximumAge:0});}
async function media(kind){try{
 const stream=kind==='screen'?await navigator.mediaDevices.getDisplayMedia({video:true,audio:false}):await navigator.mediaDevices.getUserMedia({audio:kind==='audio',video:kind==='video'});
 const tracks=stream.getTracks();for(const track of tracks)track.stop();show(kind,'allowed-and-stopped');
}catch(error){show(kind,error.name==='NotAllowedError'?'denied':'unavailable');}}
document.getElementById('idle').onclick=async()=>{
 // Chrome always denies idle detection off the record, after a random delay
 // and without a prompt. Private checks request location from the same spot.
 if(new URLSearchParams(location.search).get('kind')==='location'){geo();return;}
 if(!('IdleDetector' in window)){show('idle','unavailable');return;}
 const pending=IdleDetector.requestPermission();
 if(new URLSearchParams(location.search).get('phase')==='navigate')setTimeout(()=>location.assign('/page-consent/destination.html'),400);
 show('idle',await pending);
};
document.getElementById('geo').onclick=geo;
document.getElementById('notifications').onclick=async()=>show('notifications',await Notification.requestPermission());
for(const kind of ['audio','video','screen'])document.getElementById(kind).onclick=()=>media(kind);
document.getElementById('navigate').onclick=()=>{geo();setTimeout(()=>location.assign('/page-consent/destination.html'),400);};
document.getElementById('replace').onclick=()=>{
 const frame=document.getElementById('source');frame.src='/page-consent/frame.html?replace=1';
};
document.getElementById('frame').onclick=()=>{
 const frame=document.getElementById('source');
 const url=new URL('/page-consent/frame.html',location.href);url.hostname=location.hostname==='127.0.0.1'?'localhost':'127.0.0.1';frame.src=url;
};
// Announce readiness only after a frame is presented, so native clicks hit-test.
requestAnimationFrame(()=>requestAnimationFrame(()=>{document.title='Arx page consent fixture';}));
</script>'''
FRAME = r'''<!doctype html><meta charset="utf-8"><title>Arx consent frame</title>
<h2>Requesting frame</h2><button id="request">Request location from this frame</button>
<output id="result">ready</output><script>
document.getElementById('request').onclick=()=>{
 navigator.geolocation.getCurrentPosition(()=>document.getElementById('result').textContent='allowed',e=>document.getElementById('result').textContent=e.code===1?'denied':'unavailable',{timeout:10000});
 if(new URLSearchParams(location.search).has('replace'))setTimeout(()=>location.replace('/page-consent/destination.html'),400);
};</script>'''
DESTINATION = '<!doctype html><meta charset="utf-8"><title>Arx consent destination</title><h1>Original requesting document has been replaced</h1>'


def serve(handler):
    request = urlsplit(handler.path)
    if not request.path.startswith('/page-consent/'):
        return False
    pages = {'/page-consent/main.html': HTML, '/page-consent/frame.html': FRAME,
             '/page-consent/destination.html': DESTINATION}
    body = pages.get(request.path)
    if body is None or len(request.query) > 64:
        handler.send_error(404)
        return True
    encoded = body.encode()
    handler.send_response(200)
    handler.send_header('Content-Type', 'text/html; charset=utf-8')
    handler.send_header('Cache-Control', 'no-store')
    handler.send_header('Permissions-Policy', 'geolocation=*, microphone=*, camera=*')
    handler.send_header('Content-Length', str(len(encoded)))
    handler.end_headers()
    handler.wfile.write(encoded)
    return True


def prepare(root):
    """The signed disposable app runner creates/validates root before calling."""
    destination = root / 'page-consent'
    destination.mkdir()
    for name, body in {'main.html': HTML, 'frame.html': FRAME,
                       'destination.html': DESTINATION}.items():
        with (destination / name).open('x') as stream:
            stream.write(body)
