shader_type spatial;
// MMD 描边（严格对齐 AfterglowWeb src/shader/pmx/outline-vs.ts + outline-fs.ts）。
//
// ============ 致命语法坑 ============
// .gdshader 是 GLSL：变量写「type name = value;」，绝不用 GDScript 的「var name: type = ...」。
// GLSL 没有 null 关键字：纹理绑定判断用 bool（use_edge_alpha），不能写「tex != null」。
//
// ============ 几何：在【视图空间】做外扩（不在裁剪空间反变换）============
// AfterglowWeb 在裁剪空间外扩（out.position = clip.xy + screenNrm*edgeSize*0.003*clip.w），
// 屏幕宽度恒定。Godot 顶点只能写 VERTEX（模型空间），不能直接写裁剪坐标。
// 上一版用 inverse(PROJECTION*VIEW*MODEL) 在裁剪空间绕一圈反变换回 VERTEX，
// 在 Godot 4.7 下随视角缩放会累积误差→外壳飘离模型。
// 本版改在【视图空间】外扩：viewPos.xy += dir * (edge_size*0.003) * (-viewPos.z)，
// 乘 -viewPos.z 抵消透视→屏幕宽度同样恒定（与原版 *clip.w 数学等价），
// 反变换只碰 VIEW*MODEL（不含投影矩阵），无裁剪空间舍入问题，缩放时外壳牢牢贴合模型。
// 关键：mmd_builder.gd 已开启 FLIP_Z（顶点 Z 翻转，对齐原版 scaling(1,1,-1)），绕序恢复正常(CCW=正面)。
//       故壳的「朝相机面」在 Godot 里被判定为 front face；inverted hull 要剔除朝相机壳面、只留背相机壳面
//       (轮廓外一圈可见、中间被模型挡住)，等价于剔除 front face → 用 cull_front（不是 cull_back）。
//       若误用 cull_back 会保留朝相机壳面(比模型略大) → 黑壳盖在模型上 = 「外壳覆盖模型」。
render_mode cull_front, depth_draw_always;

uniform vec4 edge_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float edge_size = 1.0;            // 直接等于 PMX edgeScale；*0.003 得屏幕偏移（对齐原版）
uniform bool use_edge_alpha = false;       // 对齐 AfterglowWeb outline-fs：用漫反射贴图 alpha 裁掉透明处描边
uniform sampler2D edge_alpha_tex;

void vertex() {
	// 1) 已蒙皮的世界空间位置/法线（Godot 自动蒙皮，VERTEX/NORMAL 已是蒙皮后的值）
	vec4 worldPos = MODEL_MATRIX * vec4(VERTEX, 1.0);
	vec3 worldNrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);

	// 2) 转到视图空间（相机看向 -Z）
	vec4 viewPos = VIEW_MATRIX * worldPos;
	vec3 viewNrm = (VIEW_MATRIX * vec4(worldNrm, 0.0)).xyz;

	// 3) 沿视图空间法线的屏幕 XY 方向外扩；乘 -viewPos.z 抵消透视 → 屏幕宽度恒定
	//    （对齐 AfterglowWeb 的 *clip.w；法线朝相机的顶点 xy≈0，跳过避免 normalize 出 NaN）
	float nlen = length(viewNrm.xy);
	if (nlen > 1e-4) {
		vec2 dir = viewNrm.xy / nlen;
		float expand = edge_size * 0.003 * (-viewPos.z);
		viewPos.xy += dir * expand;
	}

	// 4) 深度略前推：整体朝相机移动一丢丢，确保通过深度测试（等价原版 less-equal + depthBias）
	viewPos.z *= 0.9995;

	// 5) 反变换回模型空间交还引擎（v = (VIEW*MODEL)^-1 * viewPos，不含投影矩阵）
	VERTEX = (inverse(VIEW_MATRIX * MODEL_MATRIX) * viewPos).xyz;
}

void fragment() {
	float a = 1.0;
	if (use_edge_alpha) {
		a = texture(edge_alpha_tex, UV).a;
		if (a < 0.05) {
			discard;   // 透明贴图区域不描边（对齐 AfterglowWeb outline-fs 的 texA<0.05 discard）
		}
	}
	ALBEDO = edge_color.rgb;
	ALPHA = edge_color.a * a;
}
