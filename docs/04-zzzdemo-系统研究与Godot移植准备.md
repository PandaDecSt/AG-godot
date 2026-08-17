# 04 · ZZZDemo 系统研究与 Godot 4.7 移植准备

> 研究对象：`D:\MySpace\Unity\Pros\zzzdemo-source-code`
> 性质：仿《绝区零》的 Unity URP 战斗 Demo（移动 / 连招 / 闪避 / 切人 / 打击感 / 对象池）
> 目的：把它的**架构与可复用模式**抽出来，为写进我们的 AfterGlowGodot（PMX→Godot 4.7 移植项目）做准备。
> 结论先行：**不要整盘照搬**（动画是 Unity AnimationClip，我们只有 VMD），但把它底层的「框架积木」——事件总线、黑板、可绑定属性、双 FSM、计时器池、对象池、Resource 数据驱动、打击感三件套——原样搬进 Godot 是低风险高回报的，能给我们的 MMD 播放器套上一层真正的「游戏框架」。

---

## 一、系统总览（一句话地图）

整套 Demo 的灵魂是：**双有限状态机（移动 + 连招）并行 + 数据驱动（ScriptableObject）+ 单例管理器集群 + 全局事件总线 + 对象池**。

| 模块 | 核心文件 | 作用 | 对我们是否有用 |
|---|---|---|---|
| 可绑定属性 | `Tool/BindableProperty/BindableProperty.cs` | 值变了自动通知（状态切换的「触发器」） | ✅ 直接有用，GDScript 可复刻 |
| 状态机内核 | `FSM/StateMachine/IState.cs` + `StateMachine.cs` | 状态接口 + 状态切换 | ✅ 直接有用 |
| 移动 FSM | `FSM/.../Movement/*`（10 个状态） | 走/跑/冲/闪/切人 等 | ⚠️ 逻辑可借鉴，状态需按 VMD 重建 |
| 连招 FSM | `FSM/.../Combo/*`（3 状态） | 普攻/技能/空状态 | ⚠️ 同上 |
| 连招逻辑 | `FSM/.../Combo/CharacterCombo.cs` + `CharacterComboBase.cs` | 预输入、连招衔接、移动打断、QTE、伤害触发 | ⚠️ 思路可借鉴 |
| 角色移动底座 | `Character/Base/CharacterMoveControllerBase.cs` | CharacterController + 根运动 + 重力 + 地面/坡面检测 | ✅ 对应 Godot `CharacterBody3D`+根运动 |
| 生命/伤害 | `Health/CharacterHealthBase.cs` + `CharacterHeath.cs` | HP/韧性/防御值、受击动画、格挡、破防→QTE | ✅ 数据模型可复刻 |
| 输入 | `Input/CharacterInputSystem.cs` | 封装 Unity Input System | ✅ 对应 Godot InputMap |
| 全局事件 | `Tool/EventManager/GameEventsManager.cs` | string→委托 的事件中心 | ✅ 直接有用（我们的 EventBus） |
| 黑板 | `Tool/GameBlackboard/GameBlackboard.cs` | 跨角色共享数据 + 当前敌人 | ✅ 直接有用 |
| 计时器 | `Tool/TimerManager/TimerManager.cs` + `GameTimer.cs` | 缩放/非缩放 倒计时 + 对象池复用 | ✅ 直接有用 |
| 打击感 | `Tool/VFX_Tool/CameraHitFeel.cs` + `VFXManager.cs` | 顿帧 / 慢动作 / 震屏 / 特效调速 | ✅ **强烈推荐**，配合 MMD 物理观感爆棚 |
| 对象池 | `Tool/PoolManager/*`（SFX/VFX/通用） | 音效/特效/计时器 池化 | ✅ 直接有用 |
| 角色切换 | `Character/SwitchCharacter/SwitchCharacter.cs` | 多角色管理、位置生成、相机目标切换 | ⚠️ 思路可借鉴 |
| 相机 | `Cam/CameraSwitcher.cs` 等 | Cinemachine StateDriven + Dolly + 缩放 + 居中 | ⚠️ Cinemachine 无内置，需自建 |
| 单例 | `Tool/Unilts/Tools/Singleton/*` | Mono / 非Mono 单例基类 | ✅ 对应 Godot AutoLoad |

