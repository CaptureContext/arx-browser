#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

/// Cheap helpers for the homepage's shaders. Every noise is value noise with at most four
/// octaves, so a full-viewer shader stays light enough to idle on a laptop.
namespace emptypage {
	inline float hash(float2 p) {
		p = fract(p * float2(234.34, 435.345));
		p += dot(p, p + 34.23);
		return fract(p.x * p.y);
	}

	inline float2 hash2(float2 p) {
		float n = hash(p);
		return float2(n, hash(p + n + 17.17));
	}

	inline float noise(float2 p) {
		float2 i = floor(p);
		float2 f = fract(p);
		float2 u = f * f * (3.0 - 2.0 * f);
		return mix(
			mix(hash(i), hash(i + float2(1, 0)), u.x),
			mix(hash(i + float2(0, 1)), hash(i + float2(1, 1)), u.x),
			u.y
		);
	}

	inline float fbm(float2 p, int octaves = 4) {
		float value = 0.0;
		float amplitude = 0.5;
		for (int i = 0; i < octaves; i++) {
			value += amplitude * noise(p);
			p = p * 2.03 + 17.1;
			amplitude *= 0.5;
		}
		return value;
	}

	/// Position relative to the center, in units of the shorter side.
	inline float2 centered(float2 position, float2 size) {
		return (position - size * 0.5) / min(size.x, size.y);
	}

	/// The page gradient behind web content, top to bottom.
	inline float3 page(float2 position, float2 size, half4 top, half4 bottom) {
		return mix(float3(top.rgb), float3(bottom.rgb), saturate(position.y / size.y));
	}

	/// A premultiplied color for drawing over the page.
	inline half4 over(float3 color, float alpha) {
		float a = saturate(alpha);
		return half4(half3(color * a), half(a));
	}

	inline half4 opaque(float3 color) {
		return half4(half3(saturate(color)), 1.0h);
	}

	inline float3 rgb(half4 color) {
		return float3(color.rgb);
	}

	/// Distance from `p` to the segment `a`–`b`.
	inline float segment(float2 p, float2 a, float2 b) {
		float2 pa = p - a;
		float2 ba = b - a;
		float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-4));
		return length(pa - ba * h);
	}
}

// The homepage's shaders: its background, ink, cursor-free effects on the mark. They start
// from the page's own gradient where they fill the viewer, so light and dark keep its brightness.

constant float3 emptyPagePink = float3(0.93, 0.56, 0.78);

// 25. Sparse stars that twinkle, fading toward the edges.
[[stitchable]] half4 emptyPageSparkles(float2 position, half4 color, float2 size, float time, half4 tint, float dark) {
	float cell = 30.0;
	float2 id = floor(position / cell);
	float h = emptypage::hash(id);
	float2 offset = (emptypage::hash2(id + 3.1) - 0.5) * 0.6;
	float2 q = (fract(position / cell) - 0.5 - offset) * cell;
	float twinkle = pow(0.5 + 0.5 * sin(time * (0.5 + h * 1.2) + h * 40.0), 3.0);
	float star = (1.0 - smoothstep(0.4, 2.0, length(q))) * step(0.4, h);
	float2 aq = abs(q);
	float flare = ((1.0 - smoothstep(0.0, 0.8, aq.x)) * (1.0 - smoothstep(0.0, 8.0, aq.y))
		+ (1.0 - smoothstep(0.0, 0.8, aq.y)) * (1.0 - smoothstep(0.0, 8.0, aq.x))) * step(0.8, h);
	float vignette = 1.0 - smoothstep(0.1, 0.75, length(emptypage::centered(position, size)));
	return emptypage::over(emptypage::rgb(tint), (star + flare * 0.8) * twinkle * vignette * mix(0.95, 0.9, dark));
}

// 27. A hologram: split color channels, scanlines and an occasional flicker.
[[stitchable]] half4 emptyPageHologram(float2 position, SwiftUI::Layer layer, float time, half4 tint, float dark) {
	float shift = 1.2 + sin(time * 1.3) * 0.8;
	float glitch = step(0.96, emptypage::hash(float2(floor(time * 6.0), floor(position.y / 6.0))));
	float2 jitter = float2(glitch * 4.0, 0.0);
	float red = layer.sample(position + jitter + float2(shift, 0)).a;
	float base = layer.sample(position + jitter).a;
	float blue = layer.sample(position + jitter - float2(shift, 0)).a;
	float scan = 0.72 + 0.28 * sin(position.y * 1.7 - time * 5.0);
	float3 color = float3(0.95, 0.45, 0.7) * red * 0.5
		+ float3(0.4, 0.65, 1.0) * blue * 0.5
		+ emptypage::rgb(tint) * base;
	// On a light page the same colors read as a pale smudge, so they deepen.
	color *= mix(0.62, 1.0, dark);
	float alpha = max(max(red, blue) * 0.6, base) * scan;
	return half4(half3(color * scan), half(alpha));
}

