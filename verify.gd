extends SceneTree

func _origin_list(w, i):
	if i < 0 or i >= w.size():
		return null
	var t = w[i]
	if t == null:
		return null
	var o = t.origin
	return [o.x, o.y, o.z]

func _initialize():
	print("[verify] start")
	var loader := PMXLoader.new()
	var model := loader.parse("res://models/model.pmx")
	var builder := MMDModelBuilder.new()
	var res := builder.build(model, "res://models")
	var skel: Skeleton3D = res["skeleton"]
	var mesh: ArrayMesh = res["mesh"]
	var mi: MeshInstance3D = res["mesh_instance"]
	var vl := VMDLoader.new()
	var vmd := vl.parse("res://models/motions.vmd")

	var player := VMDPlayer.new()
	player.setup(skel, model["bones"], vmd, [mi], mesh, model["morphs"])

	var n := skel.get_bone_count()
	var grest := []
	grest.resize(n)
	for i in n:
		var p: int = skel.get_bone_parent(i)
		var lr: Transform3D = skel.get_bone_rest(i)
		if p < 0:
			grest[i] = lr
		else:
			grest[i] = (grest[p] as Transform3D) * lr
	var rest_world := []
	rest_world.resize(n)
	for i in n:
		rest_world[i] = (grest[i] as Transform3D).origin

	var ik_idx := PackedInt32Array()
	for i in n:
		if int(model["bones"][i]["flag"]) & 0x20:
			ik_idx.append(i)

	# 建立名字->索引
	var name_to_idx := {}
	for i in n:
		name_to_idx[skel.get_bone_name(i)] = i

	var frames := [0.0, 1.0, 5.0]
	var report := []
	for tf in frames:
		player.time = tf
		player._process(0.0)
		var w := player._world
		var bones_out := []
		for i in n:
			var p: int = skel.get_bone_parent(i)
			var bw = _origin_list(w, i)
			var bp = _origin_list(w, p)
			var blen := 0.0
			var rlen := 0.0
			if bw != null and bp != null:
				blen = sqrt((bw[0]-bp[0])*(bw[0]-bp[0]) + (bw[1]-bp[1])*(bw[1]-bp[1]) + (bw[2]-bp[2])*(bw[2]-bp[2]))
			var rr = rest_world[i]
			var rpv = rest_world[p]
			if p >= 0 and rr != null and rpv != null:
				rlen = sqrt((rr.x-rpv.x)*(rr.x-rpv.x) + (rr.y-rpv.y)*(rr.y-rpv.y) + (rr.z-rpv.z)*(rr.z-rpv.z))
			var ep: Vector3 = player._eff_pos[i]
			var er: Quaternion = player._eff_rot[i]
			bones_out.append({"n": skel.get_bone_name(i), "p": p, "w": bw,
				"rest": [rr.x, rr.y, rr.z], "blen": blen, "rlen": rlen,
				"ep": [ep.x, ep.y, ep.z], "er": [er.x, er.y, er.z, er.w]})
		var ik_d := []
		for i in ik_idx:
			var tgt: int = int(model["bones"][i]["ikTargetIndex"])
			var wt = _origin_list(w, i)
			var we = _origin_list(w, tgt)
			var d = null
			if wt != null and we != null:
				d = sqrt((wt[0]-we[0])*(wt[0]-we[0]) + (wt[1]-we[1])*(wt[1]-we[1]) + (wt[2]-we[2])*(wt[2]-we[2]))
			ik_d.append({"name": skel.get_bone_name(i), "d": d})
		report.append({"t": tf, "bones": bones_out, "ik": ik_d})

		# 帧0 额外：右腿链 world vs rest
		if tf == 0.0:
			var chain := []
			for kn in ["右足ＩＫ", "右足首", "右ひざ", "右足", "足根", "右足先EX", "センター", "全ての親"]:
				if not name_to_idx.has(kn):
					continue
				var bi: int = name_to_idx[kn]
				chain.append({"name": kn, "idx": bi, "p": skel.get_bone_parent(bi),
					"w": _origin_list(player._world, bi), "rest": [rest_world[bi].x, rest_world[bi].y, rest_world[bi].z]})
			report.append({"chain_frame0": chain})

	var payload := {"n": n, "frames": report}
	var f := FileAccess.open("C:/ag_vmdtest/verify.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(payload))
	f.close()
	print("[verify] wrote C:/ag_vmdtest/verify.json n=%d frames=%d" % [n, frames.size()])
	quit()
