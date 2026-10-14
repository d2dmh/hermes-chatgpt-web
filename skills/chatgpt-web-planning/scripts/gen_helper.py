# browser_exec 里用的「整页生图」辅助函数（配合 chatgpt-web-planning 技能）
#
# 用法（每次 browser_exec 调用时）：
#     import sys
#     sys.path.insert(0, <本目录>)
#     import gen_helper as G
#     for n in ('new_tab','cdp','js','switch_tab','click_at_xy','wait_for_load'):
#         setattr(G, n, globals()[n])          # harness 的辅助函数在调用方的 globals 里，必须显式注入
#     tid = G.fresh_tab()
#     ...
#
# 关键经验（都是实际踩出来的，改代码前先读）：
#  1) 输入框 click_at_xy 可能不聚焦（activeElement 不是 contenteditable，发送按钮不渲染、
#     文字却进了 DOM）——此时用 JS focus() + range 全选 + Backspace 清空，再逐字符真键输入；
#     发送按钮会自动出现。
#  2) 长对话里页面会虚拟化，blob 图片数量只有 4–6 张且波动，绝不要用“图片数量”判完成/取图。
#     可靠的完成判据是“最后一张 blob 图的 src 变了”。
#  3) 取图只取“最后一张”（滚到底后即最新），并用 sha256 去重；不要用“取第 N 个”的启发式。
#  4) 落盘命名用“已保存计数器”，不要用页面序号——否则一旦某轮没取到，后面全错位。
import base64
import hashlib
import json
import os
import tempfile
import time
from typing import Any

PAGES_DIR = os.environ.get("PPT_PAGES_DIR") or os.path.join(tempfile.gettempdir(), "ppt-pages")
HASH_LOG = os.path.join(tempfile.gettempdir(), "ppt_hashes.json")

# 这些名字**由调用方注入**（见文件头用法）；下面只做类型声明，运行期不赋值——
# 调用前务必先 setattr 注入，否则会看到 NameError（这正是想要的诊断）。
new_tab: Any
wait_for_load: Any
cdp: Any
js: Any
switch_tab: Any
click_at_xy: Any


def load_hashes():
    if os.path.exists(HASH_LOG):
        return set(json.load(open(HASH_LOG)))
    return set()


def save_hashes(hs):
    json.dump(sorted(hs), open(HASH_LOG, "w"))


def fresh_tab(url="https://chatgpt.com/"):
    """开一个新标签并确认是空白新对话（客户端路由有时会把你带回旧对话）。"""
    new_tab(url)
    wait_for_load()
    time.sleep(3)
    pages = [x for x in cdp("Target.getTargets")["targetInfos"]
             if x.get("type") == "page" and x.get("url", "").startswith("https://chatgpt.com")]
    tid = pages[-1]["targetId"]
    switch_tab(tid, activate=True)
    return tid


def focus_composer(tid):
    """JS 聚焦输入框并全选内容；返回是否聚焦成功。"""
    r = js("""(() => {
      const cs=[...document.querySelectorAll('form div[contenteditable="true"]')].filter(e=>e.getBoundingClientRect().width>0);
      if(!cs.length) return JSON.stringify({ok:false, why:'no composer'});
      const el=cs[0]; el.focus();
      const sel=getSelection(); const r=document.createRange(); r.selectNodeContents(el);
      sel.removeAllRanges(); sel.addRange(r);
      return JSON.stringify({ok: document.activeElement===el && document.activeElement.isContentEditable, len: el.innerText.length});
    })()""", target_id=tid)
    return json.loads(r)


