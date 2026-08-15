# 入门篇：MMD 模型是怎么被搬进 Godot 的

> 读者：**完全没接触过这个项目**的人，甚至没写过 3D 代码也能看懂。
> 目标：看完这一篇，你能说清"数据从哪来、经过谁、变成什么"，以及"哪三条规矩不能破"。

---

## 一、这个项目在干什么？

**一句话**：把日本 MMD 软件里的 3D 人物模型和舞蹈动作，搬到 Godot 引擎里播放。

**打个比方**：
- `.pmx` 文件 = **一个人的身体**（有皮肤、衣服、骨头）
- `.vmd` 文件 = **一段舞蹈的录像笔记**（第几秒、哪根骨头转多少度）
- Godot = **舞台**

我们要做的事，就是把"身体"抬上舞台，再照着"舞蹈笔记"让它动起来。

模型文件都放在 `models/` 目录：
- `models/model.pmx` —— 人物
- `models/motions.vmd` —— 舞蹈动作（**545 条骨骼轨道，30 帧/秒**）
- `models/motion.vmd` —— ⚠️ **陷阱**：这是给**另一个模型**用的纯表情文件，骨骼轨道数为 0。别拿它调试动作，会白折腾半天。

---

## 二、五个必须懂的词（用生活比喻讲）

| 术语 | 一句话解释 | 生活比喻 |
|---|---|---|
| **骨骼（Bone）** | 一根看不见的棍子，带着周围的皮肤一起动 | 提线木偶里的一根线 |
| **rest / 静止姿态** | 这个人**什么动作都没做**时，每根骨头待的位置 | 军训时的"立正"标准姿势 |
| **pose / 姿态** | 这一帧实际摆成什么样 | 现在正在跳的这一个瞬间 |
| **局部 vs 全局** | 局部 = 相对爸爸骨头的位置；全局 = 在整个模型里的绝对位置 | "我在爸爸右手边 5 厘米"（局部） vs "我站在操场第 3 排"（全局） |
| **IK** | 反过来算：先定"脚踩在哪"，再倒推大腿小腿怎么弯 | 你伸手去拿杯子，不会先想胳膊转几度，而是眼睛盯着杯子 |

再补两个本项目特有的：

| 术语 | 解释 |
|---|---|
| **effector（末端骨）** | IK 要"拽"的那根骨头。例：`右足ＩＫ` 这根控制骨，拽的是 `右足首`（右脚踝） |
| **付与親（append parent）** | 一根骨头额外"抄"另一根骨头的动作，按比例叠加。比如袖子跟着手臂动一点点 |

---

## 三、数据是怎么流动的（全流程）

```
models/model.pmx ──▶ pmx_loader.gd   读文件，变成一堆数组（顶点、骨骼、材质）
                          │
                          ▼
                     mmd_builder.gd  建 Godot 的 Skeleton3D 骨架 + Mesh 网格 + 材质
                          │            ★ 骨骼的"立正姿势"就在这一步算出来
                          ▼
models/motions.vmd ─▶ vmd_loader.gd  读舞蹈笔记，变成"每根骨头的关键帧列表"
                          │
                          ▼
                     vmd_player.gd   每帧：插值 → 付与親 → IK 求解 → 写回骨架
                          │
                          ▼
                     Skeleton3D      Godot 拿骨架去顶点着色器里推皮肤（蒙皮）
                          │
                          ▼
                       画面
```

各脚本职责（都在项目根目录，扁平结构）：

| 文件 | 职责 | 出问题的典型症状 |
|---|---|---|
| `pmx_loader.gd` | 解析 `.pmx` 二进制，产出 `vertices/normals/uvs/boneIndices/boneWeights/bones/materials/morphs` | 乱码骨骼名、贴图找不到 |
| `mmd_builder.gd` | 建 `Skeleton3D` / `ArrayMesh` / 材质。**"立正姿势" rest 在 `_build_skeleton()` 里算** | **整个人变形、四肢变面条** |
| `vmd_loader.gd` | 解析 `.vmd`，产出 `bone_tracks`（骨名 → 关键帧数组）、`fps` | 动作不动、轨道数 = 0 |
| `vmd_player.gd` | 每帧算姿态：插值 → 付与親 → IK → `set_bone_pose_*` | 关节反折、抖动、脚打滑 |
| `mmd_material.gdshader` 等 | 卡通渲染、描边、半透明 | 颜色/描边不对（跟骨骼无关） |

---

## 四、三条不能破的项目约定 ★★★

这三条是踩过大坑换来的。**改代码前必须先读**。

