# mmd_physics.gd — MMD 物理系统 Godot 运行时接入层
#
# 把 AfterglowWeb 的 reze 物理（已忠实直译为 C++ GDExtension：mmd_phys_ext）
# 接到 Godot 的 Skeleton3D 上，驱动头发/裙子等刚体。
#
# ───────────────────────────────────────────────────────────────────────
# 坐标系约定（很容易错，务必读）：
#   1) C++ 内核（忠实直译 AfterglowWeb）在【MMD 原始（未镜像）空间】跑物理，
#      刚体/关节数据原样传入（不翻），和 AfterglowWeb 完全一致。
#   2) 但 Godot 这边的骨骼 rest 被 mmd_builder 做了 FLIP_Z（z -> -z）镜像，
#      是【已镜像（Godot 右手）空间】。所以边界处只翻骨骼 world 矩阵：
#         - 喂给物理前：把 Godot 全局位姿 UNFLIP（z 取反）→ MMD 空间
#         - 物理返回后：把 MMD 空间结果 FLIP 回 Godot 空间再写骨
#      刚体/关节数据【不翻】，由 C++ 在 MMD 空间内统一处理（与原版一致）。
#      这样彻底避免"刚体/关节旋转镜像规则猜错"导致系统性偏移。
#   3) C++ 内核用【列主序】4x4（gl-matrix 约定，平移在 [12],[13],[14]），
#      Godot Transform3D 的 basis.x/y/z 也是三个列向量 → 列主序 slot 直接一一对应，
#      打包/解包【不要转置】（_pack_tf/_unpack_tf）。详见下方"矩阵打包/解包"注释。
# ───────────────────────────────────────────────────────────────────────

class_name MMDPhysicsGD
extends RefCounted

const EXT_PATH := "res://addons/mmd_phys_ext/mmd_phys_ext.gdextension"

var _phys: RefCounted = null            # MMDPhysics3D 实例
var _bone_count: int = 0
var _driven_bones: PackedInt32Array = PackedInt32Array()  # 被物理改写的骨骼索引（动态刚体）
var _rest_invbind: PackedFloat32Array = PackedFloat32Array()  # bone_count*16，静止逆绑定（行主序）
var _loaded: bool = false


func _ensure_loaded() -> void:
	if _loaded:
		return
	# 无头模式下 Godot 不会自动扫描 .gdextension（编辑器 F5 会），这里显式加载。
	if not ClassDB.class_exists("MMDPhysics3D"):
		var res := load(EXT_PATH)
		if res == null:
			push_error("MMDPhysicsGD: 无法加载扩展资源 %s" % EXT_PATH)
	_loaded = true


# ── 矩阵打包 / 解包：Transform3D <-> 列主序 16 float ──────────────────────
#
# ★ 约定（曾长期搞错，务必别再改回去）：C++ 内核是【列主序】（gl-matrix 约定），
#   不是行主序。两个铁证：
#     1) mathutil.h 的 mulArrays 索引模式与 gl-matrix mat4.multiply 逐字一致
#        （out[col*4+r] = a[r]*b[col*4] + a[r+4]*b[col*4+1] + ...）
#     2) mathutil.h 的 toQuat 用 x=(m[6]-m[9]) —— 标准公式是 x=R21-R12，
#        列主序下 m[6]=R21/m[9]=R12 才吻合；行主序会得到共轭（反向旋转）。
#   Godot 的 basis.x/y/z 就是三个【列】，所以列主序 slot [0..2]=第0列=basis.x，
#   直接一一对应，【不要转置】。
#   （历史 bug：早先按"行主序"转置了 3×3。绑定姿态下骨骼旋转都是单位矩阵，
#     转置无害，所以首帧完全正常；但刚体一转动，写回骨骼就变成反向旋转，
#     再喂回 C++ 形成正反馈 → 指数爆炸。）
func _pack_tf(t: Transform3D, out: PackedFloat32Array, off: int) -> void:
	out[off + 0]  = t.basis.x.x
	out[off + 1]  = t.basis.x.y
	out[off + 2]  = t.basis.x.z
	out[off + 3]  = 0.0
	out[off + 4]  = t.basis.y.x
	out[off + 5]  = t.basis.y.y
	out[off + 6]  = t.basis.y.z
	out[off + 7]  = 0.0
	out[off + 8]  = t.basis.z.x
	out[off + 9]  = t.basis.z.y
	out[off + 10] = t.basis.z.z
	out[off + 11] = 0.0
	out[off + 12] = t.origin.x
	out[off + 13] = t.origin.y
	out[off + 14] = t.origin.z
	out[off + 15] = 1.0


