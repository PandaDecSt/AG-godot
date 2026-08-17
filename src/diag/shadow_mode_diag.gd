extends SceneTree

# 校验阴影单图模式相关枚举/属性存在且可写入（无头跑，不依赖模型/场景）。
func _init() -> void:
	var sun := DirectionalLight3D.new()
	print("SHADOW_ORTHOGONAL=", DirectionalLight3D.SHADOW_ORTHOGONAL)
	print("SHADOW_PARALLEL_2_SPLITS=", DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS)
	print("SHADOW_PARALLEL_4_SPLITS=", DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS)

	# 模拟 main.tscn 的父子结构：root -> [SunLight, LayerController]
	var root := Node.new()
	sun.name = "SunLight"
	root.add_child(sun)
	var layers_script := load("res://src/mmd_layers.gd")
	var lc = layers_script.new()
	lc.name = "LayerController"
	root.add_child(lc)

	# 设成 Single ortho 并应用一次，验证新属性名合法、apply 不报错。
	# 注：--script 独立树下 get_parent().get_node_or_null 取不到 SunLight，
	# 故直接注入 _sun（真实 main.tscn 里父子结构正常，无需此步）。
	lc._sun = sun
	lc.shadow_mode = "Single ortho"
	lc.shadow_blend_splits = false
	lc.shadow_pancake_size = 20.0
	lc.shadow_max_distance = 60.0
	lc._apply_shadow()
	print("AFTER_SINGLE mode=", sun.directional_shadow_mode, " pancake=", sun.directional_shadow_pancake_size, " maxd=", sun.directional_shadow_max_distance)

	# 切回 PSSM 4-split 再应用，验证分支也合法
	lc.shadow_mode = "PSSM 4-split"
	lc._apply_shadow()
	print("AFTER_PSSM mode=", sun.directional_shadow_mode)

	print("SHADOW_MODE_DIAG_OK")
	quit()
