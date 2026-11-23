"""Owned VP8/Opus fixture with silent audio for staged native media/PiP checks. No external requests."""

import hashlib
import re
from pathlib import Path
from urllib.parse import urlsplit

VIDEO = Path(__file__).resolve().parents[1] / "fixtures/media/pattern.webm"
VIDEO_SHA256 = "cdf2634379d6918d6664b79b64fba5483c4992df19dac7f6273b621fc6832282"
# DEV-848: the same pattern at 90x160, for PiP's aspect ratio.
PORTRAIT_VIDEO = VIDEO.with_name("pattern-portrait.webm")
PORTRAIT_VIDEO_SHA256 = "394af2f3ea57e360fdf2580b678c23aba8304d819217d8c62ec1ad1504e2239c"
VIDEOS = {
    "/media/pattern.webm": (VIDEO, VIDEO_SHA256),
    "/media/pattern-portrait.webm": (PORTRAIT_VIDEO, PORTRAIT_VIDEO_SHA256),
}
CASES = {"normal", "second", "private", "late", "remove", "automatic", "automatic-delayed", "manual-only", "portrait"}


def document(case):
    if case not in CASES:
        raise ValueError("Unknown media fixture")
    delay = 6_000 if case == "late" else 750 if case == "automatic-delayed" else 0
    portrait = case == "portrait"
    source = "/media/pattern-portrait.webm" if portrait else "/media/pattern.webm"
    # Either way the video ends above the Start button, which stays where the runner clicks.
    size = "width:152px;height:270px" if portrait else "width:480px;height:270px"
    # Controlled metadata is constant; document.title is the observable test state. Beside it, for
    # a runner's timeout to tell a load that never started (a page still hidden), a stalled fetch
    # and a title that stopped reaching the app: the page's visibility, the video's ready and
    # network states, and how many reports the page has made (DEV-1177).
    return f'''<!doctype html><meta charset="utf-8"><title>Arx media loading</title>
<style>body{{margin:0;background:#123;color:white;font:16px system-ui}}video{{{size}}}
#start{{position:absolute;left:16px;top:286px;width:200px;height:44px}}</style>
<video id="video" preload="auto" loop playsinline src="{source}"></video>
<button id="start" type="button">Start controlled media</button>
<script>
const video=document.querySelector('video');
const state={{case:{case!r},ready:false,starts:0,trustedStarts:0,playing:false,pip:false,loads:0,plays:0,pauses:0,entered:0,left:0,requests:0,error:null,active:false,activeAtRequest:null,entryReason:null,reports:0}};
const report=()=>{{state.active=navigator.userActivation.isActive;state.time=Math.round(video.currentTime*1000)/1000;
 state.visibility=document.visibilityState;state.videoReady=video.readyState;state.network=video.networkState;state.reports++;
 document.title='Arx media '+JSON.stringify(state)}};
setInterval(report,100);
document.querySelector('#start').addEventListener('click',event=>{{
 if(!event.isTrusted||state.starts!==0)return;
 state.starts++;state.trustedStarts++;event.currentTarget.disabled=true;report();
 video.play().catch(()=>{{state.error='start';report()}});
}});
video.addEventListener('canplay',()=>{{state.ready=true;report()}});
navigator.mediaSession.metadata=new MediaMetadata({{title:'Arx {case} media sentinel',artist:'Controlled fixture'}});
navigator.mediaSession.setActionHandler('play',()=>video.play().catch(()=>{{state.error='play';report()}}));
navigator.mediaSession.setActionHandler('pause',()=>video.pause());
if(state.case!=='manual-only')navigator.mediaSession.setActionHandler('enterpictureinpicture',details=>{{
 state.requests++;state.activeAtRequest=navigator.userActivation.isActive;
 state.entryReason=details.enterPictureInPictureReason;report();
 const enter=()=>video.requestPictureInPicture().catch(()=>{{state.error='pip-denied';report()}});
 if({delay})setTimeout(enter,{delay});else enter();
}});
video.addEventListener('loadedmetadata',()=>{{state.loads++;report()}});
video.addEventListener('play',()=>{{state.plays++;report()}});
video.addEventListener('playing',()=>{{state.playing=true;navigator.mediaSession.playbackState='playing';report()}});
video.addEventListener('pause',()=>{{state.playing=false;state.pauses++;navigator.mediaSession.playbackState='paused';report()}});
video.addEventListener('enterpictureinpicture',()=>{{state.pip=true;state.entered++;report();
 if(state.case==='remove')setTimeout(()=>{{video.removeAttribute('src');video.load();video.remove();report()}},250);
}});
video.addEventListener('leavepictureinpicture',()=>{{state.pip=false;state.left++;report()}});
video.addEventListener('error',()=>{{state.error='video';report()}});
state.ready=video.readyState>=2;report();
</script>'''.encode()