func _unpack_tf(a: PackedFloat32Array, off: int) -> Transform3D:
	var bx := Vector3(a[off + 0], a[off + 1], a[off + 2])
	var by := Vector3(a[off + 4], a[off + 5], a[off + 6])
	var bz := Vector3(a[off + 8], a[off + 9], a[off + 10])
	var o  := Vector3(a[off + 12], a[off + 13], a[off + 14])
	return Transform3D(Basis(bx, by, bz), o)


# FLIP_Z 反射（z -> -z）作用于 Transform3D。是对合（翻转两次复原）。
# 用于边界处把 Godot（已镜像）空间 <-> MMD（未镜像）空间互转。
func _flip_tf(t: Transform3D) -> Transform3D:
	var o := Vector3(t.origin.x, t.origin.y, -t.origin.z)
	# 反射 M = diag(1,1,-1)：B' = M B M  → 第2行取反、第2列（行0/1）取反。
	var bx := Vector3(t.basis.x.x, t.basis.x.y, -t.basis.x.z)
	var by := Vector3(t.basis.y.x, t.basis.y.y, -t.basis.y.z)
	var bz := Vector3(-t.basis.z.x, -t.basis.z.y, t.basis.z.z)
	return Transform3D(Basis(bx, by, bz), o)


# ── 初始化：从 PMX 解析出的刚体/关节建立物理世界 ─────────────────────────
func initialize(skeleton: Skeleton3D, rigidbodies: Array, joints: Array) -> void:
	_ensure_loaded()
	_bone_count = skeleton.get_bone_count()

	# 静止逆绑定矩阵（行主序），只在首帧被 C++ 使用，这里一次性预计算。
	_rest_invbind = PackedFloat32Array()
	_rest_invbind.resize(_bone_count * 16)
	for b in _bone_count:
		var rest := skeleton.get_bone_global_rest(b)
		# Unflip 到 MMD 原始空间（物理在 MMD 空间跑，刚体/关节不翻）。
		_pack_tf(_flip_tf(rest.affine_inverse()), _rest_invbind, b * 16)

	# 刚体打包（扁平数组，逐条对照 C++ unpack_rigidbodies）
	var n := rigidbodies.size()
	var rb_bone := PackedInt32Array();    rb_bone.resize(n)
	var rb_group := PackedInt32Array();   rb_group.resize(n)
	var rb_mask := PackedInt32Array();    rb_mask.resize(n)
	var rb_shape := PackedInt32Array();   rb_shape.resize(n)
	var rb_size := PackedFloat32Array();  rb_size.resize(n * 3)
	var rb_pos := PackedFloat32Array();   rb_pos.resize(n * 3)
	var rb_rot := PackedFloat32Array();   rb_rot.resize(n * 3)
	var rb_params := PackedFloat32Array(); rb_params.resize(n * 5)
	var rb_type := PackedInt32Array();    rb_type.resize(n)
	var rb_aligned := PackedInt32Array(); rb_aligned.resize(n)

	_driven_bones = PackedInt32Array()
	_driven_bones.resize(0)

	for i in n:
		var rb: Dictionary = rigidbodies[i]
		var bone_idx: int = rb["boneIndex"]
		rb_bone[i] = bone_idx
		rb_group[i] = rb["group"]
		rb_mask[i] = rb["collisionMask"]
		rb_shape[i] = rb["shape"]
		var sz: Vector3 = rb["size"]
		rb_size[i * 3 + 0] = sz.x
		rb_size[i * 3 + 1] = sz.y
		rb_size[i * 3 + 2] = sz.z
		# 刚体位置/旋转原样传入（MMD 原始空间，与 AfterglowWeb 一致，不翻）。
		var p: Vector3 = rb["position"]
		rb_pos[i * 3 + 0] = p.x
		rb_pos[i * 3 + 1] = p.y
		rb_pos[i * 3 + 2] = p.z
		var rot: Vector3 = rb["rotation"]
		rb_rot[i * 3 + 0] = rot.x
		rb_rot[i * 3 + 1] = rot.y
		rb_rot[i * 3 + 2] = rot.z
		rb_params[i * 5 + 0] = rb["mass"]
		rb_params[i * 5 + 1] = rb["linearDamping"]
		rb_params[i * 5 + 2] = rb["angularDamping"]
		rb_params[i * 5 + 3] = rb["restitution"]
		rb_params[i * 5 + 4] = rb["friction"]
		# PMX type -> 端口 type + aligned：
		#   0 -> Static(0), aligned=false
		#   1 -> Dynamic(1), aligned=false
		#   2 -> Dynamic(1), aligned=true
		var pmx_type: int = rb["type"]
		if pmx_type == 0:
			rb_type[i] = 0
			rb_aligned[i] = 0
		else:
			rb_type[i] = 1
			rb_aligned[i] = 1 if pmx_type == 2 else 0
		# 被物理改写的骨骼 = 动态刚体（端口 type==1）且绑定了骨骼
		if rb_type[i] == 1 and bone_idx >= 0:
			_driven_bones.append(bone_idx)

	# 关节打包
	var m := joints.size()
	var jt_a := PackedInt32Array();    jt_a.resize(m)
	var jt_b := PackedInt32Array();    jt_b.resize(m)
	var jt_pos := PackedFloat32Array();  jt_pos.resize(m * 3)
	var jt_rot := PackedFloat32Array();  jt_rot.resize(m * 3)
	var jt_posmin := PackedFloat32Array(); jt_posmin.resize(m * 3)
	var jt_posmax := PackedFloat32Array(); jt_posmax.resize(m * 3)
	var jt_rotmin := PackedFloat32Array(); jt_rotmin.resize(m * 3)
	var jt_rotmax := PackedFloat32Array(); jt_rotmax.resize(m * 3)
	var jt_spos := PackedFloat32Array();   jt_spos.resize(m * 3)
	var jt_srot := PackedFloat32Array();   jt_srot.resize(m * 3)
	for i in m:
		var j: Dictionary = joints[i]
		jt_a[i] = j["rigidbodyA"]
		jt_b[i] = j["rigidbodyB"]
		var P: Vector3 = j["position"]
		var R: Vector3 = j["rotation"]
		var PM: Vector3 = j["positionMin"]
		var PX: Vector3 = j["positionMax"]
		var RM: Vector3 = j["rotationMin"]
		var RX: Vector3 = j["rotationMax"]
		var SP: Vector3 = j["springPosition"]
		var SR: Vector3 = j["springRotation"]
		# 关节位置/旋转原样传入（MMD 原始空间，不翻）。
		jt_pos[i*3+0]=P.x; jt_pos[i*3+1]=P.y; jt_pos[i*3+2]=P.z
		jt_rot[i*3+0]=R.x; jt_rot[i*3+1]=R.y; jt_rot[i*3+2]=R.z
		jt_posmin[i*3+0]=PM.x; jt_posmin[i*3+1]=PM.y; jt_posmin[i*3+2]=PM.z
		jt_posmax[i*3+0]=PX.x; jt_posmax[i*3+1]=PX.y; jt_posmax[i*3+2]=PX.z
		jt_rotmin[i*3+0]=RM.x; jt_rotmin[i*3+1]=RM.y; jt_rotmin[i*3+2]=RM.z
		jt_rotmax[i*3+0]=RX.x; jt_rotmax[i*3+1]=RX.y; jt_rotmax[i*3+2]=RX.z
		jt_spos[i*3+0]=SP.x; jt_spos[i*3+1]=SP.y; jt_spos[i*3+2]=SP.z
		jt_srot[i*3+0]=SR.x; jt_srot[i*3+1]=SR.y; jt_srot[i*3+2]=SR.z

	# 建立物理世界
	if _phys == null:
		if not ClassDB.class_exists("MMDPhysics3D"):
			push_error("MMDPhysicsGD: MMDPhysics3D 类未注册（扩展加载失败？）")
			return
		_phys = ClassDB.instantiate("MMDPhysics3D")
	_phys.setup(
		rb_bone, rb_group, rb_mask, rb_shape, rb_size, rb_pos, rb_rot,
		rb_params, rb_type, rb_aligned,
		jt_a, jt_b, jt_pos, jt_rot, jt_posmin, jt_posmax,
		jt_rotmin, jt_rotmax, jt_spos, jt_srot)
	print("MMDPhysicsGD: 初始化完成 刚体=%d 关节=%d 受驱动骨骼=%d" % [n, m, _driven_bones.size()])


