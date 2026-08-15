class_name VMDPlayer
extends Node

# VMD 运行时播放器：每帧 bezier 插值驱动骨骼局部变换，再做 MMD 式 CCD IK（脚不穿地）、
# 付与親(D骨/捩骨)传导，最后把表情写进 blend shape。
#
# ★ 本文件的 IK / 付与親 是 AfterglowWeb 的 1:1 移植：
#     src/scene/ik-solver.ts   (solveIK / classifyLink / limitAngle / extractEuler)
#     src/scene/skeleton.ts    (updateWorldMatrices 里的付与親合成)
#   之前自己写的"朴素 CCD"缺了 4 个机制，会造成膝盖反折+肢体拉长，详见 _solve_chain 注释。
#
# 用法（mmd_importer 构建模型后）：
#   var p := VMDPlayer.new()
#   add_child(p)
#   p.setup(skeleton, model["bones"], vmd_data, [mesh_instance, shadow_instance], array_mesh, model["morphs"])

# ---- 为什么自己维护骨骼世界变换，而不用 skeleton.get_bone_global_pose() ----
# CCD 每转一根骨骼就要立刻读到"末端骨的最新世界位置"，一帧内要读写上千次。
# Godot 的 global pose 是引擎内部按脏标记惰性重算的，一帧内反复写 pose 再读 global 既不保证
# 即时刷新、也可能每次触发全骨架重算（O(骨骼数) × 上千次）。
# 所以这里完全对齐 AfterglowWeb：自己持有 局部旋转/位置 + 世界矩阵 数组，IK 在自己的数组里迭代，
# 收敛后再一次性写回 Skeleton3D 的 pose。既确定又快。

# ---- pose 语义（Godot 4.7，源码确认）----
# set_bone_pose_position/rotation 写的是【绝对局部变换】，引擎最终局部变换 = pose 本身
# （rest 仅在骨骼被禁用时作回退，不与 pose 相乘）。故：
#   绝对局部位置 = 骨骼 rest 位置 + VMD 平移增量（= AfterglowWeb 的 localPos = bindPos + translation）
#   绝对局部旋转 = VMD 旋转增量（MMD 的 rest 旋转恒为单位，见 mmd_builder 用 Basis.IDENTITY 递推）

# 坐标手性：mmd_builder 的 FLIP_Z 把顶点/法线/骨骼 rest 的 Z 一起取反（MMD 左手 → Godot 右手）。
# 镜像变换 S=diag(1,1,-1) 下：位移 (x,y,-z)；旋转四元数 (x,y,z,w) → (-x,-y,z,w)；
# 欧拉角 (ex,ey,ez) → (-ex,-ey,ez)（对任意旋转序都成立，因共轭对乘积可分配）→ IK 限位区间同步换算。
const FLIP_Z := true

# IK 链节的"可解轴"分类（对齐 ik-solver.ts 的 SolveAxis）
const SA_NONE := 0
const SA_FIXED := 1     # 限位全为 0 → 该骨完全不参与反解
const SA_X := 2
const SA_Y := 3
const SA_Z := 4
# 限位钳位时用的欧拉旋转序（对齐 ik-solver.ts 的 EulerOrder）
const EO_YXZ := 0
const EO_ZYX := 1
const EO_XZY := 2

const HALF_PI := PI * 0.5
const EULER_LIMIT := 88.0 * PI / 180.0    # asin 万向锁保护（对齐 THRESHOLD）
const IK_EPS := 1e-8
const IK_DONE := 0.1                      # 末端与目标距离小于此值即收工（MMD 原生单位，builder 未缩放）

var skeleton: Skeleton3D = null
var _physics: MMDPhysicsGD = null        # 可选：挂上后每帧在 _flush 之后跑物理，驱动头发/裙子
var _need_phys_reset: bool = false       # 循环回绕时置位，flush 后调用 physics.reset 吸附新位姿
var vmd: Dictionary = {}
var pmx_bones: Array = []
var mesh: ArrayMesh = null
var morph_targets: Array = []           # 需要同步表情的 MeshInstance3D（可见网格 + 阴影副本）
var pmx_morphs: Array = []              # PMX morph 定义（展开组 morph 用）

var bone_cache: Dictionary = {}          # VMD 骨骼名 -> 骨架索引
# VMD 表情名 -> [{slot, ratio}, ...]
# 一条 VMD 轨可能对应多个 blend shape：本模型 11 个组 morph（まばたき/笑い/瞳小…）
# 都被 VMD 直接驱动，每个组内部是「左眼 + 右眼」两个顶点 morph，必须一权重驱动两个槽位。
var morph_route: Dictionary = {}
var _slot_weight: PackedFloat32Array = PackedFloat32Array()   # 本帧各槽位累加权重
var _slot_last: PackedFloat32Array = PackedFloat32Array()     # 上帧已写入 GPU 的值
var ik_chains: Array = []
var _cursor: Dictionary = {}             # 关键帧游标（避免每帧线性扫全轨）

