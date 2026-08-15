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

---

## 九、逐部位实时编辑（HUD，对齐 reze「改每个部位的着色器预设」）

reze 的 `graph-editor` 能单独调每个部位节点图的参数（色阶/饱和度/边缘光…）并随场景生效。
我们这边用**运行时 HUD**实现同一能力（F5 后右上角「逐部位预设编辑」面板）：

1. **选部位**：下拉选 `body / face / hair / eye / cloth_smooth / cloth_rough / stockings / metal / accent`（只列出本模型实际存在的）。
2. **调参数**，实时套用到该部位全部材质：
   - 色阶三段取色器（暗端 / 中间 / 亮端）—— 对应 reze `ramp_cardinal` 的 color0/color1 + 白，驱动 `toon_tex` 重新烘焙；
   - 6 个滑块：饱和度 / 明度 / 边缘光强度 / 边缘光锐度 / 球面贴图强度 / 自发光；
   - 边缘光颜色取色器。
3. **「还原 reze 默认」**按钮：清掉该部位的运行期覆盖，回到 `AG`/`WUWA` 表里抄来的原值。

**机制**（数据全在 `material_presets.gd`）：
- `mmd_builder` 建材质时把角色写进 `mat.set_meta("mp_role", role)`；
- `mmd_importer._build_role_mats()` 按 meta 把 `_mats` 分组成 `role → [材质...]`；
- 改一个滑块 = `set_role_override(pack, role, key, v)` → `apply_role(每块该部位材质)` 即时重设 uniform；
- 覆盖存在内存 `_overrides["pack:role"]`，**不落盘**（关场景即丢），与 reze「随场景可改不可持久」一致；
- 切 Look pack（AG↔WuWa）时 `_apply_preset` 会**连同逐部位预设一起重套**，于是 WuWa 的彩色色阶会替换 AG 的灰度色阶——这点和 reze「换 look 整体观感变」一致。

**验证**：`src/diag/preset_edit_test.gd`（headless）确认覆盖/还原/`bake_ramp_from_colors` 缓存/两主脚本可解析全绿。

> 注意：HUD 是 Control 节点，最终观感（滑块布局、取色器弹出、实时跟手）需你 F5 肉眼确认；逻辑层已无头验证通过。

---

## 十、逐材质预设指派（reze「不同部位用不同材质预设」）

第九节的「逐部位编辑」是**改某套预设长什么样**（编辑 cloth 这套的参数）；
本节是另一回事——**把某个具体部件整体换成另一套预设**（如一块布料从 `cloth_smooth` 改成 `silk`），
其他部件不受影响。这正是 reze 里"给某个材质手动指派另一个 role/预设"的能力。

reze 的机制：每个材质有个 `role`，决定用哪套节点图预设；role 可被手动改指派成目录里的任意一套。
我们之前只有"自动按名字归类"，缺这一层手动指派。现已补上：

**① 预设目录（可点选的目标）** = 角色预设（`body/hair/eye/face/metal/cloth_smooth/cloth_rough/stockings/accent`）
∪ **材质类型扩展**（`leather / silk / satin / velvet / denim / rubber / glass / pearl`），加 `default`。
- 角色预设：忠实抄自 reze（`graphs.json` / `materials.ts`）。
- 材质类型扩展：**reze 目录里没有字面的 leather/silk**，是满足"皮革→丝绸"字面需求的自补扩展，
  参数按 NPR/卡通常识给（高光/边缘光/色阶取向），**非 reze 数据**，见 `material_presets.gd` 顶部 `MATERIAL_TYPES`。

**② HUD（F5 后顶部中间「部件材质预设指派」面板）**：
1. **选部件**：下拉列出本模型所有材质（按 `mp_name`）；
2. 面板显示该部件「当前生效预设」与「自动归类角色」；
3. **选目标预设** → 「应用所选预设」→ 整块部件换上该预设全部参数，其他部件不变；
4. **「还原（用角色默认）」** → 清掉指派，回到自动归类角色。

**③ 机制**（`material_presets.gd`）：
- 覆盖存内存 `_material_preset_overrides[材质名] = 目标预设名`，**不落盘**（关场景即丢），与 reze 一致；
- `apply_material(mat, pack, mat_name, role_fallback)` 解析「指派优先、否则角色回退」后调 `apply_role`；
- 切 Look pack（AG↔WuWa）时 `_apply_preset` 走 `_apply_mat_with_override`，被改成 silk 的布料**仍保持 silk**（silk 与 pack 无关），其余跟随 pack 换色阶；
- 编辑某角色预设时（`_reapply_editing_role`）只重套"当前仍生效为该角色"的材质，已被改指派的部件不被误伤。

**验证**：`src/diag/preset_reassign_test.gd`（headless）确认
cloth_smooth→silk 时 `rim_strength 0.25→0.55`、还原回 `0.25`、`preset_names` 含 silk/leather、切 wuwa 后 silk 仍生效、两主脚本可解析，全绿。
