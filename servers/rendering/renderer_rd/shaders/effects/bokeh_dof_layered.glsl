#[compute]

#version 450

#VERSION_DEFINES

// Depth of field in two layers, at half resolution, before TAA.
//
// The picture is split by the signed circle of confusion (near negative, far
// positive, in pixels, from the same focus settings as Godot's other depth of
// field) into a near layer (in front of the focus) and the rest. Each layer is
// gathered with a disk of samples (Vogel's sunflower spiral), each sample
// counting only if its own blur reaches the pixel (scatter as gather):
//
// - The far layer takes only samples that are not in front of the focus, so
//   objects in focus, and the near layer, never smear into the blurred
//   background behind them.
// - The near layer is gathered over the largest near blur around the pixel
//   (a tile max, dilated to the neighbouring tiles), with each sample weighted
//   by how far its light spreads, so a blurred foreground covers what is
//   behind it in proportion and fades out over in-focus objects instead of
//   stopping at its silhouette.
//
// A neighbour max pass then fills the gaps between samples in the near layer's
// coverage and smooths both layers, and the composite lays the far blur over
// the sharp picture by each pixel's own blur size and the near layer over that
// by its coverage. Running before TAA lets TAA clean up the sampling noise.
//
// Layered depth of field with near and far fields: Jimenez, "Next Generation
// Post Processing in Call of Duty: Advanced Warfare", SIGGRAPH 2014 Advances in
// Real-Time Rendering. Doom (2016) uses near and far layers, a half-resolution
// disk gather and a neighbour max fill (Courrèges' frame analysis, 2016).

#define BLOCK_SIZE 8

layout(local_size_x = BLOCK_SIZE, local_size_y = BLOCK_SIZE, local_size_z = 1) in;

#define FLAG_ORTHOGONAL (1 << 0)
#define FLAG_NEAR (1 << 1)
#define FLAG_FAR (1 << 2)
#define FLAG_PHYSICAL_NEAR (1 << 3)
#define FLAG_PHYSICAL_FAR (1 << 4)
#define FLAG_JITTER (1 << 5)

// Blur radii below this many full-resolution pixels count as in focus.
#define IN_FOCUS 1.0

const float GOLDEN_ANGLE = 2.39996323;

layout(push_constant, std430) uniform Params {
	ivec2 full_size;
	ivec2 half_size;

	float z_near;
	float z_far;
	uint flags;
	int sample_count;

	float near_begin;
	float near_end;
	float far_begin;
	float far_end;

	// Largest blur radius, in full-resolution pixels.
	float blur_size;
	float blur_size_near; // Physically based near and far blur scales.
	float blur_size_far;
	int tile_size; // In half-resolution pixels.

	ivec2 tile_count;
	uint frame;
	uint pad;
}
params;

#ifdef MODE_PREPARE
layout(set = 0, binding = 0) uniform sampler2D source_color;
layout(set = 0, binding = 1) uniform sampler2D source_depth;
// rgb: colour, a: signed blur radius in half-resolution pixels.
layout(rgba16f, set = 0, binding = 2) uniform restrict writeonly image2D prepared_image;
#endif

#ifdef MODE_NEAR_TILES
layout(set = 0, binding = 0) uniform sampler2D source_prepared;
layout(r16f, set = 0, binding = 1) uniform restrict writeonly image2D near_tile_image;
#endif

#ifdef MODE_NEAR_DILATE
layout(set = 0, binding = 0) uniform sampler2D source_near_tiles;
layout(r16f, set = 0, binding = 1) uniform restrict writeonly image2D near_dilated_image;
#endif

#ifdef MODE_GATHER
layout(set = 0, binding = 0) uniform sampler2D source_prepared;
layout(set = 0, binding = 1) uniform sampler2D source_near_dilated;
layout(rgba16f, set = 0, binding = 2) uniform restrict writeonly image2D far_image;
layout(rgba16f, set = 0, binding = 3) uniform restrict writeonly image2D near_image;
#endif

