# 取回网页端生成的素材（图片 / 视频 / PDF）

用于：用户要网页 ChatGPT 生图/生视频/出成品文件，且成品要落到工作区。
连接器是**只读**的（ChatGPT 能 `read_image` 读文件，但不能写进仓库），所以取回必须是
「页面里的真实控件 → 取回**原始字节** → 本地导入」这条路。
**截图永远不算成品**，截图只能当导航证据。

## 步骤

1. 提要求时明确写「请真正调用图像生成工具，不要用代码或 SVG 绘制」——
   否则它可能写一段代码画图，看起来像生图，其实没调用模型。
2. 等生成结束，**判据只认 `img[src^="blob:"]` 的图数 > 0**（`naturalWidth/Height` 就是原生分辨率）。
   **长对话里页面会虚拟化**：可见的 blob 图只有 4–6 张且来回波动，所以
   **"图片数量"不是可靠的完成判据**——更稳的是**"最后一张 blob 图的 `src` 变了"**
   （先记下 `src`，轮询到变化为止；辅助函数见 `scripts/gen_helper.py` 的 `wait_new_image()`）。
   每 15s 轮询一次「blob 图数 + 正文末尾」即可（本机 1 张约 45s，成组出图 1–2 分钟）。
   **不要拿正文里的「回答已完成」当结束信号**：它是页面的 aria-live 播报区，正文还停在「思考中」、
   进度只到 88% 的时候它就已经出现了（实测在 blob 图数为 0 时就读到「回答已完成」）。
   图出现后再多等一轮（约 20s），确认正文里的「正在回应 / 思考中」消失再取字节。
   **一轮出多少张由它自己定，可能少于你要的**（要 4 张只给 3 张）——别在页面里干等，
   直接在同一对话里追加一句「再补 N 张，风格和前面几张拉开差异」，追加产出的新图照下面的哈希法识别。
3. **即使提示词里写了「交付前先自审并写出审查结论」，纯生图任务它也可能只交图、一个字不写。**
   这不是失败信号（图本身已过审），**不要为此重发或追问**，直接把图取回交付；
   要审查意见就另开一个会话让它当评审者。
4. 图片悬浮时只有「编辑 / 分享」，**没有下载按钮**。先点开图片进查看器，右上角才出现
   「下载 / 分享 / 关闭查看器」。
5. 用真实鼠标点「下载」（`click_at_xy`，或点 `button[aria-label="下载"]`）。
   文件落到浏览器默认下载目录（macOS `~/Downloads`，Windows `%USERPROFILE%\Downloads`），
   文件名是生成标题而不是随机串。
   **点完必须核实文件真的落盘**：看下载目录里最新的文件，再查浏览器下载库
   （macOS：`cp <profile>/Default/History /tmp/h.db` 后
   `sqlite3 /tmp/h.db "select target_path,state from downloads order by start_time desc limit 5"`；
   Windows：把 `<profile>\Default\History` 复制出来再用 sqlite 读。**库是锁着的，必须先复制**）。
   **库里没有新记录 = 这次点击根本没触发下载**（该控件走系统保存对话框）。
   此时不要反复重试点击（真实点击、JS `.click()`、指定下载目录都试过，都不会落盘），
   直接走下面「读页面字节」的兜底：那条路已验证可用，拿到的与原图**逐字节相同**。
6. 本地先确认它是真位图而不是截图：`file <path>`（Windows 用
   `python -c "print(open(r'<path>','rb').read(8))"`）、尺寸、字节数；更硬的证据跑
   `scripts/verify_asset_origin.py <path>`。
