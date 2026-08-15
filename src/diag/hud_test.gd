extends SceneTree

func _initialize() -> void:
	var s = load("res://src/mmd_importer.gd")
	if s == null:
		print("PARSE FAIL mmd_importer.gd")
		quit()
	print("PARSE OK mmd_importer.gd")
	var n = s.new()
	get_root().add_child(n)   # _ready 会自动运行（含 _init_hud）
	await create_timer(0.3).timeout   # 等一帧，确保 _ready 跑完
	print("HUD docks=", n._hud_docks != null, " left=", n._left_dock != null, " right=", n._right_dock != null)
	if n._left_dock != null:
		print("left rect=", n._left_dock.get_rect(), " right rect=", n._right_dock.get_rect())
		# 模拟视口缩放夹取（小窗口 640x480）
		get_root().size = Vector2(640, 480)
		await create_timer(0.05).timeout
		print("after resize left rect=", n._left_dock.get_rect(), " right rect=", n._right_dock.get_rect())
		# 切换可见
		print("toggle before=", n._hud_visible)
		n._on_hud_toggle()
		print("toggle after=", n._hud_visible, " docks.visible=", n._hud_docks.visible)
		n._on_hud_toggle()
		print("toggle back=", n._hud_visible)
	quit()