#ifdef MODE_FILL
layout(set = 0, binding = 0) uniform sampler2D source_far;
layout(set = 0, binding = 1) uniform sampler2D source_near;
layout(rgba16f, set = 0, binding = 2) uniform restrict writeonly image2D far_filled_image;
layout(rgba16f, set = 0, binding = 3) uniform restrict writeonly image2D near_filled_image;
#endif

#ifdef MODE_COMPOSITE
layout(rgba16f, set = 0, binding = 0) uniform restrict image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D source_depth;
layout(set = 0, binding = 2) uniform sampler2D source_far;
layout(set = 0, binding = 3) uniform sampler2D source_near;
#endif

#if defined(MODE_PREPARE) || defined(MODE_COMPOSITE)

float linear_depth(float raw_depth) {
	float depth = raw_depth * 2.0 - 1.0;
	if (bool(params.flags & FLAG_ORTHOGONAL)) {
		return -(depth * (params.z_far - params.z_near) - (params.z_far + params.z_near)) / 2.0;
	}
	return 2.0 * params.z_near * params.z_far / (params.z_far + params.z_near + depth * (params.z_far - params.z_near));
}

// Signed blur radius in full-resolution pixels (near negative), as Godot's
// other depth of field computes it, clamped to the largest radius.
float circle_of_confusion(float depth) {
	if (bool(params.flags & FLAG_NEAR) && depth < params.near_begin) {
		float size;
		if (bool(params.flags & FLAG_PHYSICAL_NEAR)) {
			float d = abs(params.near_begin - depth);
			size = (d / (params.near_begin - d)) * params.blur_size_near;
		} else {
			size = (1.0 - smoothstep(params.near_end, params.near_begin, depth)) * params.blur_size;
		}
		return -min(size, params.blur_size);
	}
	if (bool(params.flags & FLAG_FAR) && depth > params.far_begin) {
		float size;
		if (bool(params.flags & FLAG_PHYSICAL_FAR)) {
			float d = abs(params.far_begin - depth);
			size = (d / (params.far_begin + d)) * params.blur_size_far;
		} else {
			size = smoothstep(params.far_begin, params.far_end, depth) * params.blur_size;
		}
		return min(size, params.blur_size);
	}
	return 0.0;
}

#endif

#ifdef MODE_PREPARE

void main() {
	ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pos, params.half_size))) {
		return;
	}
	// Four full-resolution pixels per half-resolution one. Where any of them is
	// in front of the focus, the near ones decide, so near silhouettes are kept.
	vec3 all_sum = vec3(0.0);
	float coc_sum = 0.0;
	vec3 near_sum = vec3(0.0);
	float near_count = 0.0;
	float nearest = 0.0;
	for (int i = 0; i < 4; i++) {
		ivec2 texel = min(pos * 2 + ivec2(i & 1, i >> 1), params.full_size - 1);
		vec3 color = texelFetch(source_color, texel, 0).rgb;
		float coc = circle_of_confusion(linear_depth(texelFetch(source_depth, texel, 0).r));
		all_sum += color;
		coc_sum += coc;
		if (coc < -IN_FOCUS) {
			near_sum += color;
			near_count += 1.0;
			nearest = min(nearest, coc);
		}
	}
	vec4 prepared = near_count > 0.0 ? vec4(near_sum / near_count, nearest) : vec4(all_sum * 0.25, max(coc_sum * 0.25, 0.0));
	prepared.a *= 0.5; // Half-resolution pixels.
	imageStore(prepared_image, pos, prepared);
}

#endif

#ifdef MODE_NEAR_TILES

shared float group_max[BLOCK_SIZE * BLOCK_SIZE];