def type_and_send(tid, msg):
    """清空输入框 -> 逐字符真键输入 -> 点发送。返回是否发出。"""
    switch_tab(tid, activate=True)
    time.sleep(2)
    st = focus_composer(tid)
    if not st.get("ok"):
        rect = json.loads(js("""(() => { const cs=[...document.querySelectorAll('form div[contenteditable="true"]')].filter(e=>e.getBoundingClientRect().width>0);
          const r=cs[0].getBoundingClientRect(); return JSON.stringify({x:Math.round(r.x+r.width/2), y:Math.round(r.y+r.height/2)}); })()""", target_id=tid))
        click_at_xy(rect["x"], rect["y"])
        time.sleep(1)
        st = focus_composer(tid)
        if not st.get("ok"):
            return False
    sid = cdp("Target.attachToTarget", targetId=tid, flatten=True)["sessionId"]
    if st.get("len"):
        cdp("Input.dispatchKeyEvent", session_id=sid, type="keyDown", key="Backspace", code="Backspace", windowsVirtualKeyCode=8)
        cdp("Input.dispatchKeyEvent", session_id=sid, type="keyUp", key="Backspace", code="Backspace", windowsVirtualKeyCode=8)
        time.sleep(1)
    for ch in msg:
        cdp("Input.dispatchKeyEvent", session_id=sid, type="keyDown", text=ch, unmodifiedText=ch)
        cdp("Input.dispatchKeyEvent", session_id=sid, type="keyUp", text=ch, unmodifiedText=ch)
    time.sleep(3)
    b = json.loads(js("""(() => { const bs=[...document.querySelectorAll('button')].filter(b=>{const l=(b.getAttribute('aria-label')||'')+(b.getAttribute('data-testid')||'');
      return b.getBoundingClientRect().width>0 && /发送|Send|send-button/i.test(l);});
      const x=bs[bs.length-1]; return x? JSON.stringify({x:Math.round(x.getBoundingClientRect().x+x.getBoundingClientRect().width/2), y:Math.round(x.getBoundingClientRect().y+x.getBoundingClientRect().height/2)}):'null'; })()""", target_id=tid))
    if b == "null":
        return False
    click_at_xy(b["x"], b["y"])
    time.sleep(4)
    return True


LASTSRC = """(() => { const is=[...document.querySelectorAll('img')].filter(i=>((i.currentSrc||i.src||'').startsWith('blob:')));
  const im=is[is.length-1]; return im ? im.currentSrc : ''; })()"""


def wait_new_image(tid, prev_src, timeout=240):
    """等“最后一张 blob 图”的 src 变化（页面虚拟化时这是唯一可靠的完成判据）。"""
    t0 = time.time()
    while time.time() - t0 < timeout:
        time.sleep(10)
        js("window.scrollTo(0, document.body.scrollHeight)", target_id=tid)
        cur = js(LASTSRC, target_id=tid)
        if cur and cur != prev_src:
            time.sleep(6)          # 让它画完
            return True
    return False


def grab_newest(tid, out_path):
    """取页面里最后一张 blob 图的原始字节（不是截图），按 sha256 去重后落盘。"""
    js("window.scrollTo(0, document.body.scrollHeight)", target_id=tid)
    time.sleep(1)
    js("""(() => { window.__last=null;
      const is=[...document.querySelectorAll('img')].filter(i=>((i.currentSrc||i.src||'').startsWith('blob:')));
      const im=is[is.length-1]; if(!im) return 'none';
      fetch(im.currentSrc).then(r=>r.arrayBuffer()).then(buf=>{
        const u8=new Uint8Array(buf); let bin=''; const c=0x8000;
        for(let i=0;i<u8.length;i+=c) bin+=String.fromCharCode.apply(null,u8.subarray(i,i+c));
        window.__last={b64:btoa(bin), size:u8.length, w:im.naturalWidth, h:im.naturalHeight};
      }).catch(e=>{ window.__last={err:String(e)}; });
      return 'started'; })()""", target_id=tid)
    meta = None
    for _ in range(20):
        time.sleep(1.5)
        meta = json.loads(js("JSON.stringify(window.__last && {size:window.__last.size, w:window.__last.w, h:window.__last.h, has:!!window.__last.b64} || null)", target_id=tid) or "null")
        if meta and meta.get("has"):
            break
    if not meta or not meta.get("has"):
        return {"error": "fetch failed", "meta": meta}
    off, parts = 0, []
    while True:
        chunk = js("(window.__last.b64||'').substr(%d,200000)" % off, target_id=tid)
        if not chunk:
            break
        parts.append(chunk)
        off += len(chunk)
        if len(chunk) < 200000:
            break
    raw = base64.b64decode("".join(parts))
    h = hashlib.sha256(raw).hexdigest()
    seen = load_hashes()
    if h in seen:
        return {"duplicate": True, "sha256": h}   # 说明这轮还没出图或取到了旧图
    seen.add(h)
    save_hashes(seen)
    os.makedirs(PAGES_DIR, exist_ok=True)
    path = os.path.join(PAGES_DIR, out_path)
    with open(path, "wb") as f:
        f.write(raw)
    return {"path": path, "bytes": len(raw), "sha256": h, "dims": [meta["w"], meta["h"]]}
