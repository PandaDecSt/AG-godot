extends SceneTree

func _initialize():
	var loader: Variant = (load("res://src/pmx_loader.gd") as Script).new()
	var model: Variant = loader.parse("res://models/model.pmx")
	var mats: Array = model["materials"]
	var mp: Variant = (load("res://src/material_presets.gd") as Script).new()
	var texs: Array = model["textures"]
	for m in mats:
		var role: String = mp.classify_role(m["name"])
		var toon_src := ""
		if m["toonSharing"] == 1:
			toon_src = "fallback(shared)"
		elif m["toonTextureIndex"] >= 0 and m["toonTextureIndex"] < texs.size():
			toon_src = texs[m["toonTextureIndex"]]
		else:
			toon_src = "fallback(no-idx)"
		print("[mat] %-28s role=%-12s toon=%s" % [m["name"], role, toon_src])
	quit()