7. 导入工作区：

   ```bash
   node <c2c检出目录>/bin/c2c.js asset import -w <workspace> \
     --from <下载文件绝对路径> --to <新的工作区相对路径> --json
   ```

   目标必须是不存在的新路径、工作区内相对路径；importer 校验
   PNG/JPEG/GIF/WebP/SVG/MP4/MOV/WebM，拒绝活动 SVG 与路径逃逸，且**绝不覆盖**已有文件。
   视频同理，走同一个查看器的下载控件。
   **落盘命名用「已保存计数器」，不要用页码索引**：某一轮超时没取到，按索引命名就会整体错位
   （实测把第 8 页存成了 `p09.png`，之后全乱，只能靠看图认页码再改名）。
   **多张图逐张导入时，先把「源文件 → 目标名」的映射写死再执行**：`--to` 与 `--from` 配错不会报错
   （importer 只校验媒体类型），你会得到一张文件名与内容不符的图，而「绝不覆盖」意味着只能先删掉
   错文件再重导。导完把每个工作区文件的 sha256 与本地源文件对一遍再写进汇报。
8. 汇报时给全：工作区路径 + 尺寸 + 字节数 + sha256。

## 验真（用户会问「这是原图吗」）

三条独立证据，缺一条都可能只是缩略图或截图：

1. **与页面同源**：页面里 `fetch(blobURL).then(r=>r.blob()).then(b=>window.__sz=b.size)`，
   拿到的字节数与落盘文件相等 → 与页面上那张是逐字节同一份。
2. **容器结构**：真 PNG 有 `IHDR`（分辨率/位深/色彩类型）+ `IDAT`。
   截图也是 PNG，所以这条只能排除「被重新编码过」。
3. **出处签名**：OpenAI 生图带一个 `caBX` 块（C2PA 内容凭证），内含 `OpenAI OpCo, LLC`、
   `dname=ChatGPT`、`version=gpt-image`、`digitalSourceType=…/trainedAlgorithmicMedia`，
   以及 OpenAI 的签名/时间戳 CA 链。**截图或任何重新编码都不会带这些**——
   这是「模型原始产出」的决定性证据。

给用户看图时：原图偏大就先出缩略图再贴（见 `cross-platform.md` 里的缩略图命令），
但必须**明说那是缩略图**并同时给出原图路径——否则用户会以为你拿到的就是缩略图。

## 兜底：直接读页面里的原始字节

下载控件不落盘时（判据见步骤 5），取页面里那张图自己的 blob 字节写成本地文件——
同样是模型原始产出，**不是截图**。

先把图挂成 base64（用 `js(expr, target_id=<自己的标签>)`，**不要裸 `js()`**）：

```js
window.__b64=null; window.__meta=null;
fetch(IM.currentSrc).then(r=>r.arrayBuffer()).then(buf=>{
  const u8=new Uint8Array(buf); let bin=''; const c=0x8000;
  for(let i=0;i<u8.length;i+=c) bin+=String.fromCharCode.apply(null,u8.subarray(i,i+c));
  window.__b64=btoa(bin);
  window.__meta={size:u8.length, dims:[IM.naturalWidth, IM.naturalHeight]};
});
```

等几秒读 `window.__meta` 拿字节数/尺寸，再分块取回并解码：

```python
off, parts = 0, []
while True:
    chunk = js("(window.__b64||'').substr(%d,200000)" % off, target_id=TID)
    if not chunk:
        break
    parts.append(chunk); off += len(chunk)
    if len(chunk) < 200000:
        break
open(path, 'wb').write(base64.b64decode(''.join(parts)))
```

落盘后的字节数必须等于 `window.__meta.size`，不等就是没取全。

## 一维多图：缩略图点不动主图

一次生成多张时页面是「一张大图 + 右侧缩略图列」，**点缩略图不会切换主图**：
若每次都读「最大的那个 img」，会拿到 N 份同一张（表现为字节数全等）。

正确做法是取每个缩略图按钮**自己内部**的 img，再对它走上面的读字节流程：

```js
const btn=[...document.querySelectorAll('button,[role=button]')]
  .filter(b=>(b.getAttribute('aria-label')||'')==='显示生成的图像 N').pop();   // pop：历史消息里有同名按钮
const im=btn.querySelector('img') || btn.parentElement.querySelector('img');
```

