#[compute]

#version 450

#VERSION_DEFINES

// Camera and per-object motion blur from the velocity buffer.
//
// The reconstruction filter follows McGuire, Hennessy, Bukowski and Osman,
// "A Reconstruction Filter for Plausible Motion Blur", I3D 2012: the velocity
// buffer is reduced to one dominant velocity per tile (tile max), dilated to
// the neighbouring tiles (neighbour max), and each pixel then gathers samples
// along the dominant velocity of its neighbourhood, weighting each sample by
// whether it lies in front of or behind the pixel and whether its own blur
// reaches the pixel.
//
// From Jimenez, "Next Generation Post Processing in Call of Duty: Advanced
// Warfare", SIGGRAPH 2014 Advances in Real-Time Rendering: the pixel also
// gathers along its own velocity where it points elsewhere, a fast path skips
// the depth and velocity tests where the whole neighbourhood moves alike, and
// sample offsets are jittered with interleaved gradient noise where the sample
// budget cannot cover a blur at one sample per pixel.
//
// The diagonal test in the neighbour max pass (a diagonal tile only counts if
// its velocity points at this tile) is from Guertin, McGuire and
// Nowrouzezahrai, "A Fast and Stable Feature-Aware Motion Blur Filter",
// HPG 2014.
//
// Samples are one pixel apart along a blur, with filtered colour reads: the sum
// of such samples does not depend on where they start, so very bright thin
// features (lit edges, lamp strips, HDR values far above their surroundings)
// streak evenly instead of as beads or grain. Nothing after this pass smooths
// noise (it runs after TAA). To keep that affordable, the tile max pass also
// packs each pixel's blur vector, linear depth and exclusion into one texture,
// so a sample costs two reads.
//
// With MSAA the velocity is resolved here, from single samples, so that the
// exclusion bit (see is_excluded()) survives.
//
// Velocities in the velocity buffer are in UV units per frame, pointing from
// the current position to the previous one. Here they become blur vectors in
// output pixels covering half of the exposure, so a pixel is blurred from
// X - V to X + V, clamped to the tile size.

#define BLOCK_SIZE 8

layout(local_size_x = BLOCK_SIZE, local_size_y = BLOCK_SIZE, local_size_z = 1) in;

#include "motion_vector_inc.glsl"

#define FLAG_ORTHOGONAL (1 << 0)
#define FLAG_USE_MASK (1 << 1)

// Blur vectors shorter than this (in pixels) are not blurred at all.
#define MIN_BLUR 0.5
// Depth difference, relative to the nearer depth, over which a sample goes from
// "same surface" to "in front of" or "behind" (McGuire 2012's soft depth extent).
#define SOFT_DEPTH_SCALE 0.05

layout(push_constant, std430) uniform Params {
	// Current UV and depth to previous NDC, for pixels no geometry wrote a
	// velocity for (the sky, and static geometry when only moving objects
	// write velocity).
	highp mat4 reprojection;
	// UV velocity to half-exposure blur vector in output pixels.
	vec2 velocity_scale;
	ivec2 color_size;
	ivec2 velocity_size;
	ivec2 tile_count;
	// Tile size, also the largest blur vector, in output pixels.
	float max_radius;
	float z_near;
	float z_far;
	uint flags;
	// Sample pairs at most per direction of the full filter, and on the fast path.
	uint max_pairs;
	uint max_fast_pairs;
}
params;

#ifdef MODE_RESOLVE_VELOCITY

layout(set = 0, binding = 0) uniform sampler2DMS source_velocity_multisample;
layout(rg16f, set = 0, binding = 1) uniform restrict writeonly image2D velocity_image;

#endif

#ifdef MODE_TILE_MAX

layout(set = 0, binding = 0) uniform sampler2D source_velocity;
layout(set = 0, binding = 1) uniform sampler2D source_depth;
layout(rgba16f, set = 0, binding = 2) uniform restrict writeonly image2D tile_max_image;
// Per pixel: xy blur vector, z linear depth, w 1 if excluded.
layout(rgba16f, set = 0, binding = 3) uniform restrict writeonly image2D motion_image;

#endif

#ifdef MODE_NEIGHBOR_MAX

layout(set = 0, binding = 0) uniform sampler2D source_tile_max;
layout(rgba16f, set = 0, binding = 1) uniform restrict writeonly image2D neighbor_max_image;

