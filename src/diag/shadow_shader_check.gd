extends SceneTree

func _initialize() -> void:
	var path := "res://shaders/mmd_material.gdshader"
	var res := ResourceLoader.load(path)
	if res == null:
		print("SHADER_LOAD_FAIL: ", path)
		quit(1)
		return
	var ok := res is Shader
	print("SHADER_LOAD_OK path=", path, " is_shader=", ok, " class=", res.get_class())
	if not ok:
		quit(1)
		return
	# 顺带确认关联脚本语法可加载（本次只改了着色器，这里仅做存在性/解析兜底）。
	for p in ["res://src/mmd_layers.gd", "res://src/mmd_importer.gd"]:
		var r := ResourceLoader.load(p)
		if r == null:
			print("SCRIPT_LOAD_FAIL: ", p)
			quit(1)
			return
		print("SCRIPT_LOAD_OK: ", p)
	quit(0)