# ---- 自维护的骨骼运行时状态（对齐 AfterglowWeb 的 Skeleton 数组）----
var _parent := PackedInt32Array()        # 父骨索引
var _bind_pos := PackedVector3Array()    # rest 局部位置（= bindPositions）
var _local_pos := PackedVector3Array()   # 绝对局部位置 = bind + VMD 平移
var _local_rot: Array = []               # 绝对局部旋转（Quaternion）
var _ik_rot: Array = []                  # IK 增量（左乘到 _local_rot 上）
var _eff_pos := PackedVector3Array()     # 叠加付与親后的最终局部位置（写回骨架用）
var _eff_rot: Array = []                 # 叠加付与親后的最终局部旋转
var _world: Array = []                   # 骨架空间世界变换（Transform3D）
var _order := PackedInt32Array()         # 拓扑序：父一定排在子之前
var _ap_src := PackedInt32Array()        # 付与親来源骨（-1 表示无）
var _ap_ratio := PackedFloat32Array()    # 付与親比率
var _ap_flags := PackedByteArray()       # bit0=继承旋转 bit1=继承平移

# ---- 播放控制（供 HUD / Inspector 调）----
var time := 0.0
var playing := false
var loop := true
var speed := 1.0
var duration := 0.0
var ik_enabled := true
var append_enabled := true
var morph_enabled := true
# 表情权重是否钳到 [0,1]。MMD 原生行为是【累加不钳位】（组 morph 与其成员各自贡献相加），
# 已实测本动作各槽位累加峰值 = 1.0（组 morph 与成员轨在时间上不重叠），故默认保持忠实不钳位。
# 若换用别的 .vmd 出现脸部顶穿，把它打开即可。
var morph_clamp := false

var matched_bones := 0
var matched_morphs := 0
var _ik_logged := false                  # IK 首帧诊断只打一次


func setup(skel: Skeleton3D, bones: Array, vmd_data: Dictionary, targets: Array = [],
		arr_mesh: ArrayMesh = null, morphs: Array = []) -> void:
	skeleton = skel
	pmx_bones = bones
	vmd = vmd_data
	morph_targets = targets
	mesh = arr_mesh
	pmx_morphs = morphs
	if skeleton == null or vmd.is_empty():
		push_error("[VMDPlayer] setup 参数无效")
		return
	_build_runtime()
	_build_bone_cache()
	_build_ik()
	_build_append()
	_build_morph_cache()
	_compute_duration()
	_reset_all_to_neutral()
	playing = true
	print("[VMDPlayer] IK=AfterglowWeb移植(轴约束+限位反射+父空间轴) 骨骼匹配=%d/%d 表情匹配=%d/%d IK链=%d 付与親=%d 时长=%.2fs"
		% [matched_bones, vmd["bone_tracks"].size(),
			matched_morphs, vmd["morph_tracks"].size(),
			ik_chains.size(), _append_count(), duration])


# ---------------- 初始化 ----------------

func _build_runtime() -> void:
	var n := skeleton.get_bone_count()
	_parent.resize(n)
	_bind_pos.resize(n)
	_local_pos.resize(n)
	_eff_pos.resize(n)
	_local_rot.resize(n)
	_ik_rot.resize(n)
	_eff_rot.resize(n)
	_world.resize(n)
	_ap_src.resize(n)
	_ap_ratio.resize(n)
	_ap_flags.resize(n)
	var non_identity := 0
	for i in n:
		var rest := skeleton.get_bone_rest(i)
		_parent[i] = skeleton.get_bone_parent(i)
		_bind_pos[i] = rest.origin
		_local_pos[i] = rest.origin
		_eff_pos[i] = rest.origin
		_local_rot[i] = Quaternion.IDENTITY
		_ik_rot[i] = Quaternion.IDENTITY
		_eff_rot[i] = Quaternion.IDENTITY
		_world[i] = Transform3D.IDENTITY
		_ap_src[i] = -1
		_ap_ratio[i] = 0.0
		_ap_flags[i] = 0
		if not rest.basis.is_equal_approx(Basis.IDENTITY):
			non_identity += 1
	_order = _topo_order(n)
	if non_identity > 0:
		# MMD 骨骼 rest 只有位移没有旋转，本套 IK/付与親数学以此为前提。
		push_warning("[VMDPlayer] %d 根骨骼的 rest 带旋转，与 MMD 约定不符（IK 可能不准）" % non_identity)


