# AG-godot — 用纯 GDScript 把 MMD 模型搬进 Godot 4.7

不依赖任何第三方导入插件，从零解析 MMD 的 `.pmx` 模型与 `.vmd` 动作文件，
在 Godot 4.7 里还原骨骼动画（含 IK、付与親）、表情变形与 MMD 风格卡通渲染。

> 目标不是"做个能跑的 demo"，而是**把 MMD 的每一条约定亲手实现一遍并搞懂它为什么这么定**。
> 因此仓库里同时保留了完整的排查方法论文档（见 [`docs/`](docs/)）。

---

## 这个项目做了什么

| 能力 | 说明 |
|---|---|
| PMX 模型解析 | 纯 GDScript 读二进制：顶点、面、材质、骨骼、IK、变形（morph）、刚体 |
| VMD 动作解析 | 骨骼关键帧 + 表情关键帧，含贝塞尔插值 |
| Shift-JIS 解码 | Godot 没有内置 Shift-JIS，MMD 的日文骨骼名靠自建码表还原（`sjis_map.gd`） |
| 骨骼动画 | 自维护世界变换数组，实现 CCD 式 **IK 解算**、**付与親**（append parent）继承 |
| 表情变形 | 顶点 morph（`ArrayMesh` blend shape） |
| 卡通渲染 | toon 色阶、sphere 高光、边缘光、自发光、**描边**（next_pass 反向外扩） |
| 图层栈调试 | Inspector 里实时开关/重排渲染图层，画面立即变化，无需重启（`mmd_layers.gd`） |
| 自定义景深 | Godot 4.7 移除了 `Environment.dof_blur_far_*`，这里用 `CompositorEffect` 自己写了散景 DOF |

---

## 快速开始

**需要 Godot 4.7+**（开发环境为 `4.7.1-stable`）。

```bash
git clone https://github.com/PandaDecSt/AG-godot.git
```

用 Godot 打开项目根目录，直接 **F5** 运行。

主场景是 `main.tscn`，运行时由 `mmd_importer.gd` 完成：
`PMXLoader 解析 → MMDModelBuilder 构建骨架+网格+材质 → 挂进场景 → 自动取景 → 逐帧喂光照方向`。

模型与动作路径写在 `mmd_importer.gd` 顶部常量：

```gdscript
const PMX_PATH := "res://models/model.pmx"
const VMD_PATH := "res://models/motions.vmd"
```

> **坑提醒**：`models/` 下另有一个 `motion.vmd`（无 s），那是给**别的模型**做的纯表情文件，
> 骨骼名只命中 22/191，用它会看起来"动作没生效"。要用的是 `motions.vmd`。

---

## 项目结构

### 核心管线

| 文件 | 职责 |
|---|---|
| `pmx_loader.gd` | 解析 `.pmx` 二进制 → 纯数据字典（顶点/材质/骨骼/IK/morph） |
| `vmd_loader.gd` | 解析 `.vmd` 二进制 → 骨骼轨道与表情轨道 |
| `sjis_map.gd` | Shift-JIS → Unicode 码表，供 VMD/PMX 日文名解码 |
| `mmd_builder.gd` | 由数据构建 `Skeleton3D` + `ArrayMesh` + 材质（**rest 姿势在此计算**） |
| `mmd_importer.gd` | 总编排：加载、挂场景、取景相机、每帧喂视线空间光照方向 |
| `vmd_player.gd` | 动画播放核心：采样关键帧 → 付与親 → IK 解算 → 写回骨骼 pose |

### 渲染

| 文件 | 职责 |
|---|---|
| `mmd_material.gdshader` | MMD 主材质（toon / sphere / 边缘光 / 自发光，支持图层掩码与排序） |
| `mmd_material_transparent.gdshader` | 半透明材质变体 |
| `mmd_outline.gdshader` | 描边（反向法线外扩） |
| `mmd_layers.gd` | 图层栈控制面板，把 Inspector 参数每帧写进材质 uniform |
| `dof_compositor.gd` | 自定义散景景深（`CompositorEffect`，RD 级后处理） |
| `free_camera.gd` | 自由观察相机 |