void main() {
	// One work group per tile: the largest near blur radius in it.
	ivec2 tile = ivec2(gl_WorkGroupID.xy);
	ivec2 local = ivec2(gl_LocalInvocationID.xy);
	uint index = gl_LocalInvocationIndex;

	ivec2 begin = tile * params.tile_size;
	ivec2 end = min(begin + params.tile_size, params.half_size);
	float largest = 0.0;
	for (int y = begin.y + local.y; y < end.y; y += BLOCK_SIZE) {
		for (int x = begin.x + local.x; x < end.x; x += BLOCK_SIZE) {
			largest = max(largest, -texelFetch(source_prepared, ivec2(x, y), 0).a);
		}
	}
	group_max[index] = largest;

	memoryBarrierShared();
	barrier();

	for (uint stride = (BLOCK_SIZE * BLOCK_SIZE) / 2; stride > 0; stride >>= 1) {
		if (index < stride) {
			group_max[index] = max(group_max[index], group_max[index + stride]);
		}
		memoryBarrierShared();
		barrier();
	}

	if (index == 0) {
		imageStore(near_tile_image, tile, vec4(group_max[0]));
	}
}

#endif

#ifdef MODE_NEAR_DILATE

void main() {
	// A near blur reaches at most one tile (its radius) beyond its own tile.
	ivec2 tile = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(tile, params.tile_count))) {
		return;
	}
	float largest = 0.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			ivec2 neighbor = clamp(tile + ivec2(x, y), ivec2(0), params.tile_count - 1);
			largest = max(largest, texelFetch(source_near_tiles, neighbor, 0).r);
		}
	}
	imageStore(near_dilated_image, tile, vec4(largest));
}

#endif

#ifdef MODE_GATHER

// Interleaved gradient noise (Jimenez 2014), to rotate the sample disk per pixel.
float interleaved_gradient_noise(vec2 pos) {
	return fract(52.9829189 * fract(dot(pos, vec2(0.06711056, 0.00583715))));
}

void main() {
	ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pos, params.half_size))) {
		return;
	}

	vec4 center = texelFetch(source_prepared, pos, 0);
	float near_radius = texelFetch(source_near_dilated, pos / params.tile_size, 0).r;
	float far_radius = max(center.a, 0.0);
	float in_focus = IN_FOCUS * 0.5;

	// A different rotation per pixel (and per frame with jitter, for TAA to average).
	vec2 noise_pos = vec2(pos);
	if (bool(params.flags & FLAG_JITTER)) {
		noise_pos += vec2(float(params.frame % 64u) * 5.588238, float(params.frame % 64u) * 3.137162);
	}
	float rotation = interleaved_gradient_noise(noise_pos) * 6.28318530718;
	vec2 to_uv = 1.0 / vec2(params.half_size);
	vec2 origin = vec2(pos) + 0.5;
	float count = float(params.sample_count);

	// Far layer: what is not in front of the focus, blurred by each pixel's own radius.
	vec4 far_result = vec4(center.rgb, 0.0);
	if (far_radius >= in_focus) {
		vec3 sum = center.rgb;
		float total = 1.0;
		for (int i = 0; i < params.sample_count; i++) {
			float r = sqrt((float(i) + 0.5) / count) * far_radius;
			float angle = float(i) * GOLDEN_ANGLE + rotation;
			vec4 s = textureLod(source_prepared, (origin + r * vec2(cos(angle), sin(angle))) * to_uv, 0.0);
			if (s.a < -in_focus) {
				continue; // The near layer never enters the far one.
			}
			// The sample's own blur reaches this pixel (soft over a pixel).
			float weight = clamp(s.a - r + 1.0, 0.0, 1.0);
			sum += s.rgb * weight;
			total += weight;
		}
		far_result = vec4(sum / total, 1.0);
	}

	// Near layer: over the largest near blur around, coverage by energy. Where
	// this pixel is itself in front of the focus, the samples that are not also
	// estimate what is behind it, for the composite to lay the near layer over
	// instead of the sharp foreground (its edges are semi-transparent).
	vec4 near_result = vec4(0.0);
	bool center_near = center.a < -in_focus;
	vec3 behind_sum = vec3(0.0);
	float behind_total = 0.0;
	if (near_radius >= in_focus) {
		vec3 sum = vec3(0.0);
		float total = 0.0;
		float coverage = 0.0;
		for (int i = 0; i < params.sample_count; i++) {
			float r = sqrt((float(i) + 0.5) / count) * near_radius;
			float angle = float(i) * GOLDEN_ANGLE + rotation;
			vec4 s = textureLod(source_prepared, (origin + r * vec2(cos(angle), sin(angle))) * to_uv, 0.0);
			float reach = -s.a;
			if (reach < in_focus) {
				behind_sum += s.rgb;
				behind_total += 1.0;
				continue;
			}
			// It reaches this pixel, and its light spreads over a disk of its own
			// radius: samples drawn over the larger near radius count for that much
			// more. Capped at 16 times, as a few samples of a barely blurred pixel
			// would otherwise decide the coverage alone; such pixels are nearly sharp
			// and show through the composite anyway.
			float spread = max(reach, near_radius * 0.25);
			float weight = clamp(reach - r + 1.0, 0.0, 1.0) * (near_radius * near_radius) / (spread * spread);
			sum += s.rgb * weight;
			total += weight;
			coverage += weight;
		}
		if (total > 0.0) {
			near_result = vec4(sum / total, clamp(coverage / count, 0.0, 1.0));
		}
	}
	if (center_near && behind_total > 0.0) {
		far_result = vec4(behind_sum / behind_total, 1.0);
	}

	imageStore(far_image, pos, far_result);
	imageStore(near_image, pos, near_result);
}