### 约定 1：PMX 的 `bone.position` 是**绝对坐标**，不是相对爸爸的偏移

MMD 文件里每根骨头记的是"我在模型空间里的绝对位置"，就像"我站在操场第 3 排"。

所以全局静止姿态直接就是它本身：

```gdscript
global_rest[i] = Transform3D(Basis.IDENTITY, pos)      # ✅ 正确
global_rest[i] = global_rest[parent] * T(pos)           # ❌ 致命错误：双重累加
```

写错第二种，就等于把"我在第 3 排"理解成"我在爸爸后面再退 3 排"，从爸爸到爷爷层层叠加，**骨架被拉到几百单位外，人直接炸成面条**（详见 `docs/02-排查方法论`）。

局部静止姿态再用一遍父链反推出来：

```gdscript
local_rest[i] = global_rest[parent].affine_inverse() * global_rest[i]
```

### 约定 2：Godot 4.7 的 `pose` 是"绝对局部变换"，必须初始化成 rest（不是单位矩阵）

Godot 里 `set_bone_pose()` 不是"在 rest 上再加一点"，而是**直接替换掉 rest**。

所以建好骨架后必须写 `skel.set_bone_pose(i, local_rest)`。
如果留成单位矩阵，蒙皮矩阵会变成"全局 rest 的逆"，静止就已经是变形状态。

（这一条是用 `pose_test.gd` 这个 2 根骨头的小实验实测确认的，不是猜的。）

### 约定 3：`FLIP_Z` 要**整套一起翻**

MMD 是左手坐标系，Godot 是右手，所以项目里统一把 Z 取反（`FLIP_Z = true`）。

必须同步翻的地方：
- 顶点、法线（`mmd_builder`）
- 骨骼 `position`（`mmd_builder._build_skeleton`）
- VMD 的位移和旋转（`vmd_player`，旋转要做**共轭镜像**）

**只翻一半的后果非常阴险**：静止时看不出问题（bind 和 pose 互相抵消了），但骨头一转，**肢体就往 Z 的反方向弯**，整套动作变成镜像。

---

## 五、怎么跑起来

### 有显卡，看画面
Godot 编辑器里打开项目，**F5**。

如果画面异常但你确定代码是对的：关掉 Godot → 删项目里的 `.godot` 缓存目录 → 重开 → F5。旧缓存会掩盖真错误。

### 没显卡 / 想看数字（重要）
用 Godot 的 **console 版**跑纯 CPU 脚本，不渲染也能把骨骼数据 dump 成 JSON：

```bash
"D:\MySpace\workshop\Agame\Godot\Godot_v4.7.1-stable_win64_console.exe" \
  --headless \
  --path "D:\MySpace\workshop\GodotPros\AfterGlowGodot" \
  --script "res://verify.gd"
```

⚠️ **`--path` 必须用反斜杠 `\`**。写成 `/d/MySpace/...` 会报 `Invalid project path`。

现成的三个诊断脚本：

| 脚本 | 作用 | 输出 |
|---|---|---|
| `dump.gd` | 导出 568 根骨的原始数据（`pos_raw`、rest、IK 链、付与親）+ VMD 轨道 | `C:/ag_vmdtest/dump.json` |
| `verify.gd` | **跑真实的 `mmd_builder` + `vmd_player`**，导出第 0/1/5 帧每根骨的世界坐标、骨长、IK 距离 | `C:/ag_vmdtest/verify.json` |
| `pose_test.gd` | 2 根骨头的极简实验，验证 Godot 的 pose/skin 语义 | 控制台打印 |

怎么用这些数据做排查，见 `docs/02-排查方法论-骨骼变形与动画Bug定位.md`。

---

## 六、headless 环境里的几个语言坑

写诊断脚本时会撞到，提前知道能省一小时：

| 坑 | 表现 | 解法 |
|---|---|---|
| `extends SceneTree` 没有 `add_child()` | Parse Error | 不挂节点树也能跑，直接 `player.setup(...)` |
| 值类型不能 `as Transform3D` | cast 返回 `Nil` | 直接访问属性：`w[i].origin` |
| headless 下 `get_bone_global_pose/global_rest` 不稳 | 返回 `Nil` | 自己沿父链累乘 `get_bone_rest(i)` |
| `var x := ...` 推不出类型 | `Cannot infer type` | 显式写：`var tgt: int = int(...)` |
| `if d.has(k): var bi = d[k]` | `Identifier not declared` | 改成 `if not d.has(k): continue` 再声明 |
| `for name in ...` | 警告 shadow 基类属性 | 换个变量名，如 `for bname in ...` |