取完用 sha256 逐张比对，确认是 N 张不同的图（长度相同也要比内容）。

两个会让「取回成功」却是错图的坑：

- **新一组可能根本没有缩略图列**（只生成 1–2 张时直接内联展示）。此时按
  `aria-label="显示生成的图像 N"` 过滤会命中**上一个消息里的旧组**，于是字节数与你上一批完全相同——
  看着成功，其实拿的是旧图。判据：新取的 sha256 与上一批任何一张相同 = 取错了。
- **懒加载**：未滚进可见区域的 `img`，`naturalWidth` 为 0，会被 `naturalWidth > 800` 这类过滤条件
  直接筛掉，于是「最新那张图不存在」。先 `window.scrollTo(0, document.body.scrollHeight)`，
  等几秒，再枚举。

稳的做法（不依赖有没有缩略图列）：枚举所有 `src` 含 `blob:` 的 `img`，按 DOM 顺序对 `src` 去重，
把**每一个**都读回本地、算 sha256，再用「已落盘的哈希集合」筛出真正的新图。
**不要用「取最后 N 个」代替这一步**：DOM 顺序不等于时间顺序——本机实测追加一轮后，
新图出现在枚举结果的**第 0 位**，而第 1–3 位反而是上一轮的旧图；按「最后 N 个」取会拿到旧图
还自以为成功。同一对话里追第二、第三轮出图时，**只认「哈希没见过」这一条判据**。

## 它自己产出的 PDF／文档（沙箱文件）怎么取回

网页端可以直接做成一份文件交给你（实测：把五张原图贴回去、要求"合成一份可直接发出的 PDF"，
它在沙箱里用 WeasyPrint 排出了 15 页：正文 A4 竖版 + 图片 A4 横版混排，图注贴图下）。
页面上的卡片会写「PDF · 15 页 · 约 5.5 MB」+ 一个「下载…」控件。

**那个「下载」控件不是 `<a>`，点它只会弹系统保存框**（自动化环境下不落盘）。
不要在这里死磕点击，改走这两步拿到**原文件字节**：

1. **点一下那个下载控件，同时开 `Network.enable`**，然后 `drain_events()`。
   链接是 JS 控件，用 DOM 找时按 `span.Pressable-*` + 文本匹配（`e.children.length<=2` 且
   `getBoundingClientRect().width>0`），别用 `textContent===` 全等（会命中隐藏模板，坐标是 `0,0`）。
2. 抓到的两个请求就是答案：
   - `GET /backend-api/conversation/<cid>/interpreter/download?download_intent=true&message_id=…&sandbox_path=…`
     （沙箱文件名在里面，**百分号被再编码过一次**：`%2FChatGPT_Hermes_%25E7%25A7%2591…`）
   - `GET /backend-api/estuary/content?id=file_…&fn=…&cd=attachment&ts=…&p=fs&cid=1&sig=…&v=0`
     ← **这条才是真文件**，`sig` 是签名，**缺任何参数都回 422**（只拿 `?id=…&fn=…` 实测 422）。

   ```python
   # 把完整 URL 丢回页面里 fetch（同源带 cookie），再 base64 分块读回（同图片那套）
   ```

3. 落盘后验真：开头是 `%PDF`、字节数与页面自报的一致、用 `pymupdf` 看页数与页面尺寸。

## 一次看清多张：拼联系表

核对多张图时不要一张张贴：写一个 HTML 网格（`<img src="file:///绝对路径.png">` 加标号），
用**无头浏览器**截成一张联系表，一次看完：

```bash
# macOS
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless --disable-gpu \
  --hide-scrollbars --user-data-dir=<临时目录> --window-size=1460,930 \
  --screenshot=<临时目录>/contact.png "file://<临时目录>/contact.html"
# Windows 把第一段换成 & "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
```
