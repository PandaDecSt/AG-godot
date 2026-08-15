# 进阶篇：把 reze 的"角色渲染预设"搬进了 Godot

> 读者：已经能跑起模型、想搞懂"为什么不同部位颜色/边缘光不一样、怎么一键换整体风格"。
> 目标：看完能说清"预设分三层、数据从哪抄来的、怎么在界面上实时切换"。

---

## 一、这件事在解决什么？

**一句话**：reze 那边给每种材质（皮肤、头发、眼睛、布料……）都配好了"专属化妆方案"，我们这边也要有。

**打个比方**：
- 一个 MMD 人物 = 一个**演员**
- 皮肤、头发、眼睛、衣服、丝袜 = 演员身上**不同部位**
- reze 的预设 = 给每个部位定制好的**妆容卡**（粉底多厚、口红什么色、打光角度）
- 我们以前：所有人**统一一张脸**（只有 PMX 自带的 toon 贴图）
- 现在：按部位自动套**专属妆容卡**，还可以一键换"整体滤镜"

数据**全部忠实抄自 reze**（不瞎编数值），来源见第四节。

---

## 二、预设分三层（像"底妆 + 整体滤镜 + 调色"）

| 层 | 名字 | 管什么 | 生活比喻 | 代码入口 |
|---|---|---|---|---|
| **第 1 层** | 角色预设（per-role） | 每个材质的 toon 色阶、饱和度、边缘光、自发光 | 给**鼻子、嘴唇**各自打不同粉底 | `material_presets.gd` 的 `AG` / `WUWA` 表 |
| **第 2 层** | Look Pack（整体风格） | 全局曝光、色调映射模式、世界色染色 | 整个片场的**灯光 + 滤镜**（AG 紫调 / WuWa 冷白） | `LOOK` 表 |
| **第 3 层** | Color Grade（调色） | 全局对比度、饱和度、暗部/亮部分色调 | 后期**加一层调色**（血色/赛博/神性……） | `GRADES` 表 |

三层的执行顺序：**先按部位化妆（第 1 层）→ 再罩整体滤镜（第 2、3 层）**。
第 2、3 层作用在**所有材质**上（逐材质写入 uniform），第 1 层只作用在**命中的材质**上。

---

## 三、自动分类：材质名 → 角色

每个 PMX 材质都有名字（如 `skin`、`hair_F`、`stocking`、`瞳1`）。
`material_presets.gd` 里的 `classify_role()` 用**子串匹配**把它归到 9 种角色之一：

```
body / face / hair / eye / cloth_smooth / cloth_rough / stockings / metal / accent
```

匹配不到 → 返回 `"default"`，此时**保留 PMX 自带的 toon 贴图、不动它**（不会崩，只是没套我们的妆）。

> ⚠️ 子串坑：本机 Godot 的 `String.contains()` 在某些情况下行为异常（例如 `"stocking".contains("sock")` 竟返回 `false`）。
> 代码统一改用 `_has(n, sub)`（内部 `n.find(sub) >= 0`）绕开，更稳妥。
> 注意 `"stocking"` 里**本来就不含** `"sock"`（它是 s-t-o-c-k-i-n-g），所以专门加了 `"stock"` 子串才兜住。

本模型真实材质分类结果（已无 `default` 漏网）：

| 材质名 | 命中角色 |
|---|---|
| skin / 齿 / 舌 / 唇 / skin_cloth / skin_metal | body |
| face01 / 口腔 | face |
| hair_F | hair |
| 瞳1 / 瞳2 / 目白 / eyebrow / eyelash | eye |
| cloth01 / cloth_naive / cloth01_alpha / cloth_metal | cloth_smooth |
| metal / stocking_metal | metal |
| stocking / stocking_metal | stockings |
| gem | accent |

---

## 四、数据从哪来（忠实，不臆造）

