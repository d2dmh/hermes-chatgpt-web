# 往网页 ChatGPT 输入框里传文件（CDP，实测可用）

要让网页端**看到**图/文件（审查成品、读材料），必须真的把它挂进输入框。
ChatGPT 的输入框与文件输入都被前端框架接管，常规程序化赋值不生效。
下面是验过的那一条路，macOS 与 Windows 只有「怎么把文件放进剪贴板」这一步不同。

## 试过但不生效的做法（别再重复）

- CDP `DOM.setFileInputFiles`：调用不报错，但 `input.files.length` 始终为 0。
- Playwright `set_input_files`：同上，写不进去。
- 用 `osascript` 走 System Events 发按键：本机没有辅助功能权限，报"不允许发送按键"。
- 把**图片数据**放进剪贴板（`... as «class PNGf»`）再粘贴：输入框不认。
- 多文件列表（剪贴板里放若干个 `POSIX file`）粘贴：不生效。

## 可用的做法：文件引用进剪贴板 + CDP 编辑命令 paste

**第 1 步：把文件本身（不是文件内容/图片数据）放进剪贴板。**

macOS——放进去的是文件引用（`furl`）：

```bash
osascript -e 'set the clipboard to (POSIX file "/abs/path/to.png")'
osascript -e 'clipboard info' | head -1     # 期望看到 «class furl»
```

Windows——用系统自带的 **Windows PowerShell 5.1** 的 `Set-Clipboard -Path`（放进去的是文件拖放列表，
和资源管理器里复制文件等价；**PowerShell 7 已去掉 `-Path`，所以要调 `powershell.exe` 而不是 `pwsh`**）：

```powershell
powershell.exe -NoProfile -Command "Set-Clipboard -Path 'C:\abs\path\to.png'"
```

> Windows 这一步**没有在真机上验证过**（本项目在 macOS 上开发）。判据是第 3 步的校验：
> 只要附件的「移除"<文件名>"」按钮出现，就说明挂上了；没出现就按下面「若这条路仍不通」处置。

**第 2 步：在已接管的标签页里点真实输入框坐标，再用 CDP 发粘贴编辑命令（不是模拟物理按键）。**

```python
for t in ('rawKeyDown', 'keyUp'):
    cdp('Input.dispatchKeyEvent', type=t, modifiers=4, key='v', code='KeyV',
        windowsVirtualKeyCode=86, nativeVirtualKeyCode=9, commands=['paste'],
        target_id=TID)
```

**第 3 步：校验。** 附件名会出现在「移除"<文件名>"」这类按钮的 `aria-label` 上：

```python
js("""(() => [...document.querySelectorAll('button')]
     .map(b=>b.getAttribute('aria-label')||'').filter(x=>/^移除/.test(x)))()""", target_id=TID)
```

## 四个必守细节（每个都踩过）

- **CDP 调用必须带 `target_id`。** 不带时既不报错也不生效——最难查的一种失败，同一段代码带上就成功了。
- **设剪贴板与粘贴必须串行。** 同一轮里既改剪贴板又发粘贴会互相冲掉，之后 `clipboard info` 读出来是空的。
- **一次只放一个文件。** 逐个"放一个 → 粘一次"才稳。即便如此也要克制：一次发一大把会被附件上限截断
  并产生重复挂载，用户看到的是"又一次性传了一大堆"。多页材料先本地拼成**一张联系表**再发
  （拼法见 `media-export.md`）。
- **新对话要在已接管的那个标签页里开**（页面内点「新聊天」），不要新起标签页：
  新标签页收不到 CDP 事件，粘贴会静默失败。

## 粘贴成功 ≠ 可以发送：上传是异步的

粘贴后附件只是进了输入框，字节**还在后台上传**；这期间「发送」按钮是**灰的**（`disabled: true`）。
必须轮询到它能点再发，否则点了没反应、看起来像"发送失败"：

```python
js("""(() => { const b=[...document.querySelectorAll('button')]
     .find(e=>e.getAttribute('aria-label')==='发送'); return b.disabled; })()""", target_id=TID)
```

上传链路（抓 `Network.enable` + `drain_events()` 可见）：

1. `POST https://chatgpt.com/backend-api/files` → 拿上传地址（期望 200）
2. `OPTIONS` + `PUT https://<region>.oaiusercontent.com/files/<id>/raw?...` → **真正的字节上传**

一次卡住数十秒的情形见过：`PUT` 与预检都只见
`Network.loadingFailed … net::ERR_ABORTED canceled: true`、没有任何 response → 传输被中断
（用户侧当天是网络波动）。处理：**等一会再重贴/重发**，不要改代码、不要换方法。
区分"域名被封"与"临时中断"：在页面里跑
`fetch('https://<region>.oaiusercontent.com/', {mode:'no-cors'})`，返回 `opaque` 说明域名可达。

**校验真的读到了**：让它把文件里一段随机 token 原样复述。用
`[...document.querySelectorAll('*')].filter(e=>e.children.length===0 && e.textContent.includes(TOKEN))`
找所在元素；父级 class 含 **`DilResponseRoot`** 说明出现在**模型回复正文**（可信），
若只在附件卡片里则是预览省略显示（如 `HERMES...ADE9`），不算证据。

**输入框位置分两种**：新对话在屏幕中部；**已有对话里在页面最底部**。
拿 `div[contenteditable=true]` 的 `getBoundingClientRect()` 现测，别照抄旧坐标。

## 清理已挂上的附件

找 `aria-label` 以「移除」开头的按钮（每个附件一个，宽约 16px）循环点掉，直到这类按钮数为 0，
再用 `img[src^="blob:"]` 计数确认输入框干净。

## 若这条路仍不通

不要把交付卡在这里。把成品与预览图拷到用户好找的位置（如 `~/Downloads/hermes-inbox/`，
Windows 为 `%USERPROFILE%\Downloads\hermes-inbox\`）交给用户自己转发，
并在回复里说明卡在哪一步、下一步怎么走。