#endif

#ifdef MODE_BLUR

layout(set = 0, binding = 0) uniform sampler2D source_color;
layout(set = 0, binding = 1) uniform sampler2D source_motion;
layout(set = 0, binding = 2) uniform sampler2D source_neighbor_max;
layout(rgba16f, set = 0, binding = 3) uniform restrict writeonly image2D dest_color;

#endif

#ifdef MODE_TILE_MAX

float linear_depth(float raw_depth) {
	float depth = raw_depth * 2.0 - 1.0;
	if (bool(params.flags & FLAG_ORTHOGONAL)) {
		return -(depth * (params.z_far - params.z_near) - (params.z_far + params.z_near)) / 2.0;
	}
	return 2.0 * params.z_near * params.z_far / (params.z_far + params.z_near + depth * (params.z_far - params.z_near));
}

// Excluded objects (first-person weapons, the player's vehicle) mark their
// velocity by setting the lowest mantissa bit of its Y half float (see the
// scene shader). Their velocity stays correct for TAA; here it counts as zero.
bool is_excluded(vec2 velocity) {
	return bool(params.flags & FLAG_USE_MASK) && (packHalf2x16(vec2(velocity.y, 0.0)) & 1u) != 0u;
}

// Half-exposure blur vector in output pixels, zero for excluded objects.
vec2 get_blur_vector(ivec2 velocity_texel, float raw_depth, out bool r_excluded) {
	vec2 velocity = texelFetch(source_velocity, velocity_texel, 0).xy;
	r_excluded = is_excluded(velocity);
	if (r_excluded) {
		return vec2(0.0);
	}
	// Not written this frame (only moving objects wrote velocity), or the sky
	// (which writes none): derive the camera's motion from depth.
	if (all(lessThanEqual(velocity, vec2(-1.0))) || (velocity == vec2(0.0) && raw_depth == 0.0)) {
		vec2 uv = (vec2(velocity_texel) + 0.5) / vec2(params.velocity_size);
		velocity = derive_motion_vector(uv, raw_depth, params.reprojection);
	}
	vec2 blur = velocity * params.velocity_scale;
	float len = length(blur);
	if (len > params.max_radius) {
		blur *= params.max_radius / len;
	}
	return blur;
}

#endif

#ifdef MODE_RESOLVE_VELOCITY

void main() {
	ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pos, params.velocity_size))) {
		return;
	}
	// With MSAA, take one sample as it is: averaging the samples, as the
	// hardware resolve does, scrambles the exclusion bit wherever two surfaces
	// share a pixel. Prefer a sample geometry wrote over the sky's (zero): the
	// averaged depth of such a pixel is not the sky's, so a zero velocity there
	// would read as geometry that does not move.
	vec2 velocity = texelFetch(source_velocity_multisample, pos, 0).xy;
	int sample_count = textureSamples(source_velocity_multisample);
	for (int i = 1; i < sample_count && velocity == vec2(0.0); i++) {
		velocity = texelFetch(source_velocity_multisample, pos, i).xy;
	}
	imageStore(velocity_image, pos, vec4(velocity, 0.0, 0.0));
}

#endif

#ifdef MODE_TILE_MAX

shared vec4 group_max[BLOCK_SIZE * BLOCK_SIZE]; // xy: longest blur vector, z: its squared length, w: shortest length.