### 诊断脚本（无显卡也能跑，见下节）

| 文件 | 用途 |
|---|---|
| `dump.gd` | 导出全部骨骼的 rest/IK/付与親 数据到 JSON，供离线复算 |
| `verify.gd` | 用**真实** builder + player 跑若干帧，导出世界坐标供断言 |
| `pose_test.gd` | 最小骨架实验，验证 Godot `set_bone_pose*` 的语义 |
| `diag_rdsrc.gd` | 探测 `RDShaderSource` 的实际属性名（写 DOF 时用） |

---

## 没有显卡也能验证

这个项目最有价值的部分之一：**不渲染也能确认动画数学对不对**。

Godot 的 **console 版**可执行文件支持纯 CPU 跑脚本，不开图形设备：

```bash
# 注意 Windows 下 --path 必须用反斜杠，正斜杠会被判为 "Invalid project path"
Godot_v4.7.1-stable_win64_console.exe --headless \
  --path "D:\path\to\AG-godot" --script "res://dump.gd"
```

脚本把骨骼数据写成 JSON，再用 Python 独立复算一遍，比对运行时结果。
这样能在**几秒内**完成一轮"改代码 → 验证"，而不是每次都启动编辑器肉眼看画面。

具体流程、可断言的不变量清单、以及一个"把人拉成面条"的真实 bug 全过程复盘，见：

- 📘 [`docs/01-入门-MMD模型是怎么被搬进Godot的.md`](docs/01-入门-MMD模型是怎么被搬进Godot的.md)
  — 给零前置认知的读者：数据怎么流动、术语用生活比喻讲、每个脚本管什么
- 🔍 [`docs/02-排查方法论-骨骼变形与动画Bug定位.md`](docs/02-排查方法论-骨骼变形与动画Bug定位.md)
  — 七步通用排查流程、七条不变量、"症状 → 先查哪里"对照表

---

## 三条不能破的约定

踩过的坑里最关键的三条，改代码前务必知道：

**1. PMX 的 `bone.position` 是模型空间【绝对坐标】，不是相对父骨的偏移。**

```gdscript
global_rest[i] = global_rest[parent] * T(pos)   # ❌ 双重累加 → 骨头飞出几百单位，人变面条
global_rest[i] = T(pos)                          # ✅ 绝对坐标直接用
```

局部 rest 再由 `父全局逆 × 自身全局` 求得。这个 bug 曾把手指骨推到 y≈252、
而整个模型只有 22 单位高，表现为"四肢和脖子拉成面条、IK 永远不收敛"。

**2. Godot 的 `set_bone_pose_*` 写的是【绝对局部变换】，会替换 rest，不是叠加在 rest 上。**

所以初始化时必须把 pose 显式设成 rest，否则静止姿势就是错的。
（此结论由 `pose_test.gd` 实测确认，不是猜的。）

**3. `FLIP_Z` 必须整套一起翻。**

MMD 是左手坐标系、Godot 是右手系。顶点、法线、骨骼 rest、morph 偏移、
VMD 的位移与旋转**全都要**做镜像共轭。只翻一部分的话——静止时看不出问题
（bind 与 pose 互相抵消），但骨头一转，肢体就朝 Z 反方向弯，整套动作镜像。

---

## 素材与版权 ⚠️

`models/` 目录下的 MMD 模型（`model.pmx`）、动作（`*.vmd`）与贴图（`textures/`）
**均为第三方作品，版权归各自原作者所有**，本仓库不主张任何权利。

这些文件仅为便于复现与调试而随仓库存放。请注意：

- 多数 MMD 模型与动作的使用条款**限制或禁止再分发、商用、改造**；
- 若你是素材作者且不希望它出现在此处，请提 issue，我会立即移除；
- 使用者有责任自行确认所用素材的许可条款。

本仓库**自行编写的代码**（`*.gd`、`*.gdshader`、`docs/`）可自由参考学习。

`addons/godot_mcp/` 为开发期使用的编辑器辅助插件。

---

## 状态

进行中的学习性项目。当前已跑通：模型导入 → 卡通渲染 → 完整舞蹈动作播放（含 IK 与表情）。
