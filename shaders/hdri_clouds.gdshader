shader_type sky;
// Photoreal HDRI sky for the coast + a procedurally animated FBM cloud layer
// drifting across it, so the sky is not a frozen panorama.

uniform sampler2D panorama : source_color, filter_linear, repeat_enable;
uniform vec3 cloud_light : source_color = vec3(0.94, 0.95, 0.97);
uniform vec3 cloud_shadow : source_color = vec3(0.62, 0.66, 0.72);
uniform float cloud_coverage : hint_range(0.0, 1.0) = 0.45;
uniform float cloud_opacity : hint_range(0.0, 1.0) = 0.55;
uniform float cloud_scale = 0.55;
uniform float cloud_speed = 0.012;
uniform float horizon_softness = 0.22;
uniform float sky_brightness : hint_range(0.0, 1.5) = 0.65;
uniform int cloud_octaves : hint_range(2, 5) = 5;
uniform float night : hint_range(0.0, 1.0) = 0.0;
uniform float stars_amount : hint_range(0.0, 1.0) = 0.0;
uniform vec3 haze_color : source_color = vec3(0.72, 0.80, 0.86);
uniform float haze_strength : hint_range(0.0, 1.0) = 0.35;
uniform vec3 sun_color : source_color = vec3(1.0, 0.95, 0.86);

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise2(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash(i);
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
	float sum = 0.0;
	float amp = 0.55;
	int octaves = clamp(cloud_octaves, 2, 5);
	for (int i = 0; i < 5; i++) {
		if (i >= octaves) {
			break;
		}
		sum += amp * noise2(p);
		p = p * 2.03 + vec2(17.0, 31.0);
		amp *= 0.5;
	}
	return sum;
}

void sky() {
	vec3 dir = normalize(EYEDIR);
	float u = 0.5 + atan(dir.z, dir.x) / 6.2831853;
	float v = acos(clamp(dir.y, -1.0, 1.0)) / 3.14159265;
	vec3 base = texture(panorama, vec2(u, v)).rgb * sky_brightness;

	// 夜色：把白天的 HDRI 压成冷蓝夜空，雪原/极夜地图不再挂一张白昼全景
	vec3 night_tint = base * vec3(0.20, 0.27, 0.52) + vec3(0.008, 0.014, 0.032);
	base = mix(base, night_tint, night * 0.82);

	// 地平线霾带，和场景雾色衔接
	float haze = exp(-abs(dir.y) * 15.0) * haze_strength * (1.0 - night * 0.45);
	base = mix(base, haze_color, haze * 0.30);
	// 地平线以下：HDRI 全景自带的草地会在海面尽头露出一条绿带，
	// 这里按雾色压掉，让海平线外只剩空气透视。过渡结束在 y=0，
	// 否则海面（雾色）与天空（照片余晖）之间会剩一道硬缝。
	float below = 1.0 - smoothstep(-0.025, 0.002, dir.y);
	base = mix(base, haze_color, below);

	float sun_amount = 0.0;
	if (LIGHT0_ENABLED) {
		sun_amount = max(dot(dir, LIGHT0_DIRECTION), 0.0);
		float low_sky = pow(clamp(1.0 - dir.y, 0.0, 1.0), 4.0);
		base += sun_color * pow(sun_amount, 3.0) * low_sky * 0.10 * (1.0 - night);
	}

	// projection of the drifting cloud plane (fades out under the horizon)
	float above = smoothstep(-0.02, horizon_softness, dir.y);
	vec2 p = dir.xz / max(dir.y + 0.18, 0.12) * cloud_scale;
	p += vec2(TIME * cloud_speed, TIME * cloud_speed * 0.35);
	float cloud = fbm(p);
	float cov = smoothstep(1.0 - cloud_coverage * 0.85, 1.05 - cloud_coverage * 0.2, cloud);
	vec3 lit_col = mix(cloud_light, cloud_light * vec3(0.28, 0.32, 0.44), night);
	vec3 dark_col = mix(cloud_shadow, cloud_shadow * vec3(0.30, 0.34, 0.46), night);
	vec3 cloud_color = mix(dark_col, lit_col,
		smoothstep(0.35, 0.85, cloud) * 0.75 + sun_amount * 0.5);
	cloud_color = mix(cloud_color, sun_color, pow(sun_amount, 6.0) * 0.35 * (1.0 - night));
	vec3 sky_color = mix(base, cloud_color, cov * cloud_opacity * above);

	// 星点
	if (stars_amount > 0.01 && dir.y > 0.015) {
		vec2 suv = vec2(atan(dir.z, dir.x), asin(clamp(dir.y, -1.0, 1.0))) * 130.0;
		vec2 cell = floor(suv);
		float s = hash(cell);
		float twinkle = 0.55 + 0.45 * sin(TIME * 2.0 + s * 110.0);
		vec3 star_col = mix(vec3(0.72, 0.82, 1.0), vec3(1.0, 0.88, 0.70), hash(cell + 7.3));
		float star = smoothstep(0.993, 1.0, s) * (0.6 + 0.6 * hash(cell + 3.1));
		sky_color += star_col * star * twinkle * stars_amount
			* smoothstep(0.015, 0.25, dir.y) * (1.0 - cov * 0.85);
	}

	COLOR = sky_color;
}