# 拓扑排序：保证算世界变换时父骨已经算好。PMX 一般已满足 父索引<子索引，
# 但规范并不强制，遇到乱序骨（部分模型的物理骨）不排序会算出错位。
func _topo_order(n: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var done := PackedByteArray()
	done.resize(n)
	done.fill(0)
	var progressed := true
	while out.size() < n and progressed:
		progressed = false
		for i in n:
			if done[i] != 0:
				continue
			var p := _parent[i]
			if p < 0 or done[p] != 0:
				out.append(i)
				done[i] = 1
				progressed = true
	if out.size() < n:
		push_warning("[VMDPlayer] 骨骼父子关系存在环，%d 根骨按原序兜底" % (n - out.size()))
		for i in n:
			if done[i] == 0:
				out.append(i)
	return out


func _build_bone_cache() -> void:
	var missing: Array = []
	# 对齐 AfterglowWeb animation-player.ts:50：把骨架骨骼名也归一化，再和(已归一化的)VMD 名匹配。
	# 否则 VMD 的「右足ＩＫ」(全角) 匹配不到 PMX 的「右足IK」(半角) → IK 骨整条丢弃。
	var skel_norm := {}
	for i in skeleton.get_bone_count():
		skel_norm[VMDLoader.normalize_bone_name(skeleton.get_bone_name(i))] = i
	for bname in vmd["bone_tracks"].keys():
		var n := VMDLoader.normalize_bone_name(bname)
		if skel_norm.has(n):
			bone_cache[bname] = skel_norm[n]
		else:
			missing.append(bname)
	matched_bones = bone_cache.size()
	if missing.size() > 0:
		print("[VMDPlayer] %d 条骨骼轨模型里没有(已忽略): %s%s"
			% [missing.size(), missing.slice(0, 6), " ..." if missing.size() > 6 else ""])


# PMX 里 flag&0x0020 的骨骼是"IK 骨"，它自己的位置就是目标点(goal)，由 VMD 直接驱动；
# ikTargetIndex 指向的才是要去够到目标的末端骨(effector，如 左足首)；ikLinks 是被反解旋转的链(ひざ/足)。
# 注意：mmd_builder 按 PMX 顺序 add_bone，故 PMX 索引 == 骨架索引，直接用索引比 find_bone 更稳。
func _build_ik() -> void:
	if pmx_bones.size() != skeleton.get_bone_count():
		push_warning("[VMDPlayer] PMX 骨骼数与骨架不一致，IK 索引可能错位")
	for i in pmx_bones.size():
		var b: Dictionary = pmx_bones[i]
		if not (b["flag"] & 0x0020):
			continue
		var eff: int = b["ikTargetIndex"]
		if eff < 0 or eff >= skeleton.get_bone_count():
			continue
		var links: Array = []
		for lk in b["ikLinks"]:
			var li: int = lk["linkIndex"]
			if li < 0 or li >= skeleton.get_bone_count():
				continue
			var has_limit: bool = lk["hasLimit"]
			var mn: Vector3 = lk["limitMin"]
			var mx: Vector3 = lk["limitMax"]
			if FLIP_Z and has_limit:
				# 镜像 S=diag(1,1,-1) 下欧拉角 (ex,ey,ez)→(-ex,-ey,ez)，
				# 故绕 X/Y 的区间取反并左右互换，绕 Z 的区间不变。
				var nmn := Vector3(-mx.x, -mx.y, mn.z)
				var nmx := Vector3(-mn.x, -mn.y, mx.z)
				mn = nmn
				mx = nmx
			# 对齐 ik-solver.ts buildIKChains：逐分量排序，保证 min<=max（限位钳位的前提）
			var smn := Vector3(minf(mn.x, mx.x), minf(mn.y, mx.y), minf(mn.z, mx.z))
			var smx := Vector3(maxf(mn.x, mx.x), maxf(mn.y, mx.y), maxf(mn.z, mx.z))
			var cls := _classify_link(smn, smx, has_limit)
			links.append({"index": li, "has_limit": has_limit, "min": smn, "max": smx,
				"axis": cls[0], "order": cls[1]})
		if links.size() == 0:
			continue
		# 単位角(ikUnitLength)：每次迭代的转角上限，第 li 节放宽到 単位角×(li+1)（对齐 ik-solver.ts:439）。
		# 注意不要再乘 4（之前抄 three.js 的写法），否则一次迭代转过头，链节来回过冲 → 关节抽搐/反折。
		var unit: float = b["ikUnitLength"]
		if unit <= 0.0:
			unit = PI
		ik_chains.append({"goal": i, "eff": eff, "links": links,
			"loops": maxi(int(b["ikLoopCount"]), 1), "unit": unit, "name": b["name"]})
		var axis_txt := ""
		for lk2 in links:
			axis_txt += "%s(%s/%s) " % [skeleton.get_bone_name(lk2["index"]),
				_axis_name(lk2["axis"]), _order_name(lk2["order"])]
		print("[VMDPlayer]   IK[%s] 末端=%s 迭代=%d 単位角=%.2f° 链=%s"
			% [b["name"], pmx_bones[eff]["name"], ik_chains[-1]["loops"], rad_to_deg(unit), axis_txt])


func _axis_name(a: int) -> String:
	if a == SA_FIXED:
		return "固定"
	if a == SA_X:
		return "仅X"
	if a == SA_Y:
		return "仅Y"
	if a == SA_Z:
		return "仅Z"
	return "自由"


func _order_name(o: int) -> String:
	if o == EO_YXZ:
		return "YXZ"
	if o == EO_ZYX:
		return "ZYX"
	return "XZY"


# 判定链节的"可解轴"与限位钳位用的欧拉序（1:1 对齐 ik-solver.ts classifyLink）。
# 这一步是膝盖不反折的关键：ひざ 的限位只在 X 上非零 → 归类为"仅X"，
# 反解时强制只绕父空间的 X 轴转，CCD 就不会把膝盖往侧面/后面掰。
func _classify_link(mn: Vector3, mx: Vector3, has_limit: bool) -> Array:
	var sa := SA_NONE
	var eo := EO_XZY
	if has_limit:
		var zx: bool = is_zero_approx(mn.x) and is_zero_approx(mx.x)
		var zy: bool = is_zero_approx(mn.y) and is_zero_approx(mx.y)
		var zz: bool = is_zero_approx(mn.z) and is_zero_approx(mx.z)
		if zx and zy and zz:
			sa = SA_FIXED
		elif zy and zz:
			sa = SA_X
		elif zx and zz:
			sa = SA_Y
		elif zx and zy:
			sa = SA_Z
		# 欧拉序要让"被限制得最窄的轴"落在中间位置，避免钳位时被万向锁扭曲
		if -HALF_PI < mn.x and mx.x < HALF_PI:
			eo = EO_YXZ
		elif -HALF_PI < mn.y and mx.y < HALF_PI:
			eo = EO_ZYX
		else:
			eo = EO_XZY
	return [sa, eo]


# 付与親(grant)：本骨骼额外继承来源骨骼的"动画量 × 比率"。
# 对齐 skeleton.ts updateWorldMatrices：付与親不写进 _local_rot，而是在合成最终局部变换时叠加，
# 这样它永远读到来源骨"含 IK 的当前动画量"，也不会逐帧累加。
func _build_append() -> void:
	for i in mini(pmx_bones.size(), _ap_src.size()):
		var b: Dictionary = pmx_bones[i]
		var src: int = b["appendParentIndex"]
		if src < 0 or src >= _ap_src.size():
			continue
		var f := 0
		if b["appendRotate"]:
			f |= 1
		if b["appendMove"]:
			f |= 2
		if f == 0:
			continue
		_ap_src[i] = src
		_ap_ratio[i] = b["appendRatio"]
		_ap_flags[i] = f


func _append_count() -> int:
	var c := 0
	for i in _ap_src.size():
		if _ap_src[i] >= 0:
			c += 1
	return c


func _build_morph_cache() -> void:
	if mesh == null or morph_targets.is_empty():
		return
	var slot_of := {}
	for i in mesh.get_blend_shape_count():
		slot_of[VMDLoader.normalize_bone_name(String(mesh.get_blend_shape_name(i)))] = i
	_slot_weight.resize(mesh.get_blend_shape_count())
	_slot_last.resize(mesh.get_blend_shape_count())
	_slot_last.fill(0.0)     # Godot 里 blend shape 初值就是 0，与之对齐

	# PMX morph 名 -> 索引（组 morph 内部按索引引用子 morph，按索引解析比按名字更稳）
	var idx_of := {}
	for i in pmx_morphs.size():
		idx_of[VMDLoader.normalize_bone_name(String(pmx_morphs[i]["name"]))] = i

	var missing: Array = []
	var unsupported: Array = []
	var expanded := 0
	for mname in vmd["morph_tracks"].keys():
		var route: Array = []
		if idx_of.has(mname):
			route = _resolve_morph(idx_of[mname], 1.0, slot_of, 0)
			if route.size() > 1:
				expanded += 1
			elif route.is_empty():
				# 模型里有这个 morph，但类型不是顶点/组（骨骼 morph、材质 morph 等）
				unsupported.append("%s(type%d)" % [mname, int(pmx_morphs[idx_of[mname]]["type"])])
		elif slot_of.has(mname):
			route = [{"slot": int(slot_of[mname]), "ratio": 1.0}]   # 无 PMX morph 表时的退路
		else:
			missing.append(mname)
		if not route.is_empty():
			morph_route[mname] = route
	matched_morphs = morph_route.size()
	if expanded > 0:
		print("[VMDPlayer] 组morph展开: %d 条轨映射到多个 blend shape" % expanded)
	if unsupported.size() > 0:
		print("[VMDPlayer] %d 条表情轨类型暂不支持(已忽略): %s" % [unsupported.size(), unsupported])
	if missing.size() > 0:
		print("[VMDPlayer] %d 条表情轨模型里没有(已忽略): %s%s"
			% [missing.size(), missing.slice(0, 6), " ..." if missing.size() > 6 else ""])


# 把一个 PMX morph 解析成「blend shape 槽位 + 权重比率」列表。
#   type1 顶点 morph → 它自己就是一个 blend shape，直接返回。
#   type0 组  morph → 递归展开子 morph，比率连乘（本模型全是「左+右」、ratio=1.0）。
#   其它类型（骨骼/UV/材质 morph）→ 返回空，调用方记为“暂不支持”。
# depth 限深防止组 morph 互相引用形成死循环。
func _resolve_morph(mi: int, ratio: float, slot_of: Dictionary, depth: int) -> Array:
	if depth > 4 or mi < 0 or mi >= pmx_morphs.size():
		return []
	var mo: Dictionary = pmx_morphs[mi]
	var mt: int = mo["type"]
	if mt == 1:
		var nm := VMDLoader.normalize_bone_name(String(mo["name"]))
		if slot_of.has(nm):
			return [{"slot": int(slot_of[nm]), "ratio": ratio}]
		return []
	if mt != 0:
		return []
	var out: Array = []
	for off in mo["offsets"]:
		out.append_array(_resolve_morph(int(off["morphIndex"]),
			ratio * float(off["ratio"]), slot_of, depth + 1))
	return out


func _compute_duration() -> void:
	duration = 0.0
	for key in ["bone_tracks", "morph_tracks"]:
		for tk in vmd[key].keys():
			var arr: Array = vmd[key][tk]
			if arr.size() > 0:
				var last: float = float(arr[arr.size() - 1]["frame"]) / vmd["fps"]
				if last > duration:
					duration = last


# ---------------- 主循环 ----------------

func _process(delta: float) -> void:
	if skeleton == null or vmd.is_empty():
		return
	if playing:
		time += delta * speed
		if duration > 0.0 and time > duration:
			if loop:
				time = fmod(time, duration)
				_cursor.clear()
				# 循环回到开头：骨骼位姿会大跳变，让物理立刻吸附而不是插值追赶。
				# 只置标志，实际 reset 放在 flush 之后（那时骨骼已是新一帧动画位姿）。
				_need_phys_reset = true
			else:
				time = duration
				playing = false
	# 每帧从 rest 重建局部变换（不做增量累加，杜绝 IK/付与親 逐帧漂移）
	_apply_bones()
	_update_world_all()
	if ik_enabled:
		_apply_ik()
		_update_world_all()      # 让付与親读到 IK 之后的来源骨
	_flush_to_skeleton()
	# 物理：读取本帧（已 flush 的）骨骼局部位姿 -> C++ 求解 -> 把动态刚体对应骨骼写回。
	# 物理内部状态跨帧保留，故每帧在动画位姿之上叠加二次运动（头发/裙子的自然摆动）。
	if _physics != null and _physics.is_ready():
		if _need_phys_reset:
			_physics.reset(skeleton)
			_need_phys_reset = false
		_physics.step_frame(skeleton, delta)
	if morph_enabled:
		_apply_morphs()


# 由 mmd_importer 在装配动作时调用：把编译好的物理世界挂到播放器上。
func set_physics(p: MMDPhysicsGD) -> void:
	_physics = p


func _apply_bones() -> void:
	for i in _local_rot.size():
		_local_pos[i] = _bind_pos[i]
		_local_rot[i] = Quaternion.IDENTITY
		_ik_rot[i] = Quaternion.IDENTITY
	var ft: float = time * vmd["fps"]
	for bname in bone_cache.keys():
		var idx: int = bone_cache[bname]
		var r := _sample_bone(bname, vmd["bone_tracks"][bname], ft)
		var pos: Vector3 = r[0]
		var rot: Quaternion = r[1]
		if FLIP_Z:
			pos = Vector3(pos.x, pos.y, -pos.z)
			rot = Quaternion(-rot.x, -rot.y, rot.z, rot.w)
		_local_pos[idx] = _bind_pos[idx] + pos
		_local_rot[idx] = rot.normalized()


# 返回 [位移, 旋转]（GDScript 没有引用出参，用小数组返回最省事）
func _sample_bone(nm: String, arr: Array, ft: float) -> Array:
	var n := arr.size()
	if n == 0:
		return [Vector3.ZERO, Quaternion.IDENTITY]
	if n == 1 or ft <= float(arr[0]["frame"]):
		return [arr[0]["pos"], arr[0]["rot"]]
	if ft >= float(arr[n - 1]["frame"]):
		return [arr[n - 1]["pos"], arr[n - 1]["rot"]]
	var i: int = _seek(nm, arr, ft)
	var a: Dictionary = arr[i - 1]
	var b: Dictionary = arr[i]
	var span := float(b["frame"] - a["frame"])
	var t := 0.0 if span <= 0.0 else (ft - float(a["frame"])) / span
	var ip: PackedByteArray = a["interp"]
	# MMD 的 64 字节插值表按"通道交错"存：通道 c(0=X,1=Y,2=Z,3=旋转) 的控制点是
	#   x1=ip[c], y1=ip[c+4], x2=ip[c+8], y2=ip[c+12]（值域 0..127）
	var px := _bez_ch(ip, 0, t)
	var py := _bez_ch(ip, 1, t)
	var pz := _bez_ch(ip, 2, t)
	var pr := _bez_ch(ip, 3, t)
	var ap: Vector3 = a["pos"]
	var bp: Vector3 = b["pos"]
	var pos := Vector3(lerp(ap.x, bp.x, px), lerp(ap.y, bp.y, py), lerp(ap.z, bp.z, pz))
	var rot: Quaternion = (a["rot"] as Quaternion).slerp(b["rot"], pr)
	return [pos, rot]


# 关键帧游标：动画顺序播放时几乎总是命中相邻帧，避免每帧线性扫全轨
func _seek(nm: String, arr: Array, ft: float) -> int:
	var n := arr.size()
	var i: int = _cursor.get(nm, 1)
	i = clamp(i, 1, n - 1)
	while i > 1 and float(arr[i - 1]["frame"]) > ft:
		i -= 1
	while i < n - 1 and float(arr[i]["frame"]) < ft:
		i += 1
	_cursor[nm] = i
	return i


func _bez_ch(ip: PackedByteArray, ch: int, t: float) -> float:
	if ip.size() < 16:
		return t
	var x1 := float(ip[ch]) / 127.0
	var y1 := float(ip[ch + 4]) / 127.0
	var x2 := float(ip[ch + 8]) / 127.0
	var y2 := float(ip[ch + 12]) / 127.0
	# 线性(20,20,107,107 之类)时直接返回，省掉牛顿迭代
	if is_equal_approx(x1, y1) and is_equal_approx(x2, y2):
		return t
	return _solve_bezier(t, x1, x2, y1, y2)


func _solve_bezier(x: float, x1: float, x2: float, y1: float, y2: float) -> float:
	var s := x
	for _k in 8:
		var bx := _bez(s, 0.0, x1, x2, 1.0) - x
		if absf(bx) < 1e-5:
			break
		var d := _bez_deriv(s, 0.0, x1, x2, 1.0)
		if absf(d) < 1e-6:
			break
		s = clampf(s - bx / d, 0.0, 1.0)
	return _bez(s, 0.0, y1, y2, 1.0)


func _bez(s: float, p0: float, p1: float, p2: float, p3: float) -> float:
	var u := 1.0 - s
	return u * u * u * p0 + 3.0 * u * u * s * p1 + 3.0 * u * s * s * p2 + s * s * s * p3


func _bez_deriv(s: float, p0: float, p1: float, p2: float, p3: float) -> float:
	var u := 1.0 - s
	return 3.0 * u * u * (p1 - p0) + 6.0 * u * s * (p2 - p1) + 3.0 * s * s * (p3 - p2)


# ---------------- 骨骼世界变换（自维护）----------------

# 合成"最终局部变换" = IK增量 × VMD动画 ，再叠加付与親。
# 对齐 skeleton.ts updateWorldMatrices(126-189) 与 ik-solver.ts updateBoneWorld(190-267)。
func _compose_local(i: int) -> void:
	var r: Quaternion = (_ik_rot[i] as Quaternion) * (_local_rot[i] as Quaternion)
	var p: Vector3 = _local_pos[i]
	var src: int = _ap_src[i]
	if append_enabled and src >= 0:
		var ratio: float = _ap_ratio[i]
		var ar := absf(ratio)
		if ar > 1e-6:
			var f: int = _ap_flags[i]
			if f & 1:
				# 来源骨的动画量（含它自己的 IK）。MMD 的 rest 旋转为单位，故局部旋转即动画量。
				var sq: Quaternion = ((_ik_rot[src] as Quaternion) * (_local_rot[src] as Quaternion)).normalized()
				if ratio < 0.0:
					sq = Quaternion(-sq.x, -sq.y, -sq.z, sq.w)   # 负比率 = 反向继承
				# 按比率插值出"部分继承"，再【左乘】到本骨旋转上（对齐 skeleton.ts:156 的 s*r）
				r = Quaternion.IDENTITY.slerp(sq, ar) * r
			if f & 2:
				p += (_local_pos[src] - _bind_pos[src]) * ratio
	_eff_rot[i] = r
	_eff_pos[i] = p


func _update_bone_world(i: int) -> void:
	_compose_local(i)
	var lt := Transform3D(Basis(_eff_rot[i] as Quaternion), _eff_pos[i])
	var p: int = _parent[i]
	if p >= 0:
		_world[i] = (_world[p] as Transform3D) * lt
	else:
		_world[i] = lt


func _update_world_all() -> void:
	for k in _order.size():
		_update_bone_world(_order[k])


func _flush_to_skeleton() -> void:
	# _eff_* 已由 _update_world_all 算好（含付与親），直接作为绝对局部 pose 写回
	for i in _eff_rot.size():
		skeleton.set_bone_pose_position(i, _eff_pos[i])
		skeleton.set_bone_pose_rotation(i, _eff_rot[i] as Quaternion)


# ---------------- IK（MMD 式 CCD，AfterglowWeb 1:1 移植）----------------

func _apply_ik() -> void:
	var dbg := not _ik_logged
	for ci in ik_chains.size():
		_solve_chain(ik_chains[ci], dbg and ci < 2)
	_ik_logged = true


# 与之前"朴素 CCD"的 4 个关键差异（正是关节反折+拉长的根因）：
#  1. 旋转轴所在空间：增量必须表达在【父骨空间】才能左乘到局部旋转上。
#     之前把轴算在"链节自身空间"却仍然左乘 → 空间与乘序不匹配 → 绕错轴，关节被扭出反折，
#     蒙皮在两根朝向差异极大的骨之间插值就被抽成尖刺（看起来像"拉长"）。
#  2. 受限链节(膝盖)在前半程强制只绕单一坐标轴转（solveAxis），否则 CCD 会先把膝盖往侧面掰，
#     事后再钳位也救不回来。
#  3. 限位钳位要按 classifyLink 选出的欧拉序做，并用"反射"式钳位(2*min-angle)让角度弹回可行区间，
#     直接 clamp 会把关节死死顶在边界上并反复过冲。
#  4. 单次迭代转角上限 = 単位角×(li+1)，不能统一乘 4。
func _solve_chain(ch: Dictionary, dbg: bool) -> void:
	var tgt: int = ch["goal"]
	var eff: int = ch["eff"]
	var links: Array = ch["links"]
	var iters: int = ch["loops"]
	var unit: float = ch["unit"]

	for lk in links:
		_ik_rot[lk["index"]] = Quaternion.IDENTITY
	# links[0] 最靠末端、links[last] 最靠根：按"根→末端"顺序刷新世界变换
	for i in range(links.size() - 1, -1, -1):
		_update_bone_world(links[i]["index"])
	_update_bone_world(eff)

	var d0 := (_world[tgt] as Transform3D).origin.distance_to((_world[eff] as Transform3D).origin)
	if d0 < IK_EPS:
		return

	var half := iters >> 1
	for it in iters:
		# 前半程用"单轴强约束"把关节推进可行方向，后半程放开做精修（对齐 ik-solver.ts:379）
		var use_axis := it < half
		for li in links.size():
			var lk: Dictionary = links[li]
			var sa: int = lk["axis"]
			if sa == SA_FIXED:
				continue
			var b: int = lk["index"]
			var cpos: Vector3 = (_world[b] as Transform3D).origin
			var d_eff: Vector3 = cpos - (_world[eff] as Transform3D).origin
			var d_tgt: Vector3 = cpos - (_world[tgt] as Transform3D).origin
			var le := d_eff.length()
			var lt := d_tgt.length()
			if le < IK_EPS or lt < IK_EPS:
				continue
			d_eff /= le
			d_tgt /= lt
			var ax_w: Vector3 = d_eff.cross(d_tgt)
			if ax_w.length() < IK_EPS:
				continue
			ax_w = ax_w.normalized()

			var p: int = _parent[b]
			var axis: Vector3
			if lk["has_limit"] and use_axis and sa >= SA_X:
				# 差异 2：强制单轴。取父骨世界基的对应列做同向性判定，决定 ±。
				var pax: Vector3
				if p >= 0:
					match sa:
						SA_X: pax = (_world[p] as Transform3D).basis.x
						SA_Y: pax = (_world[p] as Transform3D).basis.y
						SA_Z: pax = (_world[p] as Transform3D).basis.z
						_: pax = Vector3.ZERO
				else:
					pax = Vector3(1.0 if sa == SA_X else 0.0, 1.0 if sa == SA_Y else 0.0,
						1.0 if sa == SA_Z else 0.0)
				var sgn := 1.0 if ax_w.dot(pax) >= 0.0 else -1.0
				axis = Vector3(sgn if sa == SA_X else 0.0, sgn if sa == SA_Y else 0.0,
					sgn if sa == SA_Z else 0.0)
			else:
				# 差异 1：世界轴 → 父骨局部空间（父基正交，转置即逆），这样才能左乘到局部旋转上
				if p >= 0:
					axis = ((_world[p] as Transform3D).basis.transposed() * ax_w).normalized()
				else:
					axis = ax_w

			# 防御：万一轴仍为零（理论上不应再发生），跳过并报警，绝不触发 Godot 的 C++ 断言崩溃
			if axis.length() < IK_EPS:
				push_warning("[VMDPlayer] IK 零轴跳过 bone=%s use_axis=%s has_limit=%s sa=%d"
					% [skeleton.get_bone_name(b), use_axis, lk["has_limit"], sa])
				continue
			var dt := clampf(d_eff.dot(d_tgt), -1.0, 1.0)
			var ang := minf(unit * float(li + 1), acos(dt))     # 差异 4
			if ang < 1e-7:
				continue
			var acc: Quaternion = Quaternion(axis, ang) * (_ik_rot[b] as Quaternion)

			if lk["has_limit"]:
				# 差异 3：在"IK增量 × 动画旋转"的合成旋转上按指定欧拉序钳位，再还原成纯增量
				var full: Quaternion = acc * (_local_rot[b] as Quaternion)
				var e := _extract_euler(full.normalized(), lk["order"])
				var mn: Vector3 = lk["min"]
				var mx: Vector3 = lk["max"]
				e.x = _limit_angle(e.x, mn.x, mx.x, use_axis)
				e.y = _limit_angle(e.y, mn.y, mx.y, use_axis)
				e.z = _limit_angle(e.z, mn.z, mx.z, use_axis)
				acc = _euler_to_quat(e, lk["order"]) * (_local_rot[b] as Quaternion).inverse()
			_ik_rot[b] = acc.normalized()

			# 只重算被影响的那一小段（li→0 是"根→末端"方向）+ 末端骨
			for ui in range(li, -1, -1):
				_update_bone_world(links[ui]["index"])
			_update_bone_world(eff)

		if (_world[tgt] as Transform3D).origin.distance_to((_world[eff] as Transform3D).origin) < IK_DONE:
			break

	# 把 IK 增量固化进局部旋转（增量清零，避免 _compose_local 里重复叠加）
	for lk in links:
		var b2: int = lk["index"]
		var q: Quaternion = _ik_rot[b2]
		if absf(q.x) + absf(q.y) + absf(q.z) < 1e-8:
			continue
		_local_rot[b2] = ((q * (_local_rot[b2] as Quaternion)) as Quaternion).normalized()
		_ik_rot[b2] = Quaternion.IDENTITY

	if dbg:
		var d1 := (_world[tgt] as Transform3D).origin.distance_to((_world[eff] as Transform3D).origin)
		print("[VMDPlayer] IK诊断[%s] 距离 %.4f → %.4f (阈值%.2f)" % [ch["name"], d0, d1, IK_DONE])


# 从四元数取欧拉角（指定旋转序），对齐 ik-solver.ts extractEuler。
# Godot 的 Basis 用 get_column(col)[row] 取 M[row][col]，避免行/列约定踩坑。
func _extract_euler(q: Quaternion, order: int) -> Vector3:
	var bs := Basis(q)
	var c0 := bs.x
	var c1 := bs.y
	var c2 := bs.z
	var m00 := c0.x
	var m10 := c0.y
	var m20 := c0.z
	var m01 := c1.x
	var m11 := c1.y
	var m21 := c1.z
	var m02 := c2.x
	var m12 := c2.y
	var m22 := c2.z
	var out := Vector3.ZERO
	if order == EO_YXZ:
		var rx := asin(clampf(-m12, -1.0, 1.0))
		if absf(rx) > EULER_LIMIT:
			rx = -EULER_LIMIT if rx < 0.0 else EULER_LIMIT
		out.x = rx
		out.y = atan2(m02, m22)
		out.z = atan2(m10, m11)
	elif order == EO_ZYX:
		var ry := asin(clampf(-m20, -1.0, 1.0))
		if absf(ry) > EULER_LIMIT:
			ry = -EULER_LIMIT if ry < 0.0 else EULER_LIMIT
		out.x = atan2(m21, m22)
		out.y = ry
		out.z = atan2(m10, m00)
	else:
		var rz := asin(clampf(-m01, -1.0, 1.0))
		if absf(rz) > EULER_LIMIT:
			rz = -EULER_LIMIT if rz < 0.0 else EULER_LIMIT
		out.x = atan2(m21, m11)
		out.y = atan2(m02, m00)
		out.z = rz
	return out


# 欧拉角 → 四元数（与 _extract_euler 同序），对齐 ik-solver.ts eulerToQuat
func _euler_to_quat(e: Vector3, order: int) -> Quaternion:
	if order == EO_YXZ:
		return (Quaternion(Vector3.UP, e.y) * Quaternion(Vector3.RIGHT, e.x)
			* Quaternion(Vector3.BACK, e.z)).normalized()
	if order == EO_ZYX:
		return (Quaternion(Vector3.BACK, e.z) * Quaternion(Vector3.UP, e.y)
			* Quaternion(Vector3.RIGHT, e.x)).normalized()
	return (Quaternion(Vector3.RIGHT, e.x) * Quaternion(Vector3.BACK, e.z)
		* Quaternion(Vector3.UP, e.y)).normalized()


# "反射式"限位（对齐 ik-solver.ts limitAngle）：超界时先尝试镜射回可行区间，
# 只有镜射后仍超界才硬钳到边界。直接 clamp 会让关节顶死在边界并反复过冲 → 抽搐。
func _limit_angle(a: float, mn: float, mx: float, use_axis: bool) -> float:
	if a < mn:
		var d := 2.0 * mn - a
		return d if (d <= mx and use_axis) else mn
	if a > mx:
		var d2 := 2.0 * mx - a
		return d2 if (d2 >= mn and use_axis) else mx
	return a


# ---------------- 表情 ----------------

func _apply_morphs() -> void:
	if morph_route.is_empty():
		return
	var ft: float = time * vmd["fps"]
	# 按槽位累加：多条 VMD 轨可能落到同一个 blend shape
	#（例：笑い 组展开成 ウィンク右+ウィンク，而这两个本身也各有独立轨）
	_slot_weight.fill(0.0)
	for mname in morph_route.keys():
		var w := _sample_morph(mname, vmd["morph_tracks"][mname], ft)
		if absf(w) < 0.0001:
			continue
		for r in morph_route[mname]:
			var s: int = r["slot"]
			_slot_weight[s] += w * float(r["ratio"])
	# 只把有变化的槽位写进 GPU（set_blend_shape_value 会把整个 mesh instance 标脏、
	# 触发一次 skeleton.glsl compute 重算，所以不能每帧无脑全写）
	for i in _slot_weight.size():
		var w := _slot_weight[i]
		if morph_clamp:
			w = clampf(w, 0.0, 1.0)
		if is_equal_approx(_slot_last[i], w):
			continue
		_slot_last[i] = w
		for t in morph_targets:
			if t != null:
				(t as MeshInstance3D).set_blend_shape_value(i, w)


func _sample_morph(nm: String, arr: Array, ft: float) -> float:
	var n := arr.size()
	if n == 0:
		return 0.0
	if n == 1 or ft <= float(arr[0]["frame"]):
		return arr[0]["weight"]
	if ft >= float(arr[n - 1]["frame"]):
		return arr[n - 1]["weight"]
	var i: int = _seek("M:" + nm, arr, ft)
	var a: Dictionary = arr[i - 1]
	var b: Dictionary = arr[i]
	var span := float(b["frame"] - a["frame"])
	if span <= 0.0:
		return a["weight"]
	# MMD 表情帧是线性插值（没有 bezier 控制点）
	return lerpf(a["weight"], b["weight"], (ft - float(a["frame"])) / span)


# ---------------- 外部控制 ----------------

func _reset_all_to_neutral() -> void:
	# 中立姿态 = 每根骨的 pose 设回它的 rest（pose 是绝对局部变换，设零会把骨骼塌到父原点）
	for i in _local_rot.size():
		_local_pos[i] = _bind_pos[i]
		_local_rot[i] = Quaternion.IDENTITY
		_ik_rot[i] = Quaternion.IDENTITY
	_update_world_all()
	_flush_to_skeleton()


func toggle_play() -> void:
	if not playing and duration > 0.0 and time >= duration and not loop:
		time = 0.0
	playing = not playing


func seek(t: float) -> void:
	time = clampf(t, 0.0, duration)
	_cursor.clear()


func rewind_to_start() -> void:
	seek(0.0)


func clear_all_morphs() -> void:
	for i in _slot_last.size():
		_slot_last[i] = 0.0
		for t in morph_targets:
			if t != null:
				(t as MeshInstance3D).set_blend_shape_value(i, 0.0)


# 回到 T-Pose / 静止姿态（关掉播放时想看原始站姿）
func reset_to_rest() -> void:
	playing = false
	_reset_all_to_neutral()
	clear_all_morphs()
