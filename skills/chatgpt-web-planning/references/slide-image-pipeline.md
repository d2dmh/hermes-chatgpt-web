# 整页生图流水线：让 PPT 的每一页就是一张图（实测走通）

用户要"PPT 逐页生图、风格统一"（常见于科研/技术分享）时走这条线。它和"架构图三步法"同源
（**规划会话只写提示词 → 另一个新会话生图**），但节奏不同：这里要连续出十几张，还要保证视觉一致。

## 四步

1. **规划会话只写提示词，不生图**：把研讨稿/大纲放进工作区让它用连接器读，要求
   "一段一张、逐字可复制"，并让它**先给出统一视觉规范**（色号 + 字号层级 + 版式骨架 + 强调规则），
   之后每页提示词都复用它——这是 15 页视觉一致的关键。
   它还会主动把中文压成短标签（图像模型写不好长句）。
2. **另开一个全新对话逐页生图**：一次贴一条提示词，出一张取一张。**不要贴回规划会话**
   （否则它带着失败历史重新加工，又回到加戏的老路）。
3. **取回原图字节并验真**：跑 `scripts/verify_asset_origin.py`（真 PNG + C2PA `gpt-image` 出处）。
   取字节与去重的通用配方见 `media-export.md`；本流水线专用辅助函数见
   **`scripts/gen_helper.py`**（含取图、判完成、命名计数器）。
4. **组装并过目**：`python-pptx` 做 16:9 整页图 PPTX，`pymupdf` 做 PDF（页宽 1280×720），
   再拼一张**联系表用眼睛过一遍**——**必须看**，字节正确不等于版面正确。

## 四个必须知道的坑（都踩过）

- **别用"页面里 blob 图片数量"判完成**：长对话里页面会虚拟化，可见图片只有 4–6 张且来回波动。
  可靠判据是**"最后一张 blob 图的 src 变了"**（先记下 src，轮询直到变化）。
- **落盘命名用"已保存计数器"，不要用页码索引**：某一轮超时没取到，按索引命名就会整体错位
  （实测把第 8 页存成了 `p09.png`，之后全乱，只能靠看图认页码再改名）。
- **点输入框可能不聚焦**：`activeElement` 不是 contenteditable 时，逐字符真键会只进 DOM、
  不进 React——表现为**文字在、发送按钮不渲染**。改用 JS `focus()` + range 全选 + Backspace 清空，
  再逐字符真键，发送按钮随即出现（`gen_helper.type_and_send()` 就是这个顺序）。
- **`browser_exec` 大约 300 秒会被掐断**：把流程做成"**收上一页 → 发下一页 → 等新图出现**"的流水线，
  每轮一个循环；超时就下一轮补收（**已落盘的文件不会丢**）。

## 具体节奏（一次循环）

```
tid = G.fresh_tab()                    # 开一个确认是空白新对话的标签
prev = 当前最后一张 blob 图的 src        # 先记下来
...
while 还有页:
    G.grab_newest(tid, f'p{已保存计数:02d}.png')   # 收上一页（sha256 去重，重复=这轮还没出图）
    G.type_and_send(tid, 下一段提示词)
    G.wait_new_image(tid, prev)         # 等到"最后一张 blob 图的 src 变了"
    prev = 新的 src
```

每次 `browser_exec` 调用都要重新 import 并**显式注入** harness 的辅助函数：

```python
import sys; sys.path.insert(0, <skill 的 scripts 目录>)
import gen_helper as G
for n in ('new_tab','cdp','js','switch_tab','click_at_xy','wait_for_load'):
    setattr(G, n, globals()[n])      # harness 的辅助函数在调用方的 globals 里
```

落盘目录用环境变量 `PPT_PAGES_DIR` 指定（默认是系统临时目录下的 `ppt-pages`）。