func set_gravity(gx: float, gy: float, gz: float) -> void:
	if _phys != null:
		_phys.set_gravity(gx, gy, gz)


func get_gravity() -> Vector3:
	if _phys != null:
		return _phys.get_gravity()
	return Vector3(0.0, -98.0, 0.0)


# P3 风系统：方向任意长度(内部归一化), strength==0 或 dir 全零=关风。
# turbulence/frequency 控制阵风（0=恒定风）。方向在世界空间：x=横向 y=上下 z=纵深。
func set_wind(dx: float, dy: float, dz: float, strength: float, turbulence: float, frequency: float) -> void:
	if _phys != null:
		_phys.set_wind(dx, dy, dz, strength, turbulence, frequency)


func get_wind() -> Dictionary:
	if _phys != null:
		return _phys.get_wind()
	return {}


# P3 可复现随机种子(顺序随机化)：默认 0, 与 P2b 之前行为一致。
# 设成固定非零值可让"同一场景每次跑得一模一样"（便于复现/调试抖动）。
func set_order_seed(p_seed: int) -> void:
	if _phys != null:
		_phys.set_order_seed(p_seed)


func get_order_seed() -> int:
	if _phys != null:
		return _phys.get_order_seed()
	return 0


func is_ready() -> bool:
	return _phys != null


