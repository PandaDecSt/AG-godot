shader_type spatial;
// MMD 外观着色器【透明变体】——逻辑与 mmd_material.gdshader 完全一致，仅 render_mode 多了 blend_mix，
// 让真正半透的材质(alpha<1)走透明混合通道。详见 mmd_material.gdshader 顶部说明。
// depth_draw_never：对齐 AfterglowWeb pmx-viewer.ts:644 透明管线 depthWriteEnabled:false——
// 半透/薄纱布料不写深度，避免把后面的身体或其他透明层挡成硬切口。cull_disabled 沿用双面(材质标了双面)。
// 阴影：同样用自定义 light() + 内置 ATTENUATION 折 toon（透明材质也能接收方向光阴影）。
// ambient_light_disabled：关 Godot 环境光，避免叠加。
// 颜色计算全在 light() 里（Godot 4 禁止 fragment/light 间共享可变全局变量）。
render_mode ambient_light_disabled, cull_disabled, blend_mix, depth_draw_never;

uniform sampler2D albedo_tex : source_color, filter_linear, repeat_enable;
uniform sampler2D toon_tex : source_color, filter_linear;
uniform sampler2D sphere_tex : source_color, filter_linear;

uniform bool use_albedo = true;
uniform bool use_sphere = false;
uniform float sphere_mode = 1.0;
uniform vec3 base_tint = vec3(1.0);
uniform float alpha = 1.0;
uniform vec3 specular_color = vec3(0.0);
uniform float shininess = 16.0;
uniform vec3 ambient_color = vec3(0.5);
uniform vec3 rim_color = vec3(0.0);
uniform float rim_power = 2.0;
uniform float rim_strength = 0.0;
uniform float emission_strength = 0.0;

uniform vec3 light_dir = vec3(0.0, 0.0, 1.0);
uniform vec3 light_color = vec3(1.0);

uniform int layer_mask = 31;
uniform int layer_order[5];
uniform int debug_mode = 0;

// 曝光 + 着色器内 Filmic Tonemap：精确对齐 AfterglowWeb pmx-tonemapper.ts 的 Hable/Uncharted2 filmic 曲线（详见 mmd_material.gdshader）。
uniform float exposure = 1.0;
// 色彩分级（对齐原版 pmx-tonemapper.ts:63 gradeColor）：饱和度 + 对比度。详见 mmd_material.gdshader。
uniform float saturation = 1.15;
uniform float contrast = 1.08;
// 注意：Godot GLSL 内置常量 PI/TAU/E 不可重定义，故原版 Hable 参数 A B C D E F 全部小写化（a,b,c,d,e,f）。
vec3 filmicTonemap(vec3 x) {
	float a = 0.22; float b = 0.30; float c = 0.10; float d = 0.20; float e = 0.01; float f = 0.30;
	float W = 11.2;
	float wp = ((W * (a * W + c * b) + d * e) / (W * (a * W + b) + d * f)) - e / f;
	vec3 res = ((x * (a * x + c * b) + d * e) / (x * (a * x + b) + d * f)) - e / f;
	return max(res, vec3(0.0)) / wp;
}

// 色彩分级：精确对齐原版 pmx-tonemapper.ts:63 gradeColor（详见 mmd_material.gdshader）。
vec3 gradeColor(vec3 c) {
	vec3 slope = vec3(1.0);
	vec3 offset = vec3(0.0);
	vec3 power = vec3(1.0);
	vec3 x = pow(max(c * slope + offset, vec3(0.0)), power);
	x = (x - vec3(0.5)) * contrast + vec3(0.5);
	float luma = dot(x, vec3(0.2126, 0.7152, 0.0722));
	return max(mix(vec3(luma), x, saturation), vec3(0.0));
}

