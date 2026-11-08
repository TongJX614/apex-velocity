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

	// Unsharp mask：抵消 TAA / 升频带来的软化，让远处建筑与山脊更清楚
	if (sharpen > 0.001) {
		vec3 blur = (tap(uv + vec2(texel.x, 0.0)) + tap(uv - vec2(texel.x, 0.0))
			+ tap(uv + vec2(0.0, texel.y)) + tap(uv - vec2(0.0, texel.y))) * 0.25;
		col = clamp(col + (col - blur) * sharpen * 0.85, vec3(0.0), vec3(1.0));
	}

	COLOR = vec4(col, 1.0);
}