def full_screen_document():
    """DEV-949: a <video> and a <div> that a trusted click on Start puts in HTML full screen in
    turn. document.title reports the full-screen element and the page's size, with a count of its
    reports (DEV-1183).

    DEV-991: the first click also plays the video, with its silent audio, so automatic PiP could
    take it, and its own enterpictureinpicture handler floats it as a video site's would; it pauses
    whenever the page leaves full screen. X leaves through the page's own
    document.exitFullscreen()."""
    return '''<!doctype html><meta charset="utf-8"><title>Arx full screen loading</title>
<style>body{margin:0;background:#123;color:white;font:16px system-ui}video{width:480px;height:270px}
#box{position:absolute;left:240px;top:286px;width:200px;height:44px;background:#456}
#start{position:absolute;left:16px;top:286px;width:200px;height:44px}</style>
<video id="video" preload="auto" loop playsinline src="/media/pattern.webm"></video>
<div id="box">Controlled box</div>
<button id="start" type="button">Start controlled full screen</button>
<script>
const targets=['video','box'];
const video=document.querySelector('video');
const state={ready:true,requests:0,entered:0,left:0,element:null,width:0,height:0,displayMode:null,error:null,
 playing:false,pip:false,pipEntries:0,reports:0};
// DEV-1183: a count of reports, so a timeout tells a page that keeps its old size from a title
// that stopped reaching the app.
const report=()=>{state.reports++;state.element=document.fullscreenElement?document.fullscreenElement.id:null;
 state.width=innerWidth;state.height=innerHeight;
 state.displayMode=matchMedia('(display-mode: fullscreen)').matches?'fullscreen':'browser';
 state.playing=!video.paused;state.pip=document.pictureInPictureElement!==null;
 document.title='Arx full screen '+JSON.stringify(state)};
setInterval(report,100);
document.querySelector('#start').addEventListener('click',event=>{
 if(!event.isTrusted)return;
 const target=document.getElementById(targets[state.requests%2]);
 if(state.requests===0)video.play().catch(()=>{state.error='play';report()});
 state.requests++;report();
 target.requestFullscreen().catch(()=>{state.error='denied';report()});
});
document.addEventListener('keydown',event=>{
 if(event.key==='x'&&document.fullscreenElement)document.exitFullscreen().catch(()=>{state.error='exit';report()});
});
// Like a video site's own: automatic PiP asks the page, which floats its video.
navigator.mediaSession.setActionHandler('enterpictureinpicture',()=>video.requestPictureInPicture().catch(()=>{}));
video.addEventListener('enterpictureinpicture',()=>{state.pipEntries++;report()});
document.addEventListener('fullscreenchange',()=>{
 if(document.fullscreenElement){state.entered++}else{state.left++;video.pause()}
 report();
});
report();
</script>'''.encode()


def page_picture_document():
    """DEV-950: a counter and a text field for Page PiP. document.title reports the page's load
    identity, so a reload shows, with the trusted clicks and the text typed."""
    return '''<!doctype html><meta charset="utf-8"><title>Arx page picture loading</title>
<style>body{margin:0;background:#123;color:white;font:16px system-ui}
#count{position:absolute;left:16px;top:16px;width:200px;height:44px}
#text{position:absolute;left:16px;top:76px;width:200px;height:32px}</style>
<button id="count" type="button">Count</button>
<input id="text" type="text" autocomplete="off">
<script>
const state={ready:true,load:Math.random().toString(36).slice(2),clicks:0,text:''};
const report=()=>{state.text=document.querySelector('#text').value.slice(0,64);
 document.title='Arx page picture '+JSON.stringify(state)};
document.querySelector('#count').addEventListener('click',event=>{if(event.isTrusted){state.clicks++;report()}});
document.querySelector('#text').addEventListener('input',report);
setInterval(report,100);
report();
</script>'''.encode()


def serve(handler):
    path = urlsplit(handler.path).path
    if path in ("/media/full-screen.html", "/media/page-picture.html"):
        page = full_screen_document if path == "/media/full-screen.html" else page_picture_document
        payload, mime = page(), "text/html; charset=utf-8"
        handler.send_response(200)
        handler.send_header("Content-Type", mime)
        handler.send_header("Cache-Control", "no-store")
        handler.send_header("Content-Length", str(len(payload)))
        handler.end_headers()
        handler.wfile.write(payload)
        return True
    if path in VIDEOS:
        video, digest = VIDEOS[path]
        payload = video.read_bytes()
        if hashlib.sha256(payload).hexdigest() != digest:
            raise ValueError("Media fixture bytes differ from the checked-in source")
        mime = "video/webm"
    elif path.startswith("/media/") and path.endswith(".html"):
        case = path[len("/media/"):-len(".html")]
        if case not in CASES:
            return False
        payload, mime = document(case), "text/html; charset=utf-8"
    else:
        return False
    start, end, status = 0, len(payload) - 1, 200
    byte_range = handler.headers.get("Range")
    if byte_range and mime == "video/webm":
        match = re.fullmatch(r"bytes=(\d+)-(\d*)", byte_range)
        if not match or int(match[1]) >= len(payload) or (match[2] and int(match[2]) < int(match[1])):
            handler.send_response(416)
            handler.send_header("Content-Range", f"bytes */{len(payload)}")
            handler.send_header("Content-Length", "0")
            handler.end_headers()
            return True
        start, end, status = int(match[1]), min(int(match[2]) if match[2] else end, end), 206
    handler.send_response(status)
    handler.send_header("Content-Type", mime)
    handler.send_header("Cache-Control", "no-store")
    handler.send_header("Content-Length", str(end - start + 1))
    handler.send_header("Accept-Ranges", "bytes")
    if status == 206:
        handler.send_header("Content-Range", f"bytes {start}-{end}/{len(payload)}")
    handler.end_headers()
    handler.wfile.write(payload[start:end + 1])
    return True