// 30. A glass mark: lit edges and a highlight that sweeps across now and then.
[[stitchable]] half4 emptyPageGlass(float2 position, SwiftUI::Layer layer, float2 size, float time, float dark) {
	half4 color = layer.sample(position);
	if (color.a < 0.002h) {
		return color;
	}
	float e = 1.5;
	float ax = layer.sample(position + float2(e, 0)).a - layer.sample(position - float2(e, 0)).a;
	float ay = layer.sample(position + float2(0, e)).a - layer.sample(position - float2(0, e)).a;
	float edge = saturate(length(float2(ax, ay)) * 0.8);
	float2 uv = position / size;
	float sweep = fract(time * 0.11) * 3.0 - 1.0;
	float band = 1.0 - smoothstep(0.0, 0.09, abs((uv.x + uv.y) * 0.5 - sweep));
	float rim = edge * saturate(0.4 - ay * 0.8 - ax * 0.4);
	float light = band * 0.55 + rim * 0.7;
	half3 rgb = color.rgb + half3(half(light)) * color.a * half(mix(0.85, 0.6, dark));
	return half4(rgb, color.a);
}

// 43. A magnetic grid: dots shy away from the pointer, and gather in while pressed.
[[stitchable]] float2 emptyPageMagnet(float2 position, float2 pointer, float active, float pressed) {
	float2 delta = position - pointer;
	float d = length(delta);
	float pull = exp(-d * d / (130.0 * 130.0)) * active;
	float direction = mix(1.0, -1.4, pressed);
	return position - delta * pull * 0.45 * direction;
}

// 42. A pond: pressing drops a stone, hovering leaves a slight dimple.
[[stitchable]] float2 emptyPagePond(float2 position, float time, float2 pointer, float active, float3 click) {
	float2 offset = 0.0;
	float age = time - click.z;
	if (age >= 0.0 && age < 4.0) {
		float2 delta = position - click.xy;
		float d = length(delta);
		float wave = sin(d * 0.07 - age * 9.0) * exp(-age * 0.9) * exp(-d * 0.004) * (1.0 - smoothstep(age * 260.0 - 80.0, age * 260.0 + 40.0, d));
		offset += normalize(delta + 1e-4) * wave * 9.0;
	}
	float2 hover = position - pointer;
	float hd = length(hover);
	offset += normalize(hover + 1e-4) * exp(-hd * hd / 3600.0) * 6.0 * active * sin(hd * 0.12 - time * 3.0);
	return position + offset;
}

// 39. Stars streaming slowly out of the middle.
[[stitchable]] half4 emptyPageWarp(float2 position, half4 color, float2 size, float time, half4 top, half4 bottom, half4 tint, float dark) {
	float2 p = emptypage::centered(position, size);
	float radius = length(p);
	float angle = atan2(p.y, p.x);
	float3 result = emptypage::page(position, size, top, bottom);
	float3 starColor = mix(emptypage::rgb(tint) * 0.6, float3(0.92, 0.9, 1.0), dark);
	float sectors = 90.0;
	for (int layer = 0; layer < 3; layer++) {
		float offset = float(layer) * 0.37;
		float sector = floor((angle / 6.2831 + 0.5) * sectors + offset * 13.0);
		float seed = emptypage::hash(float2(sector, float(layer)));
		float travel = fract(seed * 7.0 + time * (0.025 + seed * 0.03));
		float starRadius = travel * travel * 0.9 + 0.04;
		float sectorAngle = ((sector + 0.5) / sectors - 0.5) * 6.2831 - offset * 13.0 / sectors * 6.2831;
		float2 star = float2(cos(sectorAngle), sin(sectorAngle)) * starRadius;
		float2 tail = star * (1.0 - 0.06 * travel);
		float d = emptypage::segment(p, tail, star) * min(size.x, size.y);
		float brightness = (1.0 - smoothstep(0.0, 1.4 + travel, d)) * smoothstep(0.0, 0.2, travel) * step(0.45, seed);
		result = mix(result, starColor, brightness * mix(0.5, 0.85, dark));
	}
	result = mix(result, emptypage::rgb(tint), exp(-radius * 6.0) * 0.18);
	return emptypage::opaque(result);
}

