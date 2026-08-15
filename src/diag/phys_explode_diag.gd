extends SceneTree

# 物理爆炸诊断：逐帧扫全部骨骼，量化"面条/巨大面"从哪来。
#   Test 1：静止姿态下步进 150 帧物理，看内核是否稳定（排除 C++ 比例/offset 错误）。
#   Test 2：每帧移动根骨模拟动画运动，看是否出现全局爆炸（确认写入层级联 bug）。
# 每 15 帧打印一次全骨扫描：最大原点距离、最大位移、非有限骨数、爆炸骨清单。

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


func _scan(skel: Skeleton3D, rest: Array, tag: String) -> void:
	var g := _globals(skel)
	var n := g.size()
	var max_len := 0.0
	var max_disp := 0.0
	var nonfinite := 0
	var exploded: Array = []
	for b in n:
		var t := g[b] as Transform3D
		if not (t.origin.is_finite() and t.basis.x.is_finite() and t.basis.y.is_finite()):
			nonfinite += 1
			continue
		var L := t.origin.length()
		if L > max_len:
			max_len = L
		var d := t.origin.distance_to((rest[b] as Transform3D).origin)
		if d > max_disp:
			max_disp = d
		if L > 50.0 or d > 50.0:
			exploded.append("%d:%s(L=%.1f,d=%.1f)" % [b, skel.get_bone_name(b), L, d])
	var head := ""
	for k in min(exploded.size(), 6):
		head += str(exploded[k]) + " "
	var more := ""
	if exploded.size() > 6:
		for k in range(6, min(exploded.size(), 20)):
			more += str(exploded[k]) + " "
	print("[%s] bones=%d maxOriginLen=%.2f maxDisp=%.2f nonFinite=%d exploded=%d %s" % [
		tag, n, max_len, max_disp, nonfinite, exploded.size(), head])
	if nonfinite > 0 or exploded.size() > 0:
		if more != "":
			print("   more: " + more)


func _report_top(skel: Skeleton3D, rest: Array, tag: String, topn: int) -> void:
	var g := _globals(skel)
	var n := g.size()
	var rows: Array = []
	for b in n:
		var d := (g[b] as Transform3D).origin.distance_to((rest[b] as Transform3D).origin)
		rows.append({"b": b, "name": skel.get_bone_name(b), "d": d,
			"ox": (g[b] as Transform3D).origin.x, "oy": (g[b] as Transform3D).origin.y, "oz": (g[b] as Transform3D).origin.z})
	rows.sort_custom(func(a, b): return a["d"] > b["d"])
	print("[%s] top displacement bones:" % tag)
	for k in min(topn, rows.size()):
		var r := rows[k] as Dictionary
		print("   %d:%s d=%.2f pos=(%.1f,%.1f,%.1f)" % [r["b"], r["name"], r["d"], r["ox"], r["oy"], r["oz"]])


func _initialize() -> void:
	var loader := PMXLoader.new()
	var model := loader.parse("res://models/model.pmx")
	if model.is_empty():
		printerr("PMX parse failed"); quit(1)
	print("PMX: bones=%d rigidbodies=%d joints=%d" % [
		model["bones"].size(), model["rigidbodies"].size(), model["joints"].size()])

	var root_node := Node.new()
	root.add_child(root_node)
	var skel := Skeleton3D.new()
	root_node.add_child(skel)
	var builder := MMDModelBuilder.new()
	builder._build_skeleton(skel, model)
	print("skeleton bones=%d" % skel.get_bone_count())

	var phys := MMDPhysicsGD.new()
	phys.initialize(skel, model["rigidbodies"], model["joints"])
	if not phys.is_ready():
		printerr("physics not ready"); quit(1)

	var rest := _globals(skel)
	var rest_local: Array = []
	rest_local.resize(skel.get_bone_count())
	for b in skel.get_bone_count():
		rest_local[b] = skel.get_bone_pose(b)
	var dt := 1.0 / 60.0

	# ── Test 0：重力 0 静止步进（二分：爆炸是否来自 world.step 动力学）──
	print("=== Test 0: gravity=0 + 30 physics steps (isolates placement vs dynamics) ===")
	phys.set_gravity(0.0, 0.0, 0.0)
	for i in 30:
		phys.step_frame(skel, dt)
		if (i + 1) % 10 == 0:
			_scan(skel, rest, "g0#%d" % (i + 1))
			_report_top(skel, rest, "g0#%d-top" % (i + 1), 8)
	# 复位
	for b in skel.get_bone_count():
		skel.set_bone_pose(b, rest_local[b] as Transform3D)
	phys.reset(skel)
	phys.set_gravity(0.0, -98.0, 0.0)
	rest = _globals(skel)
	_report_top(skel, rest, "g0-top", 8)

	# ── Test 1：静止 ──
	print("=== Test 1: rest + 150 physics steps (core stability) ===")
	for i in 150:
		phys.step_frame(skel, dt)
		if (i + 1) % 15 == 0:
			_scan(skel, rest, "rest#%d" % (i + 1))
	_report_top(skel, rest, "rest-top", 8)

	# 复位到静止（用局部位姿，正确）
	for b in skel.get_bone_count():
		skel.set_bone_pose(b, rest_local[b] as Transform3D)
	phys.reset(skel)
	rest = _globals(skel)
	var root_bone := 0  # 通常 センター/Center，静态根

	# ── Test 2：每帧移动根骨模拟动画 ──
	print("=== Test 2: oscillate root bone + 150 physics steps (motion) ===")
	for i in 150:
		var pose := skel.get_bone_pose(root_bone)
		pose.origin += Vector3(0.0, 0.15 * sin(float(i) * 0.3), 0.0)
		pose = pose.rotated(Vector3(0, 1, 0), 0.02 * sin(float(i) * 0.2))
		skel.set_bone_pose(root_bone, pose)
		phys.step_frame(skel, dt)
		if (i + 1) % 15 == 0:
			_scan(skel, rest, "motion#%d" % (i + 1))

	print("DONE")
	quit(0)
