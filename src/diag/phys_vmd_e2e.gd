extends SceneTree

# 真实动画端到端无头验证：
#   model.pmx + motion.vmd → 骨架 → MMDPhysicsGD(默认重力 0,-98,0) → VMDPlayer(+物理)
#   逐帧调用 player._process(dt)（与实机 F5 同一套代码路径：动画 pose → IK → flush → 物理 step_frame），
#   每帧扫描全骨架：
#     - nonFinite   ：任意骨骼原点/基是否非有限（NaN/Inf）→ 立刻 FAIL
#     - exploded    ：任意骨骼原点长度 > 50 或离静止位移 > 50（面条/炸开）→ FAIL
#     - 受驱动骨骼  ：物理是否真的在动（max disp>0）、且位移有界（<50 不炸）
#   最终打印 PASS/FAIL 与关键量化指标。
#
# 说明：这是 phys_integration_test.gd 的"升级版"——后者只手动挪了头骨一下，
# 而 phys_explode_diag.gd 的 Test2 合成根骨运动数字与 Test1 相同（没真扰动骨链）。
# 本脚本用【真实 VMD 动作】驱动，能真正检验"动画 + 物理"叠加后是否还炸。

const DT := 1.0 / 60.0
const EXPLODE := 50.0          # 原点长度 / 离静止位移 超过此值视为爆炸（模型约 20 单位高）

func _globals(skel: Skeleton3D) -> Array:
	var n := skel.get_bone_count()
	var g: Array = []
	g.resize(n)
	var lp: Array = []
	lp.resize(n)
	for i in n:
		lp[i] = skel.get_bone_pose(i)
	for i in n:
		var p := skel.get_bone_parent(i)
		if p >= 0:
			g[i] = (g[p] as Transform3D) * (lp[i] as Transform3D)
		else:
			g[i] = lp[i] as Transform3D
	return g