# ── 每帧推进：读骨骼全局位姿 -> C++ 求解 -> 写回被驱动骨骼 ─────────────────
func step_frame(skeleton: Skeleton3D, dt: float) -> void:
	if _phys == null:
		return
	var n := skeleton.get_bone_count()
	if n == 0:
		return

	# 不依赖 get_bone_global_pose()：Godot 在某些时机下它返回的是缓存旧值，
	# 不会因 set_bone_pose 立即刷新。改为自己从【局部位姿】沿父链累乘出全局位姿
	# （PMX 骨骼保证 父索引 < 子索引，所以按 b 升序遍历父已先算好）。
	# 这与 VMDPlayer 的写法一致，且对任意调用时机都正确。
	var local_poses: Array = []
	local_poses.resize(n)
	var global_poses: Array = []
	global_poses.resize(n)
	for b in n:
		local_poses[b] = skeleton.get_bone_pose(b)
	for b in n:
		var p: int = skeleton.get_bone_parent(b)
		if p >= 0:
			global_poses[b] = (global_poses[p] as Transform3D) * (local_poses[b] as Transform3D)
		else:
			global_poses[b] = local_poses[b] as Transform3D

	# 打包成行主序数组（先 UNFLIP 到 MMD 空间：物理在 MMD 原始空间跑）。
	var bone_world := PackedFloat32Array()
	bone_world.resize(n * 16)
	for b in n:
		_pack_tf(_flip_tf(global_poses[b] as Transform3D), bone_world, b * 16)

	# 求解（out 是 bone_world 的副本，动态刚体对应骨骼被物理改写）
	var out: PackedFloat32Array = _phys.step(dt, bone_world, _rest_invbind)

	# 写回被物理驱动的骨骼：物理给的是【全局】位姿，转回【局部】再写。
	#
	# ★ 必须按【层级顺序】遍历，并用【更新后】的父骨全局位姿来换算局部位姿。
	#   PMX 保证 父索引 < 子索引，所以按 b 升序遍历天然满足"父先算好"。
	#   （历史 bug：早先用【物理前】的父骨全局位姿换算，父骨被物理改动后，
	#     子骨的局部位姿就是错的，误差沿骨链逐级累乘；又因为静态刚体以骨骼
	#     作为运动学目标，错误会反馈回物理，形成正反馈 → 指数爆炸。
	#     AfterglowWeb 直接写全局矩阵，不存在这一步，所以是移植特有的坑。）
	var is_driven := {}
	for db in _driven_bones:
		if db >= 0 and db < n:
			is_driven[db] = true
	var new_global: Array = []
	new_global.resize(n)
	for b in n:
		var p: int = skeleton.get_bone_parent(b)
		if is_driven.has(b):
			# 物理返回的是 MMD 空间全局位姿 -> FLIP 回 Godot 空间再转局部。
			var world_t := _flip_tf(_unpack_tf(out, b * 16))
			new_global[b] = world_t
			var local: Transform3D
			if p >= 0:
				local = (new_global[p] as Transform3D).affine_inverse() * world_t
			else:
				local = world_t
			skeleton.set_bone_pose(b, local)
		else:
			# 未被物理驱动的骨骼：保持原局部位姿，全局位姿随（可能已变的）父级更新。
			if p >= 0:
				new_global[b] = (new_global[p] as Transform3D) * (local_poses[b] as Transform3D)
			else:
				new_global[b] = local_poses[b] as Transform3D


# 动画大跳变（如循环回到开头）时调用，让物理立刻吸附到骨骼而不是插值追赶。
func reset(skeleton: Skeleton3D) -> void:
	if _phys == null:
		return
	var n := skeleton.get_bone_count()
	var global_poses: Array = []
	global_poses.resize(n)
	for b in n:
		var p: int = skeleton.get_bone_parent(b)
		if p >= 0:
			global_poses[b] = (global_poses[p] as Transform3D) * skeleton.get_bone_pose(b)
		else:
			global_poses[b] = skeleton.get_bone_pose(b)
	# 先 UNFLIP 到 MMD 空间（与 step_frame 一致）。
	var bone_world := PackedFloat32Array()
	bone_world.resize(n * 16)
	for b in n:
		_pack_tf(_flip_tf(global_poses[b] as Transform3D), bone_world, b * 16)
	_phys.reset(bone_world)
