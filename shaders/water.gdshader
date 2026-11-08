shader_type spatial;
// 透明水面：不写深度，让岸线泡沫可以读到水下地形的深度。
render_mode blend_mix, depth_draw_never, cull_back, diffuse_burley, specular_schlick_ggx;
// Stylised-but-convincing sea surface: layered noise-warped swell (no tiling
// texture), distance-faded detail so the horizon stays calm instead of
// shimmering into a repeating checkerboard.

uniform vec3 deep_color : source_color = vec3(0.02, 0.13, 0.24);
uniform vec3 shallow_color : source_color = vec3(0.06, 0.42, 0.48);
uniform vec3 crest_color : source_color = vec3(0.55, 0.82, 0.85);
uniform vec3 haze_color : source_color = vec3(0.70, 0.80, 0.86);
uniform float wave_scale = 0.06;
uniform float wave_speed = 0.9;
uniform float wave_height = 0.35;
uniform float foam_amount : hint_range(0.0, 1.5) = 1.0;
uniform float glitter_amount : hint_range(0.0, 2.0) = 1.0;
uniform vec3 sun_dir = vec3(0.42, 0.52, 0.2);
uniform vec3 sun_color : source_color = vec3(1.0, 0.95, 0.86);
uniform float sun_energy = 1.0;
// 取代环境贴图镜面：天空色按菲涅尔比例混进水面，避免低粗糙度把云朵
// 原样倒映成大片白斑（低分辨率 cubemap 还会放大成迷彩块）。
uniform vec3 sky_reflect : source_color = vec3(0.55, 0.68, 0.78);

uniform sampler2D depth_tex : hint_depth_texture;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm3(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 3; i++) {
		v += a * vnoise(p);
		p = p * 2.03 + vec2(17.1, 9.3);
		a *= 0.5;
	}
	return v;
}

float wave(vec2 p, float t) {
	vec2 warp = vec2(
		fbm3(p * 0.23 + vec2(t * 0.05, 0.0)),
		fbm3(p * 0.23 + vec2(3.7, -t * 0.04)));
	vec2 q = p + (warp - 0.5) * 2.2;
	float swell = sin(q.x * 1.35 + t * 0.9) * cos(q.y * 1.05 - t * 0.7);
	swell += 0.55 * sin((q.x + q.y) * 2.4 - t * 1.3);
	swell += 0.28 * sin((q.x - q.y) * 3.8 + t * 1.9);
	return swell;
}

void fragment() {
	vec2 p = world_pos.xz * wave_scale;
	float t = TIME * wave_speed;
	float cam_dist = length(world_pos.xz - INV_VIEW_MATRIX[3].xz);
	// 远处细节淡出：高频波浪只在近处起伏，海平线不再出现方块状摩尔纹。
	// 但淡出别太快——否则 1km 外就退化成一块无特征的平色墙。
	float detail = exp(-cam_dist * 0.0006);
	float bump = mix(0.24, 1.0, detail);
	float e = 0.18;
	float h0 = wave(p, t);
	float hx = wave(p + vec2(e, 0.0), t);
	float hz = wave(p + vec2(0.0, e), t);
	vec2 slope = vec2((h0 - hx), (h0 - hz)) * wave_height * bump;
	// 近处叠一层细碎涟漪：不额外采样 fbm，只加两组高频正弦，便宜但有效。
	float rip = sin(p.x * 13.0 + p.y * 9.0 + t * 2.6) * sin(p.x * 8.0 - p.y * 15.0 - t * 2.1);
	slope += vec2(cos(p.x * 13.0 + t * 2.6), cos(p.y * 9.0)) * rip * 0.035 * detail;
	vec3 n = normalize(vec3(slope.x, 1.0, slope.y));

	float view_dot = clamp(dot(normalize(VIEW_MATRIX * vec4(n, 0.0)).xyz, VIEW), 0.0, 1.0);
	float fresnel = pow(1.0 - view_dot, 3.0);
	vec3 col = mix(deep_color, shallow_color, 0.20 + fresnel * 0.48);
	// 远处掠射角反射天光：颜色取自主题雾色，和地平线自然衔接。
	// 掠射角菲涅尔接近 1，海面应该几乎全是天光，而不是深水的暗绿。
	col = mix(col, sky_reflect, fresnel * 0.72);
	col = mix(col, crest_color, clamp(h0 * 0.045 * bump, 0.0, 0.12));

	// 白浪：浪脊越陡越白，只在近处出现，远处保持平静
	float cap = smoothstep(0.55, 1.0, h0 * 0.5 + 0.5) * detail;
	col = mix(col, crest_color * 1.02, cap * 0.10);

	// 太阳耀斑：GGX 高光 + 细碎闪光，落日海面不再是死板的色块。
	// n 是世界空间，顶点/视线是视图空间：统一转到视图空间再算半程向量。
	if (sun_energy > 0.001) {
		vec3 n_view = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
		vec3 l = normalize((VIEW_MATRIX * vec4(normalize(sun_dir), 0.0)).xyz);
		vec3 v = normalize(-VERTEX);
		vec3 h = normalize(l + v);
		float spec = pow(max(dot(n_view, h), 0.0), 180.0);
		float glint = pow(max(dot(n_view, h), 0.0), 900.0);
		float sparkle = 0.55 + 0.45 * vnoise(p * 9.0 + t * 1.7);
		col += sun_color * (spec * 0.55 + glint * 1.6 * sparkle) * glitter_amount * sun_energy;
	}

	// 岸边泡沫：水面不写深度，深度纹理里只有水下的地形；两者差值小就是浅滩。
	// 反向 Z 下天空的深度为 0，反投影 w 会趋近 0：必须跳过这类像素，
	// 否则整片远海都会被判成「水深为 0」而糊满泡沫。
	float depth_raw = texture(depth_tex, SCREEN_UV).r;
	vec4 vpos = INV_PROJECTION_MATRIX * vec4(vec3(SCREEN_UV, depth_raw) * 2.0 - 1.0, 1.0);
	float shore = 0.0;
	if (vpos.w > 0.0001) {
		vec3 scene_pos = vpos.xyz / vpos.w;
		float shore_delta = (-scene_pos.z) - (-VERTEX.z);
		shore = 1.0 - smoothstep(0.0, 2.6, shore_delta);
	}
	float foam_noise = vnoise(world_pos.xz * 1.6 + vec2(t * 0.4, 0.0));
	float foam = shore * smoothstep(0.32, 0.68, foam_noise + 0.22) * foam_amount;
	foam *= 1.0 - smoothstep(300.0, 900.0, cam_dist);
	col = mix(col, vec3(0.92, 0.95, 0.96), clamp(foam, 0.0, 0.85));

	// 远处接雾色：以前接深水色会在海平线压出一条暗带，和雾天对不上
	col = mix(col, haze_color, smoothstep(1200.0, 5200.0, cam_dist) * 0.95);

	ALBEDO = col;
	ROUGHNESS = 0.62;
	METALLIC = 0.0;
	// 关掉引擎镜面反射：环境 cubemap 里的云会把海面糊成白色迷彩块，
	// 太阳高光已在上面的自定义耀斑里，海面观感更可控。
	SPECULAR = 0.0;
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
}
