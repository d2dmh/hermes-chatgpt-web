"""hermes-chatgpt-web 的架构图：蓝白、扁平、可缩到 1200px 仍清楚。"""
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch
from pathlib import Path

NAVY, RED, LINE, LIGHT, INK, GREY = '#073DA5', '#DE1515', '#9CB3D3', '#EAF0FC', '#111722', '#6B7A90'
plt.rcParams.update({'font.sans-serif': ['PingFang SC', 'Hiragino Sans GB', 'Arial Unicode MS'],
                     'axes.unicode_minus': False})

OUT = Path(__file__).resolve().parent.parent / 'docs'
OUT.mkdir(exist_ok=True)
fig = plt.figure(figsize=(12, 6.4))
ax = fig.add_axes([0, 0, 1, 1])
ax.set_xlim(0, 120)
ax.set_ylim(0, 64)
ax.axis('off')


def box(x, y, w, h, fc='white', ec=NAVY, lw=1.6, r=1.4, ls='-'):
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle=f'round,pad=0.2,rounding_size={r}',
                                fc=fc, ec=ec, lw=lw, ls=ls, zorder=2))


def txt(x, y, s, size=12, color=INK, bold=False, ha='center', va='center'):
    ax.text(x, y, s, fontsize=size, color=color, fontweight='bold' if bold else 'normal',
            ha=ha, va=va, zorder=4, linespacing=1.5)


def arrow(p1, p2, color=NAVY, lw=2.0, ls='-', style='-|>', rad=0.0):
    ax.add_patch(FancyArrowPatch(p1, p2, arrowstyle=style, mutation_scale=16, color=color,
                                 lw=lw, ls=ls, zorder=3, connectionstyle=f'arc3,rad={rad}'))


# ---------------- 左：你的电脑
box(2, 6, 38, 52, fc='white')
txt(21, 55, '你的电脑', 15, NAVY, True)
box(5, 40, 32, 11, fc=LIGHT)
txt(21, 47.5, '工作区文件', 12.5, NAVY, True)
txt(21, 43.5, '代码 · 文档 · 数据 · 图', 10.5, INK)
box(5, 25, 32, 11, fc=LIGHT)
txt(21, 32.5, 'Hermes（你的 agent）', 12.5, NAVY, True)
txt(21, 28.5, '执行 · 取回 · 核验', 10.5, INK)
box(5, 10, 32, 11, fc=LIGHT)
txt(21, 17.5, 'Chrome（CDP）', 12.5, NAVY, True)
txt(21, 13.5, '开对话 · 打字 · 读回复', 10.5, INK)

# ---------------- 中：桥 + 隧道
box(46, 24, 26, 30, fc='white')
txt(59, 49.5, 'c2c 桥', 14, NAVY, True)
txt(59, 45.5, '只读 MCP 服务', 11, INK)
txt(59, 38.5, '127.0.0.1:xxxx', 11, GREY)
ax.plot([50, 68], [34.5, 34.5], color=LINE, lw=1.2, ls=':')
txt(59, 30.5, 'cloudflared 隧道', 11.5, NAVY, True)
txt(59, 27, 'https://…trycloudflare.com', 9.5, GREY)

# ---------------- 右：ChatGPT
box(80, 14, 37, 46, fc=LIGHT)
txt(98.5, 55, '网页版 ChatGPT', 15, NAVY, True)
txt(98.5, 50.5, '出方案 · 独立审查 · 出图', 11, INK)
for i, (t, s) in enumerate([('读工作区', 'workspace_info / read_file'),
                           ('给方案', 'PLAN'),
                           ('挑毛病', 'REVIEW'),
                           ('出图', 'gpt-image')]):
    y = 44 - i * 7.6
    ax.add_patch(FancyBboxPatch((83, y - 2.2), 6.5, 4.4, boxstyle='round,pad=0.15,rounding_size=0.8',
                                fc='white', ec=LINE, lw=1.2, zorder=3))
    txt(86.2, y, str(i + 1), 11, NAVY, True)
    txt(92.5, y + 0.7, t, 11, NAVY, True, ha='left')
    txt(92.5, y - 1.3, s, 9, GREY, ha='left')

# ---------------- 箭头
arrow((44.3, 42), (48.4, 42), color=NAVY, ls='--')
txt(46.3, 44.6, '只读', 9, GREY)

arrow((73, 42), (79, 42), color=NAVY)
txt(76, 44.4, '隧道', 9, GREY)

arrow((79, 32), (73, 32), color=RED)
txt(76, 29.4, 'OAuth 授权', 9, RED)

# Hermes 与 Chrome：本机操作
arrow((37.5, 30), (37.5, 21), color=GREY, lw=1.6, style='<|-|>')
txt(39.6, 25.5, 'CDP', 9.5, GREY, ha='left')
# Hermes 与工作区
arrow((37.5, 40), (37.5, 31), color=GREY, lw=1.6, style='<|-|>')
txt(39.6, 35.5, '读写', 9.5, GREY, ha='left')

txt(60, 4.5, '没有人粘贴代码或日志：它自己按需读你工作区里的那几个文件', 12.5, RED, True)
fig.savefig(OUT / 'arch.png', dpi=180, bbox_inches='tight', pad_inches=0.2)
plt.close(fig)
print('arch.png ok', (OUT / 'arch.png').stat().st_size // 1024, 'KB')
