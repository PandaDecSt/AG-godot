extends SceneTree

# 验证 mmd_layers.gd 的贴身阴影框逻辑：API 可用性 + 计算不崩。
func _initialize() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-65, 0, 0)
	sun.shadow_enabled = true
	root.add_child(sun)

	var cam := Camera3D.new()
	cam.position = Vector3(0, 1.6, 8)
	cam.current = true
	root.add_child(cam)

	var mi := MeshInstance3D.new()
	mi.mesh = BoxMesh.new()      # 高 1 的盒，模拟角色(中心在原点)
	mi.position = Vector3(0, 0, 0)
	root.add_child(mi)

	var ground := MeshInstance3D.new()
	ground.position = Vector3(0, -10.0, 0)   # 地面在 y=-10
	root.add_child(ground)

	var lc = (load("res://src/mmd_layers.gd") as Script).new()
	root.add_child(lc)
	# 注入依赖(绕过 _process 懒解析；真实场景里由节点关系自动取到)
	lc._sun = sun
	lc._ground = ground
	lc._char_mesh = mi
	lc.shadow_tight_fit = true
	lc.shadow_tight_margin = 4.0

	var aabb: AABB = mi.get_aabb()
	print("AABB_OK center=", aabb.get_center(), " size=", aabb.size)
	var md = lc._compute_tight_max_distance()
	print("COMPUTE_MD=", md)
	print("CAM_OK=", root.get_camera_3d() != null)

	# 手动复算公式，确认 clampf/maxf/distance_to/投影 等 API 在 4.7 可用且结果合理
	var top2: Vector3 = Vector3(0.0, 0.5, 0.0)
	var base2: Vector3 = Vector3(0.0, -0.5, 0.0)
	var ground_y2: float = -10.0
	var wd: Vector3 = (sun.global_transform.basis * Vector3(0, 0, 1)).normalized()
	var travel2: Vector3 = -wd
	var landing2: Vector3 = top2
	if abs(travel2.y) > 1e-4:
		var t2: float = (ground_y2 - top2.y) / travel2.y
		if t2 > 0.0:
			landing2 = top2 + travel2 * t2
	var cam_p2: Vector3 = cam.global_position
	var md2: float = maxf(cam_p2.distance_to(top2), maxf(cam_p2.distance_to(base2), cam_p2.distance_to(landing2))) + 4.0
	md2 = clampf(md2, 15.0, 200.0)
	print("MATH_SANITY=", md2)
	print("TIGHTFIT_DIAG_OK")
	quit()
