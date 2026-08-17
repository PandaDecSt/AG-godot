extends SceneTree

# 校验：① 两个改过的脚本语法可加载；② 方向光逐光源属性可写；③ 纹理尺寸走项目设置可读写。
func _init() -> void:
	var ok := true
	# ① 语法加载
	for path in ["res://src/mmd_layers.gd", "res://src/mmd_importer.gd"]:
		var scr := ResourceLoader.load(path)
		if scr == null:
			print("SYNTAX FAIL: " + path)
			ok = false
		else:
			print("SYNTAX OK:  " + path)

	# ② 逐光源属性
	var sun := DirectionalLight3D.new()
	sun.directional_shadow_max_distance = 60.0
	sun.light_angular_distance = 1.5
	sun.shadow_bias = 0.3
	sun.shadow_normal_bias = 0.9
	print("LIGHT props set OK: maxdist=%f angular=%f" % [sun.directional_shadow_max_distance, sun.light_angular_distance])

	# ③ 项目设置：方向光阴影尺寸
	var key := "rendering/lights_and_shadows/directional_shadow/size"
	var before = ProjectSettings.get_setting(key)
	ProjectSettings.set_setting(key, 8192)
	var after = ProjectSettings.get_setting(key)
	print("PS %s before=%s after=%s" % [key, before, after])
	if int(after) != 8192:
		ok = false

	print("SHADOW_VERIFY " + ("PASS" if ok else "FAIL"))
	quit()
