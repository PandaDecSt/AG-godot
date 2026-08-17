extends SceneTree

func _initialize() -> void:
	var paths := PackedStringArray([
		"res://src/mmd_importer.gd",
		"res://src/mmd_layers.gd",
	])
	var ok := true
	for p in paths:
		var res = ResourceLoader.load(p)
		if res == null:
			printerr("SYNTAX_FAIL: ", p)
			ok = false
		else:
			print("SYNTAX_OK: ", p)
	print("BIAS_CHECK_DONE" if ok else "BIAS_CHECK_FAIL")
	quit()