#endif

#ifdef MODE_FILL

void main() {
	ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pos, params.half_size))) {
		return;
	}
	// 3x3: the near layer's coverage is filled where it dips below its
	// neighbourhood, the gaps a sparse sample disk leaves (in the spirit of
	// Doom's neighbour max, without growing the layer's edges); colours are
	// smoothed with a tent, the near one weighted by coverage.
	vec4 far_center = texelFetch(source_far, pos, 0);
	vec3 far_sum = vec3(0.0);
	float far_total = 0.0;
	vec3 near_sum = vec3(0.0);
	float near_total = 0.0;
	float near_alpha_sum = 0.0;
	float tent_sum = 0.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			ivec2 p = clamp(pos + ivec2(x, y), ivec2(0), params.half_size - 1);
			float tent = (x == 0 ? 2.0 : 1.0) * (y == 0 ? 2.0 : 1.0);
			vec4 far_sample = texelFetch(source_far, p, 0);
			if (far_sample.a > 0.0) {
				far_sum += far_sample.rgb * tent;
				far_total += tent;
			}
			vec4 near_sample = texelFetch(source_near, p, 0);
			near_sum += near_sample.rgb * near_sample.a * tent;
			near_total += near_sample.a * tent;
			near_alpha_sum += near_sample.a * tent;
			tent_sum += tent;
		}
	}
	vec4 far_result = far_center.a > 0.0 && far_total > 0.0 ? vec4(far_sum / far_total, far_center.a) : far_center;
	float near_alpha = max(texelFetch(source_near, pos, 0).a, near_alpha_sum / tent_sum);
	vec4 near_result = near_total > 0.0 ? vec4(near_sum / near_total, near_alpha) : vec4(0.0);
	imageStore(far_filled_image, pos, far_result);
	imageStore(near_filled_image, pos, near_result);
}

#endif

#ifdef MODE_COMPOSITE

void main() {
	ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pos, params.full_size))) {
		return;
	}
	vec4 color = imageLoad(color_image, pos);
	float coc = circle_of_confusion(linear_depth(texelFetch(source_depth, pos, 0).r));
	vec2 uv = (vec2(pos) + 0.5) / vec2(params.full_size);

	// The far blur over the sharp picture, by this pixel's own blur size; in
	// front of the focus, what is estimated to be behind the blurred foreground.
	vec4 far_blur = textureLod(source_far, uv, 0.0);
	color.rgb = mix(color.rgb, far_blur.rgb, smoothstep(IN_FOCUS * 0.5, IN_FOCUS * 2.0, abs(coc)) * far_blur.a);

	// The near layer over everything, by its coverage.
	vec4 near_blur = textureLod(source_near, uv, 0.0);
	color.rgb = mix(color.rgb, near_blur.rgb, near_blur.a);

	imageStore(color_image, pos, color);
}

#endif
