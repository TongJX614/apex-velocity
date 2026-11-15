shader_type canvas_item;
// 合并后处理：轻微速度径向拉丝 + 全画面轻度锐化。
//
// 关键：screen_tex 必须是 filter_linear（不带 mipmap）。之前用
// filter_linear_mipmap 做 14 次径向采样，屏幕纹理被反复取到低 mip，
// 高频沥青纹理就变成块状噪点 / 马赛克。采样源固定为原分辨率。
// 中心区域（车身 + 前方路面）保持清晰，只在画面边缘做拉丝。

uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear;
uniform float amount : hint_range(0.0, 1.0) = 0.0;
uniform float sharpen : hint_range(0.0, 1.0) = 0.35;
uniform int taps : hint_range(4, 12) = 12;
uniform vec2 texel = vec2(0.000625, 0.001111);
uniform vec2 focus = vec2(0.5, 0.43);
uniform vec2 resolution = vec2(1920.0, 1080.0);

// 逐图电影调色：只改色相/冷暖，不动曝光（曝光由 Environment 控制，
// 夜城亮度是拍板值，不能在这里二次提亮）。
uniform float grade_mix : hint_range(0.0, 1.0) = 0.0;
uniform float grade_temp : hint_range(-1.0, 1.0) = 0.0;
uniform vec3 grade_shadow = vec3(0.0);
uniform vec3 grade_highlight = vec3(1.0);
uniform float film_grain : hint_range(0.0, 0.05) = 0.0;

vec3 apply_grade(vec3 col, vec2 uv) {
	if (grade_mix <= 0.001 && film_grain <= 0.0005) {
		return col;
	}
	float t = clamp(grade_temp, -1.0, 1.0);
	col.r *= 1.0 + t * 0.085;
	col.b *= 1.0 - t * 0.105;
	col.g *= 1.0 + abs(t) * 0.008;

	float luma = dot(col, vec3(0.2126, 0.7152, 0.0722));
	float shadow_w = 1.0 - smoothstep(0.02, 0.55, luma);
	float high_w = smoothstep(0.40, 0.98, luma);
	// 只偏色相、保持亮度：乘以原色会让暗部一起压黑，分离调色变成加暗。
	vec3 s_tint = grade_shadow - vec3(dot(grade_shadow, vec3(0.2126, 0.7152, 0.0722)));
	vec3 h_tint = grade_highlight - vec3(dot(grade_highlight, vec3(0.2126, 0.7152, 0.0722)));
	col += s_tint * shadow_w * grade_mix * 0.16;
	col += h_tint * high_w * grade_mix * 0.10;

	if (film_grain > 0.0005) {
		float n = fract(sin(dot(uv * resolution + vec2(TIME * 37.0, TIME * 17.0),
			vec2(12.9898, 78.233))) * 43758.5453);
		col += (n - 0.5) * film_grain;
	}
	return clamp(col, vec3(0.0), vec3(1.0));
}

vec3 tap(vec2 uv) {
	return texture(screen_tex, clamp(uv, vec2(0.001), vec2(0.999))).rgb;
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec3 base = tap(uv);
	vec3 col = base;

	if (amount > 0.0015) {
		vec2 dir = uv - focus;
		float radius = length(dir);
		float edge = smoothstep(0.20, 0.72, radius);
		float strength = amount * 0.068 * (0.18 + edge * 0.82);
		vec2 unit = dir / max(radius, 0.08);
		vec3 acc = vec3(0.0);
		float wsum = 0.0;
		int n = clamp(taps, 4, 12);
		for (int i = 0; i < 12; i++) {
			if (i >= n) {
				break;
			}
			float t = float(i) / float(n - 1) - 0.5;
			float w = 1.0 - abs(t) * 1.5;
			acc += tap(uv + unit * (t * strength)) * w;
			wsum += w;
		}
		col = mix(base, acc / max(wsum, 0.001), clamp(amount * edge * 0.95, 0.0, 0.78));
	}

	// Unsharp mask：抵消 TAA / 升频带来的软化，让远处建筑与山脊更清楚。
	// 结果夹在 4 邻域范围内：强度提高时不会在亮暗边缘拉出白边/黑边。
	if (sharpen > 0.001) {
		vec3 n = tap(uv + vec2(0.0, -texel.y));
		vec3 s = tap(uv + vec2(0.0, texel.y));
		vec3 w = tap(uv + vec2(-texel.x, 0.0));
		vec3 e = tap(uv + vec2(texel.x, 0.0));
		vec3 blur = (n + s + w + e) * 0.25;
		vec3 mn = min(col, min(min(n, s), min(w, e)));
		vec3 mx = max(col, max(max(n, s), max(w, e)));
		vec3 sharpened = col + (col - blur) * sharpen * 1.15;
		col = clamp(sharpened, mn, mx);
	}

	col = apply_grade(col, uv);
	COLOR = vec4(col, 1.0);
}