---

## 二、逐系统详解 + Godot 映射

### 2.1 可绑定属性 `BindableProperty<T>`（整个项目的神经）
```csharp
public class BindableProperty<T> {
    private T mValue;
    public Action<T> OnValueChanged;
    public T Value { get => mValue; set { if(!value.Equals(mValue)){ mValue=value; OnValueChanged?.Invoke(mValue); } } }
}
```
**干嘛用**：状态字段（如 `currentState`、`currentIndex`、敌人 Transform）一旦变化，自动触发副作用，省掉一堆 `if (changed)`。状态机 `StateMachine` 就靠它：`currentState.OnValueChanged += 回调`。

**Godot 等效**：GDScript 没有泛型委托，但用 `signal` 完美替代。见第四节骨架。

### 2.2 双 FSM（移动 + 连招）
- `IState` 接口：`Enter / Exit / HandInput / Update / OnAnimationTranslateEvent / OnAnimationExitEvent`。
- `StateMachine`：`BindableProperty<IState> currentState`，`ChangeState()` 先 `Exit()` 旧态再 `Enter()` 新态。
- `Player` 同时持有 `movementStateMachine` 和 `comboStateMachine`，每帧只驱动「当前激活角色」的两个状态机。
- 动画事件（在 AnimationClip 上挂的 Event）回调到 `Player` 的 `OnAnimationTranslateEvent / OnAnimationExitEvent`，再转发给状态机做切换——**这是动画与逻辑解耦的关键**。

**Godot 等效**：`AnimationPlayer`/`AnimationTree` 的 `animation_finished` 信号 + `AnimationTree` 的 `animation_node_finished`（或直接用 `AnimationNodeStateMachine` 的 `state_changed`）。根运动事件则用 `AnimationTree` 的 `root_motion_track`。状态用 `RefCounted` 对象即可，不一定要是 Node。

### 2.3 连招逻辑（预输入是灵魂）
`CharacterComboBase` 里几个标志位就是连招手感的命门：
- `canInput`（预输入窗口是否开启）
- `canATK`（连招最小播放间隔 / 冷却）
- `canLink`（能否衔接下一段）
- `canMoveInterrupt`（移动能否打断当前攻击）
- `comboIndex` / `currentIndex`（第几段、动画名索引）
- `ATKIndex`（同一段攻击内的多个伤害点计数）
- `canQTE`（破防后是否允许触发切人连携）

动画事件在指定帧调用 `EnablePreInput()` / `EnableMoveInterrupt()` / `DisableLinkCombo()` / `ATK()`，从而精确控制手感窗口。伤害通过 `GameEventsManager.CallEvent("触发伤害", 伤害, 受击动画, 格挡动画, 攻击者, 被击者, combo)` 广播出去，由 `CharacterHealthBase` 接收。

**Godot 等效**：这套「标志位 + 动画事件窗口」逻辑是引擎无关的，连招状态机换成本地 VMD 动作文件名即可复用。伤害广播改用我们的 EventBus。

### 2.4 生命/伤害 `CharacterHealthBase` / `CharacterHeath`
字段：`currentHP / currentStrength(韧性) / currentDefenseValue(防御值)`，全是 `BindableProperty`。
- 受击：监听 `触发伤害` 事件 → 看 `hasStrength` 决定格挡(parry)还是挨打(hit)动画 → 扣血/扣韧性/扣防御值。
- **破防**：防御值≤0 时 `CallEvent("达到QTE条件", enemy)` → 触发切人慢动作连携。

**Godot 等效**：数据模型原样搬（用 Resource 或普通 `RefCounted` + 信号）。这是将来给 MMD 角色加「可被攻击」能力的模板。