// 38. Two colored lights wandering over film grain.
[[stitchable]] half4 emptyPageFilm(float2 position, half4 color, float2 size, float time, half4 top, half4 bottom, half4 tint, float dark) {
	float2 uv = position / size;
	float aspect = size.x / size.y;
	float2 a = float2(0.3 + 0.12 * sin(time * 0.13), 0.35 + 0.1 * cos(time * 0.11));
	float2 b = float2(0.72 + 0.1 * cos(time * 0.09), 0.68 + 0.12 * sin(time * 0.12));
	float la = exp(-length((uv - a) * float2(aspect, 1.0)) * 2.6);
	float lb = exp(-length((uv - b) * float2(aspect, 1.0)) * 2.4);
	float3 result = emptypage::page(position, size, top, bottom);
	result = mix(result, emptypage::rgb(tint), la * mix(0.45, 0.5, dark));
	result = mix(result, emptyPagePink, lb * mix(0.3, 0.35, dark));
	float grain = emptypage::hash(floor(position) + floor(time * 24.0) * 1.37) - 0.5;
	return emptypage::opaque(result + grain * mix(0.035, 0.045, dark));
}

// 37. Folds of silk that ripple slowly.
[[stitchable]] half4 emptyPageSilk(float2 position, half4 color, float2 size, float time, half4 top, half4 bottom, half4 tint, float dark) {
	float2 uv = position / size;
	float t = time * 0.18;
	float fold = sin(uv.x * 3.0 + sin(uv.y * 2.0 + t) * 1.5 + t)
		+ 0.5 * sin(uv.x * 7.0 - uv.y * 3.0 + t * 1.6)
		+ 0.25 * sin(uv.y * 11.0 + uv.x * 2.0 - t * 2.0);
	float slope = cos(uv.x * 3.0 + sin(uv.y * 2.0 + t) * 1.5 + t);
	float light = 0.5 + 0.5 * fold / 1.75;
	float sheen = pow(saturate(slope * 0.5 + 0.5), 6.0);
	float3 page = emptypage::page(position, size, top, bottom);
	float3 silk = mix(page, emptypage::rgb(tint), light * mix(0.3, 0.38, dark));
	silk += sheen * mix(0.08, 0.06, dark);
	return emptypage::opaque(silk);
}

// 35. A topographic map whose contours drift.
[[stitchable]] half4 emptyPageTopography(float2 position, half4 color, float2 size, float time, half4 top, half4 bottom, half4 tint, float dark) {
	float scale = 1.0 / 340.0;
	float2 drift = float2(time * 0.02, -time * 0.012);
	float levels = 16.0;
	float n = emptypage::fbm(position * scale + drift) * levels;
	float nx = emptypage::fbm((position + float2(1, 0)) * scale + drift) * levels;
	float ny = emptypage::fbm((position + float2(0, 1)) * scale + drift) * levels;
	float gradient = max(length(float2(nx - n, ny - n)), 1e-4);
	float distance = abs(fract(n + 0.5) - 0.5) / gradient;
	float major = fmod(floor(n + 0.5), 4.0) == 0.0 ? 1.0 : 0.0;
	float line = 1.0 - smoothstep(0.25, 1.0 + major * 0.5, distance);
	float3 page = emptypage::page(position, size, top, bottom);
	float3 shaded = mix(page, emptypage::rgb(tint), smoothstep(0.3, 0.75, n / levels) * 0.12);
	return emptypage::opaque(mix(shaded, emptypage::rgb(tint), line * mix(0.3, 0.38, dark) * (0.6 + major * 0.4)));
}

