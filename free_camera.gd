extends Camera3D

# 自由检视相机：左键拖拽=绕目标旋转，右键拖拽=平移，滚轮=缩放，WASD/QE=自由移动。
# 取景目标来自 ModelRoot 写入的 meta（mmd_center / mmd_size），由 importer._ready 设置。

var target := Vector3(0.0, 11.0, 0.0)
var distance := 35.0
var yaw := 0.0
var pitch := 0.12

var _framed := false
var _orb := false
var _pan := false
var _last := Vector2.ZERO

const MIN_DIST := 0.5
const MAX_DIST := 500.0


func _ready() -> void:
	# 相机完全由本脚本接管；importer 不再移动相机。
	pass


func _process(dt: float) -> void:
	if not _framed:
		var mroot: Node = get_parent().get_node_or_null("ModelRoot")
		if mroot != null and mroot.has_meta("mmd_center"):
			target = mroot.get_meta("mmd_center")
			var sz: Vector3 = mroot.get_meta("mmd_size") if mroot.has_meta("mmd_size") else Vector3(15.0, 22.0, 10.0)
			distance = max(sz.x, sz.y, sz.z) * 1.6 + 1.0
			_framed = true
			_apply()
		else:
			# 兜底：默认看人物上半身高度
			target = Vector3(0.0, 11.0, 0.0)
			distance = 35.0
			_framed = true
			_apply()

	# WASD / QE 自由平移目标（前后左右 + 升降）
	var mv := Vector3.ZERO
	var right: Vector3 = global_transform.basis.x
	var fwd: Vector3 = -global_transform.basis.z
	if Input.is_key_pressed(KEY_W): mv += fwd
	if Input.is_key_pressed(KEY_S): mv -= fwd
	if Input.is_key_pressed(KEY_A): mv -= right
	if Input.is_key_pressed(KEY_D): mv += right
	if Input.is_key_pressed(KEY_E): mv += Vector3.UP
	if Input.is_key_pressed(KEY_Q): mv -= Vector3.UP
	if mv != Vector3.ZERO:
		target += mv * dt * distance * 0.6
		_apply()


func _apply() -> void:
	var t := Transform3D(Basis.from_euler(Vector3(pitch, yaw, 0.0)), Vector3.ZERO)
	var pos := target + t * Vector3(0.0, 0.0, distance)
	global_transform = Transform3D(t.basis, pos)
	look_at(target, Vector3.UP)


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventMouseButton:
		if e.button_index == MOUSE_BUTTON_LEFT:
			_orb = e.pressed
			_last = e.position
		elif e.button_index == MOUSE_BUTTON_RIGHT:
			_pan = e.pressed
			_last = e.position
		elif e.button_index == MOUSE_BUTTON_WHEEL_UP:
			distance = max(MIN_DIST, distance * 0.9)
			_apply()
		elif e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			distance = min(MAX_DIST, distance * 1.1)
			_apply()
	elif e is InputEventMouseMotion:
		if _orb:
			yaw -= e.relative.x * 0.005
			pitch = clampf(pitch - e.relative.y * 0.005, -1.55, 1.55)
			_apply()
		elif _pan:
			var right: Vector3 = global_transform.basis.x
			var upv: Vector3 = global_transform.basis.y
			var s: float = distance * 0.0015
			target -= right * e.relative.x * s
			target += upv * e.relative.y * s
			_apply()