// ===== 顶点阶段（关键：修复蒙皮网格不投射方向光阴影）=====
// 同 mmd_material.gdshader：声明 vertex() 让 Godot 为阴影 depth 通道生成带骨骼蒙皮的变体。
// 纯透传 VERTEX（骨皮后坐标由引擎自动注入），外观不变。
void vertex() {
	vec3 skinned_pos = VERTEX;   // 骨皮后本地坐标（Godot 自动注入）
	VERTEX = skinned_pos;       // 透传
}

void fragment() {
	// 双面修正：背面(FRONT_FACING=false)法线朝内，翻过来写回 NORMAL，light() 据此两面都朝外受光。
	vec3 N = normalize(NORMAL);
	if (!FRONT_FACING) {
		N = -N;
	}
	NORMAL = N;

	// 对齐原版 main-fs.ts:102：alpha = diffuse.a * tex.a（无条件乘贴图 alpha），<0.001 discard。
	vec4 tex = use_albedo ? texture(albedo_tex, UV) : vec4(1.0);
	float a = alpha * tex.a;
	if (a < 0.001) discard;
	ALBEDO = vec3(1.0);
	ALPHA = a;
}

void light() {
	// 双面法线已在 fragment() 里翻转并写回 NORMAL，这里直接用（light pass 读到的是改后的）。
	vec3 N = normalize(NORMAL);
	vec3 V = normalize(VIEW);
	vec3 L = normalize(LIGHT);
	vec3 lc = LIGHT_COLOR / PI;

	vec4 tex = use_albedo ? texture(albedo_tex, UV) : vec4(1.0);
	vec3 baseColor = tex.rgb * base_tint;

	// ---- 调试模式：直接输出固定颜色，不走光照合成 ----
	if (debug_mode == 1) {
		DIFFUSE_LIGHT = baseColor;
		SPECULAR_LIGHT = vec3(0.0);
	} else if (debug_mode == 2) {
		DIFFUSE_LIGHT = vec3(fract(UV * 8.0), 0.5);
		SPECULAR_LIGHT = vec3(0.0);
	} else if (debug_mode == 3) {
		DIFFUSE_LIGHT = N * 0.5 + 0.5;
		SPECULAR_LIGHT = vec3(0.0);
	} else {
		float ndl = dot(N, L);
		float vis = ATTENUATION;
		vis = min(vis, smoothstep(0.0, 0.35, ndl));
		float shadowedNL = min(ndl, vis * 2.0 - 1.0);
		float toonT = clamp(shadowedNL * 0.5 + 0.5, 0.0, 1.0);
		float toonShade = max(texture(toon_tex, vec2(toonT, 0.5)).r, 0.25);

		vec3 nprDiffuse = baseColor * toonShade;
		vec3 H = normalize(V + L);
		vec3 specContrib = pow(max(dot(N, H), 0.0), max(shininess, 1.0)) * specular_color;
		vec3 rimContrib  = rim_color * pow(1.0 - max(dot(N, V), 0.0), rim_power) * rim_strength;

		vec3 sphereAdd = vec3(0.0);
		if (use_sphere) {
			vec2 suv = (sphere_mode > 1.5) ? UV : (N.xy * 0.5 + 0.5);
			sphereAdd = texture(sphere_tex, suv).rgb * baseColor;
		}
		vec3 emis = baseColor * emission_strength;

		vec3 color = baseColor * ambient_color;
		for (int i = 0; i < 5; i++) {
			int id = layer_order[i];
			int bit = (1 << id);
			if ((layer_mask & bit) == 0) {
				continue;
			}
			if (id == 0) {
				color += nprDiffuse * lc;
			} else if (id == 1) {
				color += specContrib * lc;
			} else if (id == 2) {
				color += rimContrib;
			} else if (id == 3) {
				color += emis;
			} else if (id == 4) {
				color += sphereAdd;
			}
		}
		vec3 hdr = color * exposure;
		vec3 ldr = filmicTonemap(hdr);
		DIFFUSE_LIGHT = gradeColor(ldr);
		SPECULAR_LIGHT = vec3(0.0);
	}
}
