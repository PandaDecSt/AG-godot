extends SceneTree

# 仅做 GDScript 语法/编译检查：load 两个脚本，若返回 null 或报 error 说明语法坏。
func _initialize() -> void:
	var paths := PackedStringArray([
		"res://src/mmd_importer.gd",
		"res://src/mmd_physics.gd",
	])
	var ok := true
	for p in paths:
		var scr = ResourceLoader.load(p, "Script", ResourceLoader.CACHE_MODE_IGNORE)
		if scr == null:
			print("SYNTAX_FAIL: ", p, " -> load returned null")
			ok = false
		else:
			print("SYNTAX_OK:   ", p, " class=", scr.get_class())
	var code := 0 if ok else 1
	print("SYNTAX_RESULT code=", code)
	quit(code)