// A sky over the page: night in dark, day in light, with optional stars and clouds.
[[stitchable]] half4 emptyPageSky(float2 position, half4 color, float2 size, float time, half4 top, half4 bottom, float dark, float stars, float clouds) {
	float2 uv = position / size;
	float3 page = emptypage::page(position, size, top, bottom);
	float3 zenith = mix(float3(0.64, 0.75, 0.96), float3(0.08, 0.08, 0.16), dark);
	float3 horizon = mix(float3(0.99, 0.91, 0.93), float3(0.3, 0.24, 0.36), dark);
	float3 sky = mix(zenith, page, smoothstep(0.0, 1.0, uv.y));
	sky = mix(sky, horizon, exp(-pow((uv.y - 0.95) * 4.0, 2.0)) * 0.35);
	sky = mix(page, sky, 0.8);

	if (stars > 0.5) {
		float height = 1.0 - smoothstep(0.25, 0.95, uv.y);
		float3 starColor = mix(float3(0.36, 0.4, 0.62), float3(1.0, 0.97, 0.92), dark);
		for (int layer = 0; layer < 2; layer++) {
			float cell = layer == 0 ? 7.0 : 15.0;
			float2 id = floor(position / cell);
			float h = emptypage::hash(id + float(layer) * 31.0);
			float2 offset = (emptypage::hash2(id + 7.0 + float(layer)) - 0.5) * 0.7;
			float d = length((fract(position / cell) - 0.5 - offset) * cell);
			float threshold = layer == 0 ? 0.985 : 0.94;
			float radius = layer == 0 ? 0.55 : 0.95;
			float twinkle = 0.55 + 0.45 * sin(time * (0.8 + h * 2.2) + h * 50.0);
			float star = step(threshold, h) * (1.0 - smoothstep(radius * 0.4, radius + 0.7, d)) * twinkle;
			sky = mix(sky, starColor, star * height * mix(0.35, 0.95, dark));
		}
	}

	if (clouds > 0.5) {
		float2 p = float2(position.x / 460.0 + time * 0.012, position.y / 170.0);
		float n = emptypage::fbm(p + emptypage::fbm(p * 1.4 + time * 0.008, 2) * 0.7);
		float band = smoothstep(0.0, 0.3, uv.y) * (1.0 - smoothstep(0.82, 1.0, uv.y));
		float density = smoothstep(0.46, 0.78, n) * band;
		float shade = emptypage::fbm(p * 2.3 + 3.0, 2);
		float3 cloud = mix(float3(1.0), float3(0.34, 0.31, 0.42), dark) * (0.86 + 0.14 * shade);
		sky = mix(sky, cloud, density * mix(0.75, 0.6, dark));
	}

	return emptypage::opaque(sky);
}

// The ink trail with every style setting: coloring 0 is solid, 1 shifts between the two colors,
// 2 runs through the hues along the line.
[[stitchable]] half4 emptyPageInk(
	float2 position,
	half4 color,
	float time,
	device const float *trail,
	int count,
	half4 first,
	half4 second,
	float coloring,
	float width,
	float drying,
	float softness,
	float tapers,
	float opacity
) {
	// Each segment carries its endpoints' times, and width and drying are read at the nearest
	// point along it, so neighboring segments meet without seams: a slow stroke stays one line
	// instead of a row of round caps.
	int samples = count / 3;
	float alpha = 0.0;
	float3 ink = emptypage::rgb(first);
	for (int i = 1; i < samples; i++) {
		float2 a = float2(trail[(i - 1) * 3], trail[(i - 1) * 3 + 1]);
		float2 b = float2(trail[i * 3], trail[i * 3 + 1]);
		float2 pa = position - a;
		float2 ba = b - a;
		float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-4));
		float d = length(pa - ba * h);
		float sampleTime = mix(trail[(i - 1) * 3 + 2], trail[i * 3 + 2], h);
		float fade = exp(-max(time - sampleTime, 0.0) * 3.0 / max(drying, 0.05));
		float lineWidth = width * (tapers > 0.5 ? mix(0.15, 1.0, fade) : 1.0);
		float radius = lineWidth * 0.5;
		float coverage = 1.0 - smoothstep(radius * (1.0 - softness * 0.9), radius + 0.75 + softness * lineWidth, d);
		float value = coverage * fade;
		if (value > alpha) {
			alpha = value;
			if (coloring < 0.5) {
				ink = emptypage::rgb(first);
			} else if (coloring < 1.5) {
				ink = mix(emptypage::rgb(first), emptypage::rgb(second), 0.5 + 0.5 * sin(sampleTime * 1.6));
			} else {
				float hue = fract(sampleTime * 0.35);
				ink = 0.55 + 0.4 * cos(6.2831 * (hue + float3(0.0, 0.33, 0.67)));
			}
		}
	}
	return emptypage::over(ink, alpha * opacity);
}