reze 原工程在 `D:\MySpace\workshop\Agame\reze\reze-design\`：

| 我们的字段 | reze 来源文件 | 说明 |
|---|---|---|
| `AG` / `WUWA` 各角色 toon 色阶 | `content/graphs.json` | AG 用 `ramp_cardinal` 的 color0/color1 + 白；WuWa 直接取 `ramp_linear_3` 的彩色三段 |
| `AG` / `WUWA` 的 saturation/value/rim/emission | `content/` 各节点图 | 灰度角色（body/hair/metal/cloth）的 ramp 是黑→白，故色阶走中性灰 |
| `LOOK`（ag/wuwa） | `lib/materials.ts` + `lib/scene-settings.ts` | AG = filmic @ exposure 0.6(EV) world #ed6aff；WuWa = standard @ exposure 0 world #fdf2f8 |
| `GRADES`（6 套） | `content/grades.json` | Neutral/Bloody/Cyberpunk/Divine/Moonlit/Sakura 的对比/饱和/暗亮部色轮 |

**几个关键换算（代码里已固化，别手改）**：
- `exposure` 在 reze 里是 **EV（曝光值）**，含义是乘子 `2^EV`：AG `0.6 → 1.5157`，WuWa `0 → 1.0`。
- `world` 颜色：`mix(白, world_hex, strength)`，strength 越大越偏世界色（染遍所有表面）。
- grade 的暗部/亮部是 `[h°, s, v]` 色轮，转成 RGB 后**按亮度做分色调**（暗部染 shadow_tint、亮部染 highlight_tint），强度系数 `GRADE_TINT_SCALE = 0.6` 防过艳。
- Sakura 的色轮**只有 [h, s] 缺 v** → 代码里 `v` 默认 `0.5`。

---

## 五、着色器里多了哪些旋钮

`shaders/mmd_material.gdshader` 与 `mmd_material_transparent.gdshader` 各加了 7 个 uniform：

```
mat_saturation  mat_value  sphere_strength  world_color
tonemap_mode  grade_shadow_tint  grade_highlight_tint
```
（外加已有的 `exposure` / `saturation` / `contrast` / `rim_*` / `emission_strength` / `toon_tex`）

`light()` 末尾的管线：**hdr = color × exposure → filmic/standard 色调映射 → gradeColor(饱和/对比) → 分色调染色 → DIFFUSE_LIGHT**。
toon 贴图从**灰度 .r** 升级成**彩色 .rgb 三段色阶**（由 `bake_ramp()` 按角色烘焙成 128×1 贴图并缓存）。

---

## 六、怎么在界面上实时切换（HUD）

运行（F5）后，左下角播放面板旁边多了一个**预设面板**（CanvasLayer）：
- **Look 下拉**：`ag` / `wuwa` —— 切整体滤镜
- **Grade 下拉**：`Neutral / Bloody / Cyberpunk / Divine / Moonlit / Sakura` —— 切调色

选完立刻套用到所有材质。代码在 `mmd_importer.gd` 的 `_add_preset_hud()`，实际调用 `_mp_presets.apply_look(_mats, pack, grade)`。

> 第 1 层（角色妆容）是**建模时自动套**的（`mmd_builder._build_material` 里 `classify_role` + `apply_role`），不进 HUD。

---

## 七、想加东西？照着改这三张表

| 想做 | 改哪里 | 怎么改 |
|---|---|---|
| 新增一个角色妆（如"普通衣服"vs"粗糙布料"） | `AG` / `WUWA` 字典 | 加一个 key，填 toon 三段色 + 各 uniform |
| 让某材质名归到别的角色 | `classify_role()` | 在对应分支的 `_has(n, "关键词")` 里加子串（用中文/英文/假名都行） |
| 新增一套整体滤镜 | `LOOK` 表 | 填 `tonemap_mode`(0=standard/1=filmic)、`exposure`(EV)、`world_hex`、`world_strength` |
| 新增一套调色 | `GRADES` 表 | 填 `contrast`/`saturation` + `shadow`/`high` 的 `[h°,s,v]` 色轮（缺 v 默认 0.5） |

改完用无头脚本验证（不需开 GPU）：
```
"<Godot_console.exe>" --headless --path "D:\MySpace\workshop\GodotPros\AfterGlowGodot" --script "res://src/diag/preset_test.gd"
```
它会驱动 `apply_role` + `apply_look` + `bake_ramp` 并打印读回的 uniform 值，确认没接错旋钮。

---

## 八、无头验证清单（本次已跑过，全绿）

- `preset_test.gd`：apply_role(hair) 拿到 Texture2D 色阶、mat_saturation=1.4；apply_role(default) 只设中性值；apply_look(wuwa/Bloody) 拿到 exposure=1.0 / tonemap_mode=0 / 分色调 RGB；bake_ramp 缓存命中。
- `verify.gd`（真实建模）：所有材质 `MATPRESET ... -> role=... pack=ag` 无 `default` 漏网，无 SCRIPT ERROR（仅 dummy 渲染器正常的 RID 泄漏警告，可忽略）。
- 分类对照：`.test/ag_vmdtest/cltest.txt`（已修正 `stocking→stockings`）。