func _initialize() -> void:
	var loader := PMXLoader.new()
	var model := loader.parse("res://models/model.pmx")
	if model.is_empty():
		printerr("PMX parse failed")
		quit(1)
		return
	print("PMX: bones=%d rigidbodies=%d joints=%d" % [
		model["bones"].size(), model["rigidbodies"].size(), model["joints"].size()])

	var root_node := Node.new()
	root.add_child(root_node)
	var skel := Skeleton3D.new()
	root_node.add_child(skel)
	var builder := MMDModelBuilder.new()
	builder._build_skeleton(skel, model)
	print("skeleton bones=%d" % skel.get_bone_count())

	var phys := MMDPhysicsGD.new()
	phys.initialize(skel, model["rigidbodies"], model["joints"])
	if not phys.is_ready():
		printerr("physics not ready")
		quit(1)
		return

	var vl := VMDLoader.new()
	# 注意：motion.vmd 是"纯表情、给别的模型做的"（mmd_importer.gd 第11行），
	# 没有骨骼轨，检验不到"动画扰动物理"。真正带骨骼动作的是 motions.vmd（命中 504/545 轨）。
	var vmd := vl.parse("res://models/motions.vmd")
	if vmd.is_empty():
		printerr("VMD parse failed")
		quit(1)
		return
	print("VMD: bone_tracks=%d morph_tracks=%d" % [vmd["bone_tracks"].size(), vmd["morph_tracks"].size()])

	var player := VMDPlayer.new()
	root_node.add_child(player)
	# targets=[] mesh=null：本测试不验证表情渲染，只验证"动画+物理"骨链
	player.setup(skel, model["bones"], vmd, [], null, model["morphs"])
	player.set_physics(phys)
	player.playing = true
	player.loop = true

	# 受驱动骨骼集合（物理直接写回的骨骼）
	var driven: Dictionary = {}
	for db in phys._driven_bones:
		if db >= 0 and db < skel.get_bone_count():
			driven[db] = true

	var n := skel.get_bone_count()
	var rest := _globals(skel)

	# 帧数：跑完整一段 + 余量（确保至少触发一次循环回到开头的 physics.reset 路径）
	var dur_frames := int(player.duration * 60.0)
	var frames := dur_frames + 200 if dur_frames > 0 else 600
	print("motion duration=%.2fs → %d 帧；本次跑 %d 帧（覆盖循环reset路径）" % [player.duration, dur_frames, frames])

	var nonfinite_total := 0
	var exploded_total := 0
	var first_bad_frame := -1
	var max_any_origin_len := 0.0      # 全程任意骨骼原点长度最大值（爆炸阈值 EXPLODE）
	var max_any_disp := 0.0            # 全程任意骨骼离静止位移最大值（爆炸阈值 EXPLODE）
	var max_driven_disp := 0.0         # 受驱动骨骼离静止的最大位移（有界即物理正常）
	var driven_active_peak := 0.0      # 某一帧里"被物理推动最狠"的受驱动骨位移
	var driven_moved_bones: Dictionary = {}  # 统计有多少受驱动骨曾被推动过（>0.3）

	for f in frames:
		player._process(DT)
		var g := _globals(skel)
		var frame_max_origin := 0.0
		var frame_max_disp := 0.0
		var frame_driven_disp := 0.0
		for b in n:
			var t := g[b] as Transform3D
			if not (t.origin.is_finite() and t.basis.x.is_finite()
					and t.basis.y.is_finite() and t.basis.z.is_finite()):
				nonfinite_total += 1
				if first_bad_frame < 0:
					first_bad_frame = f
				continue
			var L := t.origin.length()
			if L > frame_max_origin:
				frame_max_origin = L
			var d := t.origin.distance_to((rest[b] as Transform3D).origin)
			if d > frame_max_disp:
				frame_max_disp = d
			if driven.has(b):
				if d > frame_driven_disp:
					frame_driven_disp = d
				if d > 0.3:
					driven_moved_bones[b] = true
		if frame_max_origin > max_any_origin_len:
			max_any_origin_len = frame_max_origin
		if frame_max_disp > max_any_disp:
			max_any_disp = frame_max_disp
		if frame_driven_disp > driven_active_peak:
			driven_active_peak = frame_driven_disp
		if frame_driven_disp > max_driven_disp:
			max_driven_disp = frame_driven_disp
		# 爆炸判定：任意骨骼原点长度越界，或离静止位移越界（面条/炸开）
		if frame_max_origin > EXPLODE or frame_max_disp > EXPLODE:
			exploded_total += 1
			if first_bad_frame < 0:
				first_bad_frame = f

		if (f + 1) % 60 == 0:
			print("[frame %d/%d] maxOriginLen=%.2f maxDisp=%.2f drivenPeakDisp=%.3f nonFinite=%d exploded=%d"
				% [f + 1, frames, frame_max_origin, frame_max_disp, frame_driven_disp, nonfinite_total, exploded_total])

	# ── 结论 ──
	var driven_active := driven_moved_bones.size()
	print("")
	print("=== 端到端验证结论 ===")
	print("  帧数=%d  受驱动骨骼总数=%d  其中被物理推动过(>0.3)的=%d"
		% [frames, driven.size(), driven_active])
	print("  全程 nonFinite=%d  exploded(>%.0f)=%d  首坏帧=%d"
		% [nonfinite_total, EXPLODE, exploded_total, first_bad_frame])
	print("  受驱动骨 最大位移峰值=%.3f（有界即正常，远小于 %.0f 表示没炸）" % [max_driven_disp, EXPLODE])
	print("  任意骨 最大原点长度=%.2f  最大离静止位移=%.2f" % [max_any_origin_len, max_any_disp])

	var ok := (nonfinite_total == 0 and exploded_total == 0)
	if ok and driven_active == 0:
		print("WARN: 无爆炸，但受驱动骨骼全程没动过——物理可能处于惰性（重力下应至少下垂/摆动）")
		print("PHYSICS_E2E_WARN")
		quit(0)
	elif ok:
		print("PHYSICS_E2E_PASS: 真实动画 + 物理 全链路无爆炸/无 NaN，且头发/裙子等刚体被物理驱动")
		quit(0)
	else:
		print("PHYSICS_E2E_FAIL: 出现非有限或爆炸，详见上方逐帧 trace")
		quit(1)