void main() {
	// One work group per tile; its threads stride over the tile's velocity texels.
	ivec2 tile = ivec2(gl_WorkGroupID.xy);
	ivec2 local = ivec2(gl_LocalInvocationID.xy);
	uint index = gl_LocalInvocationIndex;

	vec2 to_velocity = vec2(params.velocity_size) / vec2(params.color_size);
	ivec2 begin = ivec2(floor(vec2(tile) * params.max_radius * to_velocity));
	ivec2 end = min(ivec2(ceil(vec2(tile + 1) * params.max_radius * to_velocity)), params.velocity_size);

	vec4 best = vec4(0.0, 0.0, -1.0, 1e10);
	for (int y = begin.y + local.y; y < end.y; y += BLOCK_SIZE) {
		for (int x = begin.x + local.x; x < end.x; x += BLOCK_SIZE) {
			ivec2 texel = ivec2(x, y);
			float raw_depth = texelFetch(source_depth, texel, 0).r;
			bool excluded;
			vec2 blur = get_blur_vector(texel, raw_depth, excluded);
			imageStore(motion_image, texel, vec4(blur, linear_depth(raw_depth), excluded ? 1.0 : 0.0));
			float len2 = dot(blur, blur);
			if (len2 > best.z) {
				best.xyz = vec3(blur, len2);
			}
			best.w = min(best.w, sqrt(len2));
		}
	}
	group_max[index] = best;

	memoryBarrierShared();
	barrier();

	for (uint stride = (BLOCK_SIZE * BLOCK_SIZE) / 2; stride > 0; stride >>= 1) {
		if (index < stride) {
			vec4 a = group_max[index];
			vec4 b = group_max[index + stride];
			vec4 merged = b.z > a.z ? b : a;
			merged.w = min(a.w, b.w);
			group_max[index] = merged;
		}
		memoryBarrierShared();
		barrier();
	}

	if (index == 0) {
		vec4 result = group_max[0];
		imageStore(tile_max_image, tile, vec4(result.xy, max(result.z, 0.0) > 0.0 ? sqrt(result.z) : 0.0, min(result.w, 65000.0)));
	}
}

#endif

#ifdef MODE_NEIGHBOR_MAX

void main() {
	ivec2 tile = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(tile, params.tile_count))) {
		return;
	}

	vec2 best = vec2(0.0);
	float best_len = 0.0;
	float shortest = 1e10;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			ivec2 offset = ivec2(x, y);
			ivec2 neighbor = tile + offset;
			if (any(lessThan(neighbor, ivec2(0))) || any(greaterThanEqual(neighbor, params.tile_count))) {
				continue;
			}
			vec4 data = texelFetch(source_tile_max, neighbor, 0);
			shortest = min(shortest, data.w);
			float len = data.z;
			if (len <= best_len) {
				continue;
			}
			if (x != 0 && y != 0) {
				// A diagonal tile's blur reaches this tile only if it points this way (Guertin 2014).
				float along = abs(dot(data.xy / len, normalize(vec2(offset))));
				if (along < 0.6) {
					continue;
				}
			}
			best = data.xy;
			best_len = len;
		}
	}
	imageStore(neighbor_max_image, tile, vec4(best, best_len, min(shortest, 65000.0)));
}

#endif

#ifdef MODE_BLUR

// 1 if depth a is in front of depth b (or the same surface), falling to 0 once
// a is behind b by more than the soft depth extent.
float soft_depth_compare(float a, float b) {
	return clamp(1.0 - (a - b) / (SOFT_DEPTH_SCALE * min(a, b)), 0.0, 1.0);
}

// A blur of length len covers the pixel at this distance, fading linearly.
float cone(float dist, float len) {
	return clamp(1.0 - dist / len, 0.0, 1.0);
}

// A blur of length len covers the pixel at this distance, with a soft edge.
float cylinder(float dist, float len) {
	return 1.0 - smoothstep(0.95 * len, 1.05 * len, dist);
}

// Interleaved gradient noise (Jimenez 2014).
float interleaved_gradient_noise(vec2 pos) {
	return fract(52.9829189 * fract(dot(pos, vec2(0.06711056, 0.00583715))));
}

// Colour at a sample position (in pixels), filtered.
vec3 sample_color(vec2 position) {
	vec2 clamped = clamp(position, vec2(0.5), vec2(params.color_size) - 0.5);
	return textureLod(source_color, clamped / vec2(params.color_size), 0.0).rgb;
}

ivec2 to_velocity_texel(ivec2 color_pixel, vec2 to_velocity) {
	return min(ivec2((vec2(color_pixel) + 0.5) * to_velocity), params.velocity_size - 1);
}

// One sample pair per pixel of blur, jittered only past the sample budget.
int pair_count(float len, uint budget, float noise, out float r_jitter) {
	int pairs = clamp(int(ceil(len)), 2, int(budget));
	r_jitter = len > float(pairs) ? noise : 0.0;
	return pairs;
}

