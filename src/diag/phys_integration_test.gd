extends Node

# 端到端无头验证：真实 PMX -> 骨架 -> MMDPhysicsGD 物理 -> 写回骨骼。
# 目标：证明整条链路跑通、step_frame 确实读动画位姿并改写骨骼、物理对骨架运动有响应。

func _global_of(skel: Skeleton3D, b: int) -> Transform3D:
	# 与 MMDPhysicsGD.step_frame 同款：从局部位姿沿父链累乘（不依赖缓存的全局位姿）。
	var g: Array = []
	g.resize(skel.get_bone_count())
	for i in g.size():
		var p := skel.get_bone_parent(i)
		if p >= 0:
			g[i] = (g[p] as Transform3D) * skel.get_bone_pose(i)
		else:
			g[i] = skel.get_bone_pose(i)
	return g[b] as Transform3D


func _ready() -> void:
	var loader := PMXLoader.new()
	var model := loader.parse("res://models/model.pmx")
	if model.is_empty():
		printerr("PMX parse failed")
		get_tree().quit(1)
		return
	print("PMX: bones=%d rigidbodies=%d joints=%d" % [
		model["bones"].size(), model["rigidbodies"].size(), model["joints"].size()])

	var skel := Skeleton3D.new()
	add_child(skel)
	var builder := MMDModelBuilder.new()
	builder._build_skeleton(skel, model)
	print("skeleton bones=%d" % skel.get_bone_count())

	var phys := MMDPhysicsGD.new()
	phys.initialize(skel, model["rigidbodies"], model["joints"])
	if not phys.is_ready():
		printerr("physics not ready")
		get_tree().quit(1)
		return

	# 选一个动态刚体对应的骨骼（端口 type==Dynamic），优先取有父骨的
	var db := -1
	for rb in model["rigidbodies"]:
		if rb["type"] != 0 and rb["boneIndex"] >= 0 and skel.get_bone_parent(rb["boneIndex"]) >= 0:
			db = rb["boneIndex"]
			break
	if db < 0:
		for rb in model["rigidbodies"]:
			if rb["type"] != 0 and rb["boneIndex"] >= 0:
				db = rb["boneIndex"]; break
	if db < 0:
		printerr("no dynamic rigidbody bone found")
		get_tree().quit(1)
		return

	var rest_global := _global_of(skel, db)
	print("driven bone %d name=%s parent=%d" % [db, skel.get_bone_name(db), skel.get_bone_parent(db)])
	print("  rest pos=(%.4f, %.4f, %.4f)" % [rest_global.origin.x, rest_global.origin.y, rest_global.origin.z])

	# 移动头骨（hair 的父骨）下移 3，模拟动画
	var head := skel.get_bone_parent(db)
	var head_pose := skel.get_bone_pose(head)
	head_pose.origin += Vector3(0, -3, 0)
	skel.set_bone_pose(head, head_pose)

	# 跑 90 帧物理
	var dt := 1.0 / 60.0
	for i in 90:
		phys.step_frame(skel, dt)

	var after := _global_of(skel, db)
	var finite := after.origin.is_finite() and after.basis.x.is_finite()
	var moved := after.origin.distance_to(rest_global.origin)
	print("  after 90 frames pos=(%.4f, %.4f, %.4f)" % [after.origin.x, after.origin.y, after.origin.z])
	print("  moved_from_rest=%.4f  finite=%s" % [moved, str(finite)])

	if not finite:
		printerr("PHYSICS_FAIL: non-finite bone transform")
		get_tree().quit(1)
	elif moved > 0.001:
		print("PHYSICS_OK: 物理链路跑通，骨骼位姿被物理改写")
		get_tree().quit(0)
	else:
		print("PHYSICS_WARN: 骨骼未变化")
		get_tree().quit(0)
