extends SceneTree

# 验证：shadow_tight_fit 开启时，bias 应用逻辑按 _tight_prec 乘法写入且不崩。
# 无头无相机时 _compute_tight_max_distance 返回 0 → _tight_prec fallback=1.0 → bias=shadow_bias*1。
# 真实 _tight_prec>1 需 F5（有相机算出 fit_md）。
func _init():
	var lc = load("res://src/mmd_layers.gd").new()
	var sun = DirectionalLight3D.new()
	lc._sun = sun
	lc.shadow_bias = 0.05
	lc.shadow_normal_bias = 1.5
	lc.shadow_tight_bias_boost = 2.0
	# shadow_tight_fit 默认 true
	print("BOOST_VAR=%f" % lc.shadow_tight_bias_boost)
	lc._apply_shadow()
	print("TIGHT_BIAS=%f (无相机 fit_md=0→_tight_prec=1→期望 0.05)" % sun.shadow_bias)
	print("TIGHT_NBIAS=%f (期望 1.5)" % sun.shadow_normal_bias)
	print("TIGHT_BIAS_DIAG_OK")
	quit()