// McGuire 2012's gather of samples on both sides of the pixel along one direction.
void gather(vec2 direction, int pairs, float jitter, ivec2 pos, float center_depth, float center_len, inout vec3 sum, inout float total) {
	vec2 origin = vec2(pos) + 0.5;
	for (int i = 0; i < pairs; i++) {
		float t = (float(i) + 0.5 + jitter) / float(pairs);
		vec2 offset = direction * t;
		float dist = length(offset);
		for (int side = 0; side < 2; side++) {
			vec2 sample_point = origin + (side == 0 ? offset : -offset);
			// Motion and depth are filtered like the colour: a thin moving edge then
			// weighs in by how much of it a sample covers, not all or nothing, and
			// its streak does not band where the samples drift across it.
			vec2 uv = clamp(sample_point, vec2(0.5), vec2(params.color_size) - 0.5) / vec2(params.color_size);
			vec4 motion = textureLod(source_motion, uv, 0.0);
			// Excluded objects are never smeared over their surroundings.
			float kept = 1.0 - motion.w;
			if (kept <= 0.0) {
				continue;
			}
			float sample_len = max(length(motion.xy), MIN_BLUR);
			float front = soft_depth_compare(motion.z, center_depth); // The sample is in front of the pixel.
			float back = soft_depth_compare(center_depth, motion.z); // The sample is behind the pixel.
			float weight = (front * cone(dist, sample_len) + back * cone(dist, center_len) + cylinder(dist, sample_len) * cylinder(dist, center_len) * 2.0) * kept;

			sum += sample_color(sample_point) * weight;
			total += weight;
		}
	}
}

void main() {
	ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pos, params.color_size))) {
		return;
	}

	vec4 center_color = texelFetch(source_color, pos, 0);
	ivec2 tile = min(ivec2(vec2(pos) / params.max_radius), params.tile_count - 1);
	vec4 neighborhood = texelFetch(source_neighbor_max, tile, 0);
	float max_len = neighborhood.z;
	if (max_len < MIN_BLUR) {
		imageStore(dest_color, pos, center_color);
		return;
	}

	vec2 to_velocity = vec2(params.velocity_size) / vec2(params.color_size);
	vec4 center_motion = texelFetch(source_motion, to_velocity_texel(pos, to_velocity), 0);
	if (center_motion.w > 0.5) {
		// Excluded objects stay sharp.
		imageStore(dest_color, pos, center_color);
		return;
	}
	vec2 center_blur = center_motion.xy;
	float center_blur_len = length(center_blur);
	float center_len = max(center_blur_len, MIN_BLUR);
	float noise = interleaved_gradient_noise(vec2(pos)) - 0.5;

	vec3 sum;
	float total;

	if (neighborhood.w >= max_len * 0.5) {
		// Fast path: everything in reach moves alike (within a factor of two, which
		// a fast turn's perspective needs), so depth order does not matter and the
		// pixel averages along its own velocity, weighted as the full filter
		// weights samples of one surface (cones plus cylinders: 2 - t). One read a
		// sample.
		float jitter;
		int pairs = pair_count(center_len, params.max_fast_pairs, noise, jitter);
		vec2 origin = vec2(pos) + 0.5;
		total = 2.0 / float(pairs);
		sum = center_color.rgb * total;
		for (int i = 0; i < pairs; i++) {
			float t = (float(i) + 0.5 + jitter) / float(pairs);
			vec2 offset = center_blur * t;
			float weight = 2.0 - t;
			sum += (sample_color(origin + offset) + sample_color(origin - offset)) * weight;
			total += 2.0 * weight;
		}
	} else {
		// Full filter, along the neighbourhood's dominant velocity, and along the
		// pixel's own where it points elsewhere (Jimenez 2014). Two reads a sample.
		total = 1.0 / center_len;
		sum = center_color.rgb * total;
		float jitter;
		int pairs = pair_count(max_len, params.max_pairs, noise, jitter);
		gather(neighborhood.xy, pairs, jitter, pos, center_motion.z, center_len, sum, total);
		if (center_blur_len > 1.0 && abs(dot(center_blur / center_blur_len, neighborhood.xy / max_len)) < 0.95) {
			pairs = pair_count(center_blur_len, params.max_pairs, noise, jitter);
			gather(center_blur, pairs, jitter, pos, center_motion.z, center_len, sum, total);
		}
	}

	imageStore(dest_color, pos, vec4(sum / total, center_color.a));
}

#endif
