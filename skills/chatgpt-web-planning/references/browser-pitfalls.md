# 浏览器操作要点：把网页 ChatGPT 当成一个"真人在用"的页面

> 这里每条都是**实际踩过并付了代价**的。动手操作页面前通读一遍；
> 遇到"看起来卡住/没反应/发不出去"的现象，先来这张表里对号。

## 通道与超时

- **`browser_exec` 的 IPC 默认只等 5 秒**：ChatGPT 这类重页面/导航会报
  `timed out after 5s waiting for the daemon`，看着像页面卡死，其实只是超时。
  解：`Target.attachToTarget(targetId=…, flatten=True)` 拿到 `sessionId`，再用
  `cdp("Runtime.evaluate", session_id=sid, expression=…, returnByValue=True, _response_timeout=40)`
  —— **参数名是 `_response_timeout`**（写 `response_timeout` 会被当成 CDP 参数丢掉，无效）。
- **先分清"页面卡死"还是"通道超时"**：先 `js("1+1")`；轻页面（`about:blank` / data URL）正常
  而目标页 evaluate 超时 → 页面没加载完，**第一嫌疑是代理没开**（本机实测：代理关着时
  chatgpt.com 停在 `ERR_CONNECTION_TIMED_OUT`，其它一切正常）。
- **`cdp("Runtime.evaluate", …)` 的返回值先看有没有 `value`**：表达式抛异常时只回
  `exceptionDetails`，直接取 `["result"]["value"]` 会 `KeyError`；同一表达式有时回字符串、
  有时已被解析成 Python 对象，`json.loads()` 前先判类型。
- 点击/重渲染后元素会换实例，取不到就重新查一次，不要以为是页面坏了。

## 多标签与"谁在前台"

- 协作浏览器是**用户可见的窗口**。用户点击/切标签会改变 harness 的"当前页"，
  agent 的键盘/鼠标会跑到用户的页面上。
  **动手前先 `switch_tab(target_id, activate=True)`** 把自己的标签切到前台；
  读数据用 `js(expr, target_id=…)` 锁定自己的标签。
- 只用 `activate=False` 时按键会落到用户正在看的页面——最难查的一类"没反应"。
- **新对话要在已接管的那个标签页里开**（页面内点「新聊天」），不要另起标签页：
  新标签页收不到 CDP 事件，粘贴/按键会静默失败。

## 输入框（ProseMirror 的两个致命坑）

- ChatGPT 的输入框是 ProseMirror：`document.execCommand('insertText')`、CDP `Input.insertText`
  以及 `type_text` 都可能只进 DOM、不进 React state（输入框看着还是空的、发送按钮不出现、
  Enter 无效、消息发不出去）。**实测稳定的输入法是「真实点击 + 逐字符真键事件」**：
  1. `switch_tab(target_id, activate=True)`
  2. `click_at_xy(输入框的 CSS 像素中心)`
  3. 确认 `document.activeElement` 就是那个 `div[contenteditable]`（不是就再点一次）
  4. attach 出 `sessionId`，对每个字符发一次
     `cdp("Input.dispatchKeyEvent", session_id=sid, type="keyDown", text=ch, unmodifiedText=ch)`
     加一次 `type="keyUp"`（**中英文都走这条**，别退回 `insertText`）
- **必须用 `form div[contenteditable="true"]` 精确定位**，绝不用 `div[contenteditable]`：
  长会话里**每段提示词／写作块自己也是 `contenteditable`**，
  `querySelector('div[contenteditable]')` 会命中页面里第一个可编辑块（往往是历史消息里的提示词块）。
  后果很隐蔽：话全打进那段旧提示词里，真 composer 一直空着——发送按钮不渲染、`Enter` 只换行、
  没有报错，而 `innerText.length` 看着还"对"（实测踩过：整整 560 字打进旧提示词，白烧十几分钟）。
  自证两句：`document.querySelectorAll('form div[contenteditable="true"]').length === 1`，
  且点击后 `document.activeElement.closest('form')` 非空。
- **空态新对话页**里这个选择器会返回 2 个：第一个是隐藏模板（`getBoundingClientRect()` 宽高为 0、
  `innerText` 恒为空），可见的那个才是 composer。**按可见性过滤再取坐标/读文本**。
- **输入框坐标每轮现测**，不要复用上一轮的：会话越长 composer 越往下走。
  坐标一律取 `getBoundingClientRect()` 的 **CSS 像素**（截图像素 = CSS 像素 × `devicePixelRatio`）。
- **点发送前先验证文本真的进去了**：读可见 `div[contenteditable]` 的 `innerText`，长度对了才点发送；
  空串或只剩一个 `\n` 就是按键没落地，硬点会发出一条空消息。
- 打完字那一刻「发送」按钮可能还是 `disabled`（按 `aria-label` 过滤会返回空列表）：等 1–2 秒再查一次，
  别当成页面坏了，也别改用 JS 强点。
