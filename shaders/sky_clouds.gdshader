shader_type sky;
// Procedural sky with animated FBM clouds, sun disc/glow, night stars and a
// theme tint. Used by every circuit; uniforms are driven by the legacy track
// theme data so no HDRI/asset downloads are needed.

uniform vec3 top_color : source_color = vec3(0.11, 0.38, 0.71);
uniform vec3 horizon_color : source_color = vec3(0.85, 0.93, 0.95);
uniform vec3 ground_color : source_color = vec3(0.56, 0.78, 0.82);
uniform vec3 sun_color : source_color = vec3(1.0, 0.95, 0.85);
uniform vec3 cloud_light : source_color = vec3(1.0, 1.0, 1.0);
uniform vec3 cloud_shadow : source_color = vec3(0.42, 0.47, 0.55);
uniform float sun_size : hint_range(0.005, 0.25) = 0.04;
uniform float sun_glow : hint_range(0.0, 3.0) = 0.6;
uniform float cloud_coverage : hint_range(0.0, 1.0) = 0.45;
uniform float cloud_opacity : hint_range(0.0, 1.0) = 0.9;
uniform float cloud_scale : hint_range(0.1, 8.0) = 1.5;
uniform float cloud_speed = 0.01;
uniform float night : hint_range(0.0, 1.0) = 0.0;
uniform float stars_amount : hint_range(0.0, 1.0) = 0.0;
uniform float horizon_softness : hint_range(0.05, 1.0) = 0.55;
uniform float haze_strength : hint_range(0.0, 1.0) = 0.35;
uniform int cloud_octaves : hint_range(2, 5) = 5;
uniform float cloud_detail : hint_range(0.0, 1.0) = 1.0;
uniform float cirrus_amount : hint_range(0.0, 1.0) = 0.55;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
	float value = 0.0;
	float amplitude = 0.5;
	int octaves = clamp(cloud_octaves, 2, 5);
	for (int i = 0; i < 5; i++) {
		if (i >= octaves) {
			break;
		}
		value += amplitude * value_noise(p);
		p = p * 2.03 + vec2(17.1, 9.3);
		amplitude *= 0.5;
	}
	return value;
}

void sky() {
	vec3 dir = EYEDIR;
	float y = dir.y;

	// base gradient
	vec3 col = mix(horizon_color, top_color, smoothstep(0.0, horizon_softness + 0.45, y));
	if (y < 0.0) {
		col = mix(horizon_color, ground_color, smoothstep(0.0, 0.2, -y));
	}

	// horizon haze band
	float haze = exp(-abs(y) * 18.0) * haze_strength;
	col = mix(col, horizon_color, haze * 0.6);

	// ---- sun / moon ----
	float sun_amount = 0.0;
	if (LIGHT0_ENABLED) {
		sun_amount = max(dot(dir, LIGHT0_DIRECTION), 0.0);
		float glow = pow(sun_amount, 40.0) * sun_glow * (1.0 - 0.55 * night);
		col += sun_color * glow;
		float disc = smoothstep(1.0 - sun_size, 1.0 - sun_size * 0.4, sun_amount);
		col = mix(col, sun_color, disc);
		// 米氏散射：日落/日出时太阳周围沿地平线铺开的暖光
		float low_sky = pow(clamp(1.0 - y, 0.0, 1.0), 4.0);
		col += sun_color * pow(sun_amount, 3.0) * low_sky * 0.16 * (1.0 - night);
		// 白天太阳附近的空气透视散射，天空不再是均匀蓝
		col += sun_color * pow(sun_amount, 8.0) * 0.07 * (1.0 - night);
	}

	// ---- stars ----
	if (stars_amount > 0.01 && y > 0.015) {
		vec2 suv = vec2(atan(dir.z, dir.x), asin(clamp(y, -1.0, 1.0))) * 120.0;
		vec2 cell = floor(suv);
		float s = hash21(cell);
		float twinkle = 0.55 + 0.45 * sin(TIME * 2.2 + s * 120.0);
		float star = smoothstep(0.994, 1.0, s);
		// 星点分冷暖色，避免夜空是一层均匀白噪点
		vec3 star_col = mix(vec3(0.72, 0.82, 1.0), vec3(1.0, 0.88, 0.70),
			hash21(cell + 7.3));
		float star_size = 0.55 + 0.55 * hash21(cell + 3.1);
		col += star_col * star * star_size * twinkle * stars_amount
			* smoothstep(0.015, 0.25, y);
	}

	// ---- clouds: FBM projected onto a virtual plane ----
	if (y > 0.015) {
		vec2 cuv = dir.xz / max(y, 0.055);
		vec2 drift = vec2(TIME * cloud_speed, TIME * cloud_speed * 0.55);
		float n = fbm(cuv * cloud_scale + drift);
		float density = n;
		if (cloud_detail > 0.5) {
			float n2 = fbm(cuv * cloud_scale * 2.7 - drift * 1.6);
			density = n * 0.68 + n2 * 0.32;
		}
		float cover = smoothstep(1.0 - cloud_coverage, 1.0 - cloud_coverage + 0.11, density);
		float fade = smoothstep(0.0, 0.16, y);
		// 夜间云层压暗成蓝灰色，不再是一层发白的贴片
		vec3 lit_col = mix(cloud_light, cloud_light * vec3(0.26, 0.30, 0.42), night);
		vec3 dark_col = mix(cloud_shadow, cloud_shadow * vec3(0.30, 0.34, 0.46), night);
		// cheaper fake lighting: bright edges toward the sun, dark undersides
		vec3 cloud_col = mix(dark_col, lit_col,
			0.28 + sun_amount * 1.1 + (1.0 - night) * 0.2);
		cloud_col = mix(cloud_col, sun_color, pow(sun_amount, 6.0) * 0.6);
		// 银边：云团稀薄的外缘被太阳照透
		float rim = smoothstep(0.02, 0.30, cover) * (1.0 - smoothstep(0.40, 0.85, cover));
		cloud_col += sun_color * rim * pow(sun_amount, 5.0) * 0.45 * (1.0 - night);
		col = mix(col, cloud_col, cover * fade * cloud_opacity);

		// 高层卷云：低密度、拉长、漂移更快，和底层积云形成视差和层次。
		// 只在云层细节开启的档位计算（低档省掉这层）。
		if (cloud_detail > 0.5) {
			vec2 cir_p = cuv * 3.1 + vec2(TIME * cloud_speed * 2.4, TIME * cloud_speed * 1.15);
			float cir = value_noise(cir_p) * 0.62 + value_noise(cir_p * 2.13 + vec2(11.3, 7.7)) * 0.38;
			float streak = smoothstep(0.56, 0.84, cir) * (1.0 - smoothstep(0.9, 1.0, cir));
			vec3 cir_col = mix(dark_col, lit_col, 0.55 + 0.45 * sun_amount);
			cir_col = mix(cir_col, sun_color, pow(sun_amount, 4.0) * 0.35 * (1.0 - night));
			// 积云厚的地方盖住卷云，只有云缝里露出来
			float gap = 1.0 - cover * 0.80;
			col = mix(col, cir_col, streak * 0.26 * cirrus_amount * gap
				* smoothstep(0.03, 0.30, y));
		}
	}

	COLOR = col;
}