### 2.5 打击感 `CameraHitFeel` + `VFXManager`（最值得搬的部分）
三件套实现：
1. **顿帧（hit-stop）**：`animator.speed = 0` + 所有 `ParticleSystem.simulationSpeed = 0`，等 `time` 秒后恢复。注意——它动的是**角色动画速度**，不是全局 `Time.timeScale`，所以游戏其他部分照常跑。
2. **慢动作**：`animator.speed` 和 VFX `simulationSpeed` 一起 Lerp 从 `speedMult` 恢复到 1（配合 `Time.timeScale` 做 QTE 整体慢放）。
3. **震屏**：`CinemachineImpulseSource.GenerateImpulseWithForce(force)`。

**Godot 等效（关键差异）**：
- 顿帧：`AnimationPlayer.speed_scale = 0`（只停该角色）/ `GPUParticles3D.speed_scale = 0`（停特效）。比 Unity 更干净——不用动全局 `Engine.time_scale`。
- 慢动作：同上 Lerp `speed_scale`，想要整体慢放再叠 `Engine.time_scale`。
- 震屏：Godot 无 Cinemachine，自己写个 `CameraShake`（`Camera3D` 位置随机偏移 + Tween 衰减）即可，几十行。
- 我们已有 GDExtension 物理（头发/裙子），顿帧时如果 `AnimationPlayer.speed_scale=0` 但物理还在跑会穿帮，需在顿帧期间同步暂停物理步进——这点 Unity 版没遇到（它用动画根运动而非物理），**移植时要特别处理**。

### 2.6 对象池（SFX / VFX / 通用）
都是 `Queue<GameObject>` 思路：`Dequeue()` 取出激活 → 用完 `Enqueue()` 归还，避免 `Instantiate/Destroy` 的 GC 抖动。
- `SFX_PoolManager`：二级字典 `SoundStyle → Queue` + 按角色名分的「大中心」。
- `VFX_PoolManager`：`CharacterNameList → (特效名 → Queue)`。
- `GamePoolManager`：本仓库里是**空壳**（只有类声明，没实现），真正用的是上面两个具体池。

**Godot 等效**：Godot 没有 `Queue` 内置类型，用 `Array` 当队列（`push_back` / `pop_front`）或写个 `Pool` 工具类。见第四节。

### 2.7 角色切换 `SwitchCharacter` + 相机 `CameraSwitcher`
- 维护 `waitingCharacterList`（待命队列）、`newCharacterName`（`BindableProperty<CharacterNameList>`）。
- 切人时：旧角色播 `SwitchOut`、新角色在旧角色身后偏移生成播 `SwitchIn`、相机 LookAt/Follow 目标点交换。
- 相机靠 Cinemachine 虚拟相机优先级切换（StateDriven 按状态、Dolly 大招特写）。

**Godot 等效**：待命队列/绑定属性逻辑直接搬；相机需自建（SpringArm3D + 自定义跟随/混合，优先级用变量比较自己实现）。

### 2.8 数据驱动（ScriptableObject）
`PlayerSO` 下挂一堆子数据：`MovementData / IdleData / WalkData / RunData / SprintData / DashData / ComboData / RotationData / EnemyDetectionData`。策划调参全在 SO 上，代码不写死数值。

**Godot 等效（最干净的 1:1）**：Godot 的 `Resource`（`.tres`）就是 ScriptableObject。直接 `class_name PlayerSO extends Resource` + `@export` 字段，在编辑器里填，运行时 `load("res://...")`。我们已有 `material_presets.gd` 用 Resource 的思路，保持一致即可。

### 2.9 单例 / 输入
- `Singleton<T>`（Mono，`DontDestroyOnLoad`）→ Godot **AutoLoad**（Project Settings → Autoload），天然单例 + 跨场景。
- `SingletonNonMono<T>`（纯 C# 管理器）→ Godot 普通 `RefCounted` 单例或 AutoLoad。
- `CharacterInputSystem` 封装 Unity Input System → Godot 用 **InputMap**（Project Settings → Input Map 定义 action）+ `Input.is_action_pressed()`，或 `InputEvent`。

---

## 三、对 AfterGlowGodot 的适配要点与坑