- **发送后别拿「你说：」计数当唯一判据**：长会话里它不一定立刻 +1（实测消息真发出去了、
  输入框已清空，计数还是旧值，差点重发一条）。可靠判据是
  「`div[contenteditable].innerText` 被清空」＋「消息原文出现在 `document.body.innerText` 里」。

## 等回复

- **不要 hold 一个长浏览器等待**：发完消息后每 20–30 秒做一次**廉价 DOM 检查**即可：
  - 还在生成 → 继续等（**不要打字、不要重发**）；
  - 出现结论（`STATE: PLAN/DONE/BLOCKED`、或你要的那个值）→ 读下来继续；
  - 出现可见错误 → 修，不要新开对话。
- **浏览器/js 超时不是失败**：认领同一个标签、读页面、保持在线。想重发之前先确认原消息是否已发出。
- **长回复是分段流式写的**：某一段长度几分钟不变，很可能它在用连接器读文件，**别当卡死重发**。
  完成判据用"最后一段长度稳定 + 页面出现『回答已完成』"，不要只看"你说："计数（会滞后）。
- 长对话页面会渲染错乱（新消息插进旧回复里、长文本被拆到别处）：**刷新页面**即可恢复
  （服务端消息本身不丢）。刷新后输入框会恢复草稿，先全选删除再输入。

## 连接器设置页（Radix 组件 + 视口坑）

- 插件页的「添加」是 **Radix 菜单**：合成鼠标点不开时，`focus()` 该按钮后发 **Enter** 能打开；
  菜单项用 `[role=menuitem]` 定位（要的是「添加自定义 MCP 服务器」）。
- 「添加自定义 MCP 服务器」**对话框比视口高**：`创建为插件` 按钮贴底（本机落在 y≈778，视口高 783），
  直接点没反应且对话框不关；先 `scrollIntoView({block:'end'})` 再点。
  提交后**等 5–10 秒**（服务端会去探 MCP 端点），别急着重试。
- 新建的自定义连接器出现在插件页 **「个人」分类**；提交成功后立刻弹「连接 …」向导 →
  点「继续连接到 …」进到隧道域名下的 OAuth 授权页（此时才 `c2c pair`，5 分钟用掉）。
- **删除连接器的弹窗有坑**：点「删除应用」后如果**又点了一次页面上的同一坐标**，
  会点在遮罩上把弹窗关掉（看着像删除失败）。正确顺序：点页面按钮 → 等 2–3 秒确认弹窗文案出现
  → 再点**弹窗里**那个按钮 → 等 6–9 秒（删除有延迟）。
- **OAuth 授权页只能提交一次**：必须真实点击输入框 + 逐字符真键输入配对码 + 真实点击 Connect。
  用 JS 直接写 `input.value` 再提交会把这个一次性请求消耗掉却不带配对码，同页重试只会看到
  `authorization request has expired`。
- **「继续连接」入口只在刚创建连接器的那一刻出现**。错过授权窗口后，详情页只剩
  「管理 / 在聊天中试用 / ⋯」，**没有任何重新授权入口**——唯一出路是删除该连接器并重建
  （同名前缀、新地址、新配对码）后再走一次授权。

## 附件与素材

- 往输入框塞图片：**一次只发一张联系表**，不要逐页堆。多页审查（如 8 页 PPT）先本地拼成
  一张网格联系表再发——一次性挂多张会被附件上限截断并产生重复挂载。
- 挂文件的可靠配方、以及"粘贴成功 ≠ 可以发送（字节还在后台上传，发送按钮是灰的）"的判据，
  见 `uploading-files-to-web-chatgpt.md`。
- **绝不为了传素材把交付一直往后拖**：这一环最多两轮，仍不成就把成品与预览图放到用户好找的目录
  交给他自己转发，并说明卡在哪一步。审查是加分项，成品交付不依赖它。**先交付，再补审查。**
- 清理已挂上的附件：找 `aria-label` 以「移除」开头的按钮（每个附件一个，宽度约 16px）循环点掉，
  直到这类按钮数为 0，再用 `img[src^="blob:"]` 计数确认输入框干净。

## 网络与 DNS（中国网络环境常见）

- 本机 DNS 对 `chatgpt.com` 被污染（解析出假 IP）→ Hermes 的 SSRF 预检会误拦并报
  `Blocked: URL targets a private or internal address`。已在配置里放开；
  若进程内仍是旧配置，用不含绝对 URL 字面量的方式导航（相对路径，或把 URL 写在文件里再读）。
- 系统代理与 shell 环境变量是两套：`curl` / `git` / `pip` 只认 `https_proxy` 等环境变量，
  **不认 macOS 系统代理**。代理开着而命令超时，先查环境变量。
- 访问本地模型/本地端点要 `NO_PROXY=127.0.0.1,localhost,::1`，否则请求被代理劫走而卡死。
