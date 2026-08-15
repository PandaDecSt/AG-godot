extends SceneTree

# 物理"零重力仍漂移"的 A/B 隔离诊断。
#
# 前提事实（已确认）：C++ 内核六个模块（world/contact/solver/physics/body/constraint）
# 与 AfterglowWeb 的 TS 参考逐行一致；数据桥字段纯透传；shape 枚举与碰撞组掩码语义一致。
# 但在【重力=0 + 完美绑定姿态】下，骨骼仍从第 2 帧起指数式漂移（0.2→0.43→2.8→9.9→35）。
#
# 零重力 + 完美 bind 下唯一可能的推力来源只有两处：
#   (1) 关节约束（6DOF 弹簧/限位）
#   (2) 碰撞接触（刚体在 bind 姿态就互相穿插 → 位置修正猛推）
# 本脚本用纯 GDScript 逐一关掉它们，做四组对照：
#   A 全开        （基线，应复现漂移）
#   B 只留关节    （collisionMask 全置 0 → 无碰撞对）
#   C 只留接触    （joints 传空数组）
#   D 全关        （夹具自检，必须严格 0.00）
# 谁一关掉漂移就消失，元凶就是谁。

func _globals(skel: Skeleton3D) -> Array:
	var n := skel.get_bone_count()
	var g: Array = []
	g.resize(n)
	var lp: Array = []
	lp.resize(n)
	for i in n:
		lp[i] = skel.get_bone_pose(i)
	for i in n:
		var p := skel.get_bone_parent(i)
		if p >= 0:
			g[i] = (g[p] as Transform3D) * (lp[i] as Transform3D)
		else:
			g[i] = lp[i] as Transform3D
	return g


func _max_disp(skel: Skeleton3D, rest: Array) -> Array:
	var g := _globals(skel)
	var md := 0.0
	var name := ""
	var nonfinite := 0
	for b in g.size():
		var t := g[b] as Transform3D
		if not t.origin.is_finite():
			nonfinite += 1
			continue
		var d := t.origin.distance_to((rest[b] as Transform3D).origin)
		if d > md:
			md = d
			name = skel.get_bone_name(b)
	return [md, name, nonfinite]


# 复制刚体数组，可选把碰撞掩码清零（关掉全部碰撞对）
func _copy_rbs(rbs: Array, zero_mask: bool) -> Array:
	var out: Array = []
	for rb in rbs:
		var d: Dictionary = (rb as Dictionary).duplicate(true)
		if zero_mask:
			d["collisionMask"] = 0
		out.append(d)
	return out


func _run_case(model: Dictionary, tag: String, zero_mask: bool, drop_joints: bool, steps: int) -> void:
	# 每组都用全新的骨架 + 全新的物理实例，避免状态串味。
	var holder := Node.new()
	root.add_child(holder)
	var skel := Skeleton3D.new()
	holder.add_child(skel)
	var builder := MMDModelBuilder.new()
	builder._build_skeleton(skel, model)

	var rbs := _copy_rbs(model["rigidbodies"] as Array, zero_mask)
	var jts: Array = [] if drop_joints else (model["joints"] as Array)

	var phys := MMDPhysicsGD.new()
	phys.initialize(skel, rbs, jts)
	if not phys.is_ready():
		printerr("[%s] physics not ready" % tag)
		holder.queue_free()
		return
	phys.set_gravity(0.0, 0.0, 0.0)

	var rest := _globals(skel)
	var dt := 1.0 / 60.0
	var trace := ""
	for i in steps:
		phys.step_frame(skel, dt)
		if i < 8 or (i + 1) % 10 == 0:
			var r := _max_disp(skel, rest)
			trace += "f%d=%.3f " % [i + 1, r[0] as float]
	var fin := _max_disp(skel, rest)
	print("[%s] joints=%d mask0=%s | maxDisp=%.3f bone=%s nonFinite=%d" % [
		tag, jts.size(), str(zero_mask), fin[0] as float, fin[1] as String, fin[2] as int])
	print("      trace: " + trace)
	holder.queue_free()


func _initialize() -> void:
	var loader := PMXLoader.new()
	var model := loader.parse("res://models/model.pmx")
	if model.is_empty():
		printerr("PMX parse failed")
		quit(1)
		return
	print("PMX: bones=%d rigidbodies=%d joints=%d" % [
		(model["bones"] as Array).size(),
		(model["rigidbodies"] as Array).size(),
		(model["joints"] as Array).size()])
	print("=== 零重力 + 绑定姿态，30 步。谁关掉后 maxDisp 归零，谁就是元凶 ===")

	_run_case(model, "A 全开", false, false, 30)
	_run_case(model, "B 只留关节(无碰撞)", true, false, 30)
	_run_case(model, "C 只留接触(无关节)", false, true, 30)
	_run_case(model, "D 全关(夹具自检)", true, true, 30)

	print("DONE")
	quit(0)