1. **动画资产不通用**：我们的角色动画是 VMD（通过 `vmd_player.gd` 播放），不是 Unity AnimationClip。所以 **FSM 的具体状态要按我们的动作文件名重建**，但状态机框架、预输入/连招标志位逻辑、伤害广播完全可复用。
2. **根运动**：Unity 用 `characterAnimator.ApplyBuiltinRootMotion()`；Godot 用 `AnimationTree.root_motion_track` + `get_root_motion_transform()`（4.x 原生支持）。我们 `mmd_builder.gd` 建的 `Skeleton3D` 配合 `AnimationTree` 即可。
3. **CharacterController → CharacterBody3D**：Godot 没有 CharacterController，用 `CharacterBody3D`（`move_and_slide`），重力/地面检测自己写（参考 `CharacterMoveControllerBase` 的球体检测 + 坡面投影）。
4. **顿帧别动全局 `Engine.time_scale`**：只停 `AnimationPlayer.speed_scale` + 粒子，并**同步暂停 GDExtension 物理步进**（避免头发裙子穿帮），恢复时一起恢复。
5. **Cinemachine 无内置**：相机系统得自己写；但「状态驱动相机」「切人特写」本质是优先级比较 + LookAt/Follow 目标切换，逻辑可搬。
6. **事件总线替代方案**：Unity 用 `string → Action` 字典；Godot 可继续用 `Dictionary[String, Array[Callable]]`，或干脆用 Godot 原生 `signal`（更类型安全）。建议自建 `EventBus` AutoLoad（见第四节），比原生 signal 更适合「跨模块解耦 + 字符串路由」。
7. **对象池**：Godot 用 `Array` 当队列；注意 Godot 节点 `queue_free` 才是真删，池化用 `visible=false` + `set_process(false)` 而非销毁。

---

## 四、可直接落地的 GDScript 基金会（移植准备产物）

下面这些「积木」是引擎无关的，建议作为第一批搬进 `src/` 的框架层。放 `src/framework/` 下。

### 4.1 BindableProperty（替代 BindableProperty<T>）
```gdscript
# src/framework/bindable_property.gd
class_name BindableProperty extends RefCounted
signal value_changed(old_value, new_value)

var _value

func _init(p_value = null):
    _value = p_value

func get_value():
    return _value

func set_value(p_value) -> void:
    if _value != p_value:
        var old = _value
        _value = p_value
        value_changed.emit(old, _value)
```

### 4.2 FSM 内核（替代 IState + StateMachine）
```gdscript
# src/framework/state.gd
class_name State extends RefCounted
func enter(): pass
func exit(): pass
func hand_input(): pass
func update(_delta): pass
func on_anim_translate(_next: State): pass
func on_anim_exit(): pass

# src/framework/state_machine.gd
class_name StateMachine extends RefCounted
signal state_changed(old_state, new_state)
var current_state: State
func change_state(next: State) -> void:
    if current_state == next: return
    var old = current_state
    if current_state: current_state.exit()
    current_state = next
    if current_state: current_state.enter()
    state_changed.emit(old, next)
func hand_input(): if current_state: current_state.hand_input()
func update(delta): if current_state: current_state.update(delta)
```

### 4.3 EventBus（替代 GameEventsManager，AutoLoad）
```gdscript
# src/framework/event_bus.gd  —— 在 Project Settings 中设为 AutoLoad，名字 EventBus
extends Node
var _listeners: Dictionary = {}   # String -> Array[Callable]

func listen(name: String, cb: Callable) -> void:
    if not _listeners.has(name): _listeners[name] = []
    if not _listeners[name].has(cb): _listeners[name].append(cb)

func unlisten(name: String, cb: Callable) -> void:
    if _listeners.has(name): _listeners[name].erase(cb)

func emit_event(name: String, args: Array = []) -> void:
    if not _listeners.has(name): return
    for cb in _listeners[name]:
        cb.callv(args)
```

