extends SceneTree

# 量化【绑定姿态】下刚体的互相穿插情况。
#
# A/B 隔离已证明：零重力下的指数爆炸来自"碰撞接触"，不是关节。
# 那么要么 (a) bind 姿态本来就深度穿插（数据/语义问题），
#        要么 (b) 穿插很浅但接触求解器反应过度。
# 本脚本用 PMX 原始刚体数据（position/rotation 就是 MMD 世界坐标）算：
#   1) 通过 group/mask 过滤后的碰撞对数量
#   2) 用"包围球"近似估算穿插深度（快速、保守）
#   3) 列出最深的若干对，附形状/尺寸/组/掩码，判断是不是该碰的碰了

func _bounding_radius(shape: int, sz: Vector3) -> float:
	match shape:
		0:  # 球：size.x = 半径
			return sz.x
		1:  # 盒：size = 半边长
			return sz.length()
		2:  # 胶囊：size.x = 半径, size.y = 圆柱段高
			return sz.x + sz.y * 0.5
	return sz.x


func _shape_name(shape: int) -> String:
	match shape:
		0: return "球"
		1: return "盒"
		2: return "胶囊"
	return "?"


func _initialize() -> void:
	var loader := PMXLoader.new()
	var model := loader.parse("res://models/model.pmx")
	if model.is_empty():
		printerr("PMX parse failed")
		quit(1)
		return

	var rbs: Array = model["rigidbodies"]
	var joints: Array = model["joints"]
	var n := rbs.size()
	print("刚体=%d 关节=%d" % [n, joints.size()])

	# 关节连接关系（用于判断"该不该排除"）
	var linked := {}
	for j in joints:
		var a: int = (j as Dictionary)["rigidbodyA"]
		var b: int = (j as Dictionary)["rigidbodyB"]
		if a < 0 or b < 0:
			continue
		linked[str(min(a, b)) + "_" + str(max(a, b))] = true

	# 预算每个刚体的组位、掩码、包围球半径、世界位置、是否动态
	var grp := PackedInt32Array(); grp.resize(n)
	var msk := PackedInt32Array(); msk.resize(n)
	var rad := PackedFloat32Array(); rad.resize(n)
	var dyn := PackedInt32Array(); dyn.resize(n)
	var pos: Array = []; pos.resize(n)
	for i in n:
		var rb: Dictionary = rbs[i]
		grp[i] = 1 << (int(rb["group"]) & 0xf)
		msk[i] = int(rb["collisionMask"]) & 0xffff
		rad[i] = _bounding_radius(int(rb["shape"]), rb["size"] as Vector3)
		# 端口里 invMass>0 的条件：type != 0（静态）且 mass > 0
		dyn[i] = 1 if (int(rb["type"]) != 0 and float(rb["mass"]) > 0.0) else 0
		pos[i] = rb["position"] as Vector3

	var pair_count := 0
	var overlap_count := 0
	var linked_overlap := 0
	var max_pen := 0.0
	var rows: Array = []
	for i in n:
		for j in range(i + 1, n):
			if dyn[i] == 0 and dyn[j] == 0:
				continue
			if (msk[i] & grp[j]) == 0 or (msk[j] & grp[i]) == 0:
				continue
			pair_count += 1
			var d := (pos[i] as Vector3).distance_to(pos[j] as Vector3)
			var sumr := rad[i] + rad[j]
			var pen := sumr - d
			if pen > 0.0:
				overlap_count += 1
				var is_linked: bool = linked.has(str(i) + "_" + str(j))
				if is_linked:
					linked_overlap += 1
				if pen > max_pen:
					max_pen = pen
				rows.append({"i": i, "j": j, "pen": pen, "d": d, "sumr": sumr, "lk": is_linked})

	print("── 通过 group/mask 过滤的碰撞对 = %d" % pair_count)
	print("── 其中 bind 姿态就【包围球相交】的 = %d（占 %.1f%%）" % [
		overlap_count, 100.0 * float(overlap_count) / max(1.0, float(pair_count))])
	print("── 相交对里【被关节连接】的 = %d（MMD/Bullet 惯例：关节连接的刚体应禁用互碰）" % linked_overlap)
	print("── 最大近似穿插深度 = %.3f" % max_pen)

	rows.sort_custom(func(a, b): return a["pen"] > b["pen"])
	print("── 穿插最深的 15 对：")
	for k in min(15, rows.size()):
		var r: Dictionary = rows[k]
		var i: int = r["i"]
		var j: int = r["j"]
		var ri: Dictionary = rbs[i]
		var rj: Dictionary = rbs[j]
		print("   pen=%.3f (dist=%.3f, sumR=%.3f) %s | %s[%s r=%.2f g=%d m=0x%04x] <-> %s[%s r=%.2f g=%d m=0x%04x]" % [
			r["pen"], r["d"], r["sumr"], "关节连接" if r["lk"] else "无关节",
			ri["name"], _shape_name(int(ri["shape"])), rad[i], int(ri["group"]), msk[i],
			rj["name"], _shape_name(int(rj["shape"])), rad[j], int(rj["group"]), msk[j]])

	# 顺带看看组的分布，判断作者有没有正确分组
	var per_group := {}
	for i in n:
		var g: int = int((rbs[i] as Dictionary)["group"])
		per_group[g] = int(per_group.get(g, 0)) + 1
	print("── 刚体按 group 分布：%s" % str(per_group))

	print("DONE")
	quit(0)
