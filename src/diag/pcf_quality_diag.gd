extends SceneTree
func _initialize() -> void:
	var lc = load("res://src/mmd_layers.gd").new()
	var sun = DirectionalLight3D.new()
	lc._sun = sun
	print("PCF_VAR_EXISTS=", "shadow_pcf_quality" in lc)
	print("PCF_DEFAULT=", lc.shadow_pcf_quality)
	lc.shadow_pcf_quality = "Ultra"
	lc._apply_shadow()
	print("PCF_ULTRA_OK")
	lc.shadow_pcf_quality = "High"
	lc._apply_shadow()
	print("PCF_HIGH_OK")
	lc.shadow_pcf_quality = "Off"
	lc._apply_shadow()
	print("PCF_OFF_OK")
	print("PCF_DIAG_OK")
	quit()