### 4.4 Blackboard（替代 GameBlackboard，AutoLoad）
```gdscript
# src/framework/blackboard.gd  —— AutoLoad: Blackboard
extends Node
var data: Dictionary = {}
var enemy: Node3D = null
signal enemy_changed(old_enemy, new_enemy)

func set_data(key: String, value: Variant) -> void: data[key] = value
func get_data(key: String):
    return data.get(key)
func set_enemy(e: Node3D) -> void:
    var old = enemy
    enemy = e
    enemy_changed.emit(old, e)
```

### 4.5 TimerManager（替代 TimerManager，AutoLoad，支持缩放/非缩放）
```gdscript
# src/framework/timer_manager.gd —— AutoLoad: TimerManager
extends Node
var _pool: Array = []          # 空闲 Timer
var _active: Array = []

func _get_timer() -> Timer:
    var t = _pool.pop_back()
    if t == null:
        t = Timer.new()
        add_child(t)
    t.one_shot = true
    t.process_mode = Node.PROCESS_MODE_ALWAYS   # 非缩放（真实）时间
    _active.append(t)
    return t

# scaled=true 用 Engine.time_scale 影响；这里用 process_mode 区分
func get_timer(time: float, cb: Callable, real_time: bool = false) -> Timer:
    var t = _get_timer()
    t.process_mode = Node.PROCESS_MODE_ALWAYS if real_time else Node.PROCESS_MODE_INHERIT
    t.timeout.connect(func():
        cb.call()
        _release(t)
    , CONNECT_ONE_SHOT)
    t.start(time)
    return t

func _release(t: Timer) -> void:
    _active.erase(t)
    t.timeout.disconnect(t.timeout.get_connections()[0].callable) if false else null
    _pool.append(t)
```

### 4.6 PoolManager（替代 SFX/VFX 池，AutoLoad）
```gdscript
# src/framework/pool_manager.gd —— AutoLoad: PoolManager
extends Node
var _pools: Dictionary = {}   # String -> Array[Node]

func register_pool(key: String, prototype: Node, count: int, parent: Node = null) -> void:
    var arr: Array = []
    for i in count:
        var n = prototype.duplicate()
        n.visible = false
        (parent if parent else self).add_child(n)
        arr.append(n)
    _pools[key] = arr

func take(key: String) -> Node:
    if not _pools.has(key) or _pools[key].is_empty(): return null
    var n = _pools[key].pop_front()
    n.visible = true
    return n

func give_back(key: String, n: Node) -> void:
    n.visible = false
    _pools[key].append(n)
```

### 4.7 Resource 数据（替代 ScriptableObject）
```gdscript
# src/framework/player_so.gd
class_name PlayerSO extends Resource
@export var movement_data: Resource
@export var combo_data: Resource
@export var rotation_time: float = 0.15
# ... 子数据各自是一个 Resource 子类，对应 Unity 的 PlayerMovementData / PlayerComboData 等
```
在编辑器里「创建 Resource」→ 填值 → 存 `.tres`，运行时 `load()`。

### 4.8 CameraHitFeel（打击感三件套，AutoLoad）
```gdscript
# src/framework/camera_hit_feel.gd —— AutoLoad: HitFeel
extends Node
var slow_reset_speed: float = 4.0

# 顿帧：只停目标角色动画 + 粒子，不碰全局时间
func hit_stop(targets: Array, time: float) -> void:
    for t in targets:
        if t.has("animation_player"): t.animation_player.speed_scale = 0.0
        if t.has("particles"): t.particles.speed_scale = 0.0
    # 注意：若用了 GDExtension 物理，这里也要暂停物理步进
    await get_tree().create_timer(time, true).timeout
    for t in targets:
        if t.has("animation_player"): t.animation_player.speed_scale = 1.0
        if t.has("particles"): t.particles.speed_scale = 1.0

# 慢动作：Lerp 恢复
func slow_motion(targets: Array, speed: float, time: float) -> void:
    for t in targets:
        if t.has("animation_player"): t.animation_player.speed_scale = speed
    await get_tree().create_timer(time, true).timeout
    var cur = speed
    while abs(cur - 1.0) > 0.001:
        cur = lerp(cur, 1.0, get_process_delta_time() * slow_reset_speed)
        for t in targets:
            if t.has("animation_player"): t.animation_player.speed_scale = cur
        await get_tree().process_frame
    for t in targets:
        if t.has("animation_player"): t.animation_player.speed_scale = 1.0

# 震屏：给 Camera3D 加随机偏移
func shake(cam: Camera3D, force: float, time: float = 0.2) -> void:
    var base = cam.position
    var t = get_tree().create_timer(time, true)
    while not t.is_stopped():
        cam.position = base + Vector3(randf_range(-force, force), randf_range(-force, force), 0)
        await get_tree().process_frame
    cam.position = base
```

