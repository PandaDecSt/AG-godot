extends SceneTree

# 验证 P3「默认风 + 种子」接线真正打通到 C++（不依赖渲染，F5 之外的无头通道）。
# 走与 mmd_importer.gd 完全相同的调用路径：MMDPhysicsGD.new() → initialize → set_wind → get_wind。

func _initialize() -> void:
	var loader := PMXLoader.new()
	var model := loader.parse("res://models/model.pmx")
	if model.is_empty():
		printerr("PMX parse failed")
		quit(1)
		return

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
		printerr("physics not ready")
		quit(1)
		return

	# ---- 1) 风：走与 mmd_importer.gd 相同的调用路径（数值取 6.0 仅为验证往返，非默认值）----
	phys.set_wind(1.0, 0.0, 0.0, 6.0, 0.25, 0.8)
	var w := phys.get_wind()
	print("get_wind -> %s" % w)
	var ok := true
	if abs(w["strength"] - 6.0) > 1e-3: ok = false
	if abs(w["turbulence"] - 0.25) > 1e-3: ok = false
	if abs(w["frequency"] - 0.8) > 1e-3: ok = false
	var d: Vector3 = w["direction"]
	if abs(d.x - 1.0) > 1e-3 or abs(d.y) > 1e-3 or abs(d.z) > 1e-3: ok = false
	if not ok:
		print("WIND_WIRE_FAIL: get_wind 返回值与 set_wind 不符")
		quit(1)

	# ---- 2) 风设为 0 = 关风 ----
	phys.set_wind(0, 0, 0, 0, 0, 0)
	var w0 := phys.get_wind()
	if abs(w0["strength"]) > 1e-3:
		print("WIND_WIRE_FAIL: 关风后 strength 应为 0，实际 %s" % w0["strength"])
		quit(1)
	print("关风 OK (strength=%s)" % w0["strength"])

	# ---- 3) 种子：set/get 往返 ----
	phys.set_order_seed(12345)
	if phys.get_order_seed() != 12345:
		print("WIND_WIRE_FAIL: 种子往返不符 (%d)" % phys.get_order_seed())
		quit(1)
	print("种子往返 OK (seed=%d)" % phys.get_order_seed())

	# ---- 4) 重新开风并跑几帧，确认不崩 ----
	phys.set_wind(WIND_DIR_static().x, WIND_DIR_static().y, WIND_DIR_static().z, 6.0, 0.25, 0.8)
	var vl := VMDLoader.new()
	var vmd := vl.parse("res://models/motions.vmd")
	if vmd.is_empty():
		printerr("VMD parse failed")
		quit(1)
	var player := VMDPlayer.new()
	root_node.add_child(player)
	player.setup(skel, model["bones"], vmd, [], null, model["morphs"])
	player.set_physics(phys)
	player.playing = true
	for i in 30:
		player._process(1.0 / 60.0)
	print("跑 30 帧（带风）无崩溃 OK")

	print("WIND_WIRE_PASS")
	quit(0)


func WIND_DIR_static() -> Vector3:
	return Vector3(1.0, 0.0, 0.0)