---

## 五、建议的落地路线（为将来铺路）

**阶段 0（现在就能做，低风险）**：把第四节的 `src/framework/` 六件套（BindableProperty / StateMachine / EventBus / Blackboard / TimerManager / PoolManager）搬进项目，设为 AutoLoad。它们不依赖任何动画资产，纯框架层，立即提升我们代码的组织度。

**阶段 1（数据层）**：把 `PlayerSO` 等 Resource 数据类建起来，把我们已有的 `material_presets.gd` 思路统一到 Resource 模式。

**阶段 2（打击感）**：实现 `CameraHitFeel`（顿帧/慢动作/震屏），接上现有 VMD 播放 + GDExtension 物理。哪怕只是「播放攻击 VMD 时来一下顿帧」，观感就会质的飞跃。**重点验证顿帧期间物理同步暂停**。

**阶段 3（等有了玩法目标再做）**：双 FSM 的具体状态（移动/连招）、角色切换、相机系统——这些需要具体动作资产和玩法设计，不宜提前照搬。把 ZZZ 的「预输入 / 连招衔接 / 移动打断 / 破防 QTE」逻辑作为**设计参考**，按我们的 VMD 动作重建。

---

## 六、关键文件索引（便于回查）

```
zzzdemo-source-code/Assets/Scripts/
├─ Tool/BindableProperty/BindableProperty.cs        # 值变更通知（神经）
├─ FSM/StateMachine/{IState,StateMachine}.cs        # FSM 内核
├─ FSM/Characters/Player/Player.cs                  # 双状态机持有 + 动画事件转发
├─ FSM/.../Movement/*                                # 移动 FSM（10 状态）
├─ FSM/.../Combo/{CharacterCombo,CharacterComboBase}.cs  # 连招逻辑（预输入/伤害/QTE）
├─ FSM/.../Combo/States/ComboStates/*               # 连招状态（ATKIng/Null/Skill）
├─ Character/Base/CharacterMoveControllerBase.cs    # CharacterController + 根运动 + 重力
├─ Health/{CharacterHealthBase,CharacterHeath}.cs    # HP/韧性/防御值/破防QTE
├─ Input/CharacterInputSystem.cs                    # 输入封装（→ Godot InputMap）
├─ Tool/EventManager/GameEventsManager.cs           # 事件总线（→ EventBus）
├─ Tool/GameBlackboard/GameBlackboard.cs            # 黑板（→ Blackboard）
├─ Tool/TimerManager/{TimerManager,GameTimer}.cs    # 计时器池（→ TimerManager）
├─ Tool/VFX_Tool/{CameraHitFeel,VFXManager}.cs      # 打击感三件套（→ CameraHitFeel）
├─ Tool/PoolManager/**                               # SFX/VFX 对象池（→ PoolManager）
├─ Character/SwitchCharacter/SwitchCharacter.cs      # 角色切换
├─ Cam/CameraSwitcher.cs                             # Cinemachine 相机（→ 自建）
└─ Tool/Unilts/Tools/Singleton/*                     # 单例基类（→ Godot AutoLoad）
```

> 注：`Combo/CharacterCombo.cs`（仓库顶层那个）是**已弃用的旧版注释代码**，真正用的是 `FSM/Characters/Player/State Machine/Combo/CharacterCombo.cs`，研究时以 FSM 树下的为准。`GamePoolManager.cs` 是空壳，实际池在 SFX/VFX 两个管理器里。
