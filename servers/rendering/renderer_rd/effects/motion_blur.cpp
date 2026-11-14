/**************************************************************************/
/*  motion_blur.cpp                                                       */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md). */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                  */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining  */
/* a copy of this software and associated documentation files (the        */
/* "Software"), to deal in the Software without restriction, including    */
/* without limitation the rights to use, copy, modify, merge, publish,    */
/* distribute, sublicense, and/or sell copies of the Software, and to     */
/* permit persons to whom the Software is furnished to do so, subject to  */
/* the following conditions:                                              */
/*                                                                        */
/* The above copyright notice and this permission notice shall be         */
/* included in all copies or substantial portions of the Software.        */
/*                                                                        */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,        */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,   */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE      */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

#include "motion_blur.h"

#include "servers/rendering/renderer_rd/effects/copy_effects.h"
#include "servers/rendering/renderer_rd/storage_rd/material_storage.h"
#include "servers/rendering/renderer_rd/uniform_set_cache_rd.h"

using namespace RendererRD;

// Largest blur vector (half the exposure's motion), as a share of the output
// height: about 43 pixels at 1080p. It is also the tile size of the tile max
// and neighbour max passes, as in McGuire et al. 2012.
static constexpr float MAX_RADIUS_SHARE = 0.04;
// Sample pairs per pixel at most, per direction where depth order matters and
// where the whole neighbourhood moves alike. A blur takes one pair per pixel of
// its length up to these, so the 43-pixel limit at 1080p is jittered only past
// them; shorter blurs take fewer.
static constexpr uint32_t MAX_SAMPLE_PAIRS = 24;
static constexpr uint32_t MAX_FAST_SAMPLE_PAIRS = 36;

MotionBlur::MotionBlur() {
	Vector<String> modes;
	modes.push_back("\n#define MODE_RESOLVE_VELOCITY\n");
	modes.push_back("\n#define MODE_TILE_MAX\n");
	modes.push_back("\n#define MODE_NEIGHBOR_MAX\n");
	modes.push_back("\n#define MODE_BLUR\n");
	motion_blur_shader.initialize(modes);
	shader_version = motion_blur_shader.version_create();
	for (int i = 0; i < MODE_MAX; i++) {
		pipelines[i] = RD::get_singleton()->compute_pipeline_create(motion_blur_shader.version_get_shader(shader_version, i));
	}
}

MotionBlur::~MotionBlur() {
	motion_blur_shader.version_free(shader_version);
}

void MotionBlur::process(Ref<RenderSceneBuffersRD> p_render_buffers, const Parameters &p_params) {
	UniformSetCacheRD *uniform_set_cache = UniformSetCacheRD::get_singleton();
	ERR_FAIL_NULL(uniform_set_cache);
	MaterialStorage *material_storage = MaterialStorage::get_singleton();
	ERR_FAIL_NULL(material_storage);
	CopyEffects *copy_effects = CopyEffects::get_singleton();
	ERR_FAIL_NULL(copy_effects);

	const uint32_t view_count = p_render_buffers->get_view_count();
	const Size2i velocity_size = p_render_buffers->get_internal_size();
	const Size2i color_size = p_params.use_upscaled_texture ? p_render_buffers->get_target_size() : velocity_size;
	const RID first_color = p_params.use_upscaled_texture ? p_render_buffers->get_upscaled_texture(0) : p_render_buffers->get_internal_texture(0);
	const RD::DataFormat color_format = RD::get_singleton()->texture_get_format(first_color).format;

	const int max_radius = CLAMP(int(Math::round(color_size.height * MAX_RADIUS_SHARE)), 8, 128);
	const Size2i tile_count = Size2i((color_size.width + max_radius - 1) / max_radius, (color_size.height + max_radius - 1) / max_radius);

	const StringName context = SNAME("motion_blur");
	const StringName tile_max_name = SNAME("tile_max");
	const StringName neighbor_max_name = SNAME("neighbor_max");
	const StringName color_name = SNAME("color");
	const StringName velocity_name = SNAME("velocity");
	const StringName motion_name = SNAME("motion");
	// With MSAA, resolve the velocity here, keeping the exclusion bit exact.
	const bool msaa = p_render_buffers->has_velocity_buffer(true);

	if (p_render_buffers->has_texture(context, color_name)) {
		RD::TextureFormat tile_format = p_render_buffers->get_texture_format(context, tile_max_name);
		RD::TextureFormat blur_format = p_render_buffers->get_texture_format(context, color_name);
		if (blur_format.format != color_format || int(blur_format.width) != color_size.width || int(blur_format.height) != color_size.height || int(tile_format.width) != tile_count.width || int(tile_format.height) != tile_count.height || p_render_buffers->has_texture(context, velocity_name) != msaa) {
			p_render_buffers->clear_context(context);
		}
	}
	if (!p_render_buffers->has_texture(context, color_name)) {
		const uint32_t usage_bits = RD::TEXTURE_USAGE_SAMPLING_BIT | RD::TEXTURE_USAGE_STORAGE_BIT;
		p_render_buffers->create_texture(context, tile_max_name, RD::DATA_FORMAT_R16G16B16A16_SFLOAT, usage_bits, RD::TEXTURE_SAMPLES_1, tile_count, view_count);
		p_render_buffers->create_texture(context, neighbor_max_name, RD::DATA_FORMAT_R16G16B16A16_SFLOAT, usage_bits, RD::TEXTURE_SAMPLES_1, tile_count, view_count);
		p_render_buffers->create_texture(context, color_name, color_format, usage_bits, RD::TEXTURE_SAMPLES_1, color_size, view_count);
		// Per pixel: blur vector, linear depth, exclusion.
		p_render_buffers->create_texture(context, motion_name, RD::DATA_FORMAT_R16G16B16A16_SFLOAT, usage_bits, RD::TEXTURE_SAMPLES_1, velocity_size, view_count);
		if (msaa) {
			p_render_buffers->create_texture(context, velocity_name, RD::DATA_FORMAT_R16G16_SFLOAT, usage_bits, RD::TEXTURE_SAMPLES_1, velocity_size, view_count);
		}
	}

	PushConstant push_constant;
	memset(&push_constant, 0, sizeof(PushConstant));

	// Same reprojection as the debug view of motion vectors and FSR2's
	// fallback for pixels without a motion vector.
	Projection correction;
	correction.set_depth_correction(true, true, false);
	Projection reprojection = (correction * p_params.prev_cam_projection) * p_params.prev_cam_transform.affine_inverse() * p_params.cam_transform * (correction * p_params.cam_projection).inverse();
	MaterialStorage::store_camera(reprojection, push_constant.reprojection);

	// Velocities are per frame; a blur vector covers half of the exposure.
	push_constant.velocity_scale[0] = 0.5f * p_params.shutter * color_size.width;
	push_constant.velocity_scale[1] = 0.5f * p_params.shutter * color_size.height;
	push_constant.color_size[0] = color_size.width;
	push_constant.color_size[1] = color_size.height;
	push_constant.velocity_size[0] = velocity_size.width;
	push_constant.velocity_size[1] = velocity_size.height;
	push_constant.tile_count[0] = tile_count.width;
	push_constant.tile_count[1] = tile_count.height;
	push_constant.max_radius = max_radius;
	push_constant.z_near = p_params.z_near;
	push_constant.z_far = p_params.z_far;
	push_constant.flags = (p_params.orthogonal ? FLAG_ORTHOGONAL : 0) | (p_params.use_mask ? FLAG_USE_MASK : 0);
	push_constant.max_pairs = MAX_SAMPLE_PAIRS;
	push_constant.max_fast_pairs = MAX_FAST_SAMPLE_PAIRS;

	RID sampler = material_storage->sampler_rd_get_default(RSE::CANVAS_ITEM_TEXTURE_FILTER_NEAREST, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);
	RID linear_sampler = material_storage->sampler_rd_get_default(RSE::CANVAS_ITEM_TEXTURE_FILTER_LINEAR, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);

	for (uint32_t v = 0; v < view_count; v++) {
		RID color = p_params.use_upscaled_texture ? p_render_buffers->get_upscaled_texture(v) : p_render_buffers->get_internal_texture(v);
		RID velocity = msaa ? p_render_buffers->get_texture_slice(context, velocity_name, v, 0) : p_render_buffers->get_velocity_buffer(false, v);
		RID depth = p_render_buffers->get_depth_texture(v);
		RID tile_max = p_render_buffers->get_texture_slice(context, tile_max_name, v, 0);
		RID neighbor_max = p_render_buffers->get_texture_slice(context, neighbor_max_name, v, 0);
		RID blurred = p_render_buffers->get_texture_slice(context, color_name, v, 0);
		RID motion = p_render_buffers->get_texture_slice(context, motion_name, v, 0);

		RD::ComputeListID compute_list = RD::get_singleton()->compute_list_begin();

		if (msaa) {
			RID shader = motion_blur_shader.version_get_shader(shader_version, MODE_RESOLVE_VELOCITY);
			RD::Uniform u_velocity_multisample(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, Vector<RID>({ sampler, p_render_buffers->get_velocity_buffer(true, v) }));
			RD::Uniform u_velocity(RD::UNIFORM_TYPE_IMAGE, 1, velocity);
			RD::get_singleton()->compute_list_bind_compute_pipeline(compute_list, pipelines[MODE_RESOLVE_VELOCITY]);
			RD::get_singleton()->compute_list_bind_uniform_set(compute_list, uniform_set_cache->get_cache(shader, 0, u_velocity_multisample, u_velocity), 0);
			RD::get_singleton()->compute_list_set_push_constant(compute_list, &push_constant, sizeof(PushConstant));
			RD::get_singleton()->compute_list_dispatch_threads(compute_list, velocity_size.width, velocity_size.height, 1);
			RD::get_singleton()->compute_list_add_barrier(compute_list);
		}

		{
			RID shader = motion_blur_shader.version_get_shader(shader_version, MODE_TILE_MAX);
			RD::Uniform u_velocity(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, Vector<RID>({ sampler, velocity }));
			RD::Uniform u_depth(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, Vector<RID>({ sampler, depth }));
			RD::Uniform u_tile_max(RD::UNIFORM_TYPE_IMAGE, 2, tile_max);
			RD::Uniform u_motion(RD::UNIFORM_TYPE_IMAGE, 3, motion);
			RD::get_singleton()->compute_list_bind_compute_pipeline(compute_list, pipelines[MODE_TILE_MAX]);
			RD::get_singleton()->compute_list_bind_uniform_set(compute_list, uniform_set_cache->get_cache(shader, 0, u_velocity, u_depth, u_tile_max, u_motion), 0);
			RD::get_singleton()->compute_list_set_push_constant(compute_list, &push_constant, sizeof(PushConstant));
			// One work group per tile.
			RD::get_singleton()->compute_list_dispatch(compute_list, tile_count.width, tile_count.height, 1);
			RD::get_singleton()->compute_list_add_barrier(compute_list);
		}

		{
			RID shader = motion_blur_shader.version_get_shader(shader_version, MODE_NEIGHBOR_MAX);
			RD::Uniform u_tile_max(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, Vector<RID>({ sampler, tile_max }));
			RD::Uniform u_neighbor_max(RD::UNIFORM_TYPE_IMAGE, 1, neighbor_max);
			RD::get_singleton()->compute_list_bind_compute_pipeline(compute_list, pipelines[MODE_NEIGHBOR_MAX]);
			RD::get_singleton()->compute_list_bind_uniform_set(compute_list, uniform_set_cache->get_cache(shader, 0, u_tile_max, u_neighbor_max), 0);
			RD::get_singleton()->compute_list_set_push_constant(compute_list, &push_constant, sizeof(PushConstant));
			RD::get_singleton()->compute_list_dispatch_threads(compute_list, tile_count.width, tile_count.height, 1);
			RD::get_singleton()->compute_list_add_barrier(compute_list);
		}

		{
			RID shader = motion_blur_shader.version_get_shader(shader_version, MODE_BLUR);
			RD::Uniform u_color(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, Vector<RID>({ linear_sampler, color }));
			RD::Uniform u_motion(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, Vector<RID>({ linear_sampler, motion }));
			RD::Uniform u_neighbor_max(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 2, Vector<RID>({ sampler, neighbor_max }));
			RD::Uniform u_blurred(RD::UNIFORM_TYPE_IMAGE, 3, blurred);
			RD::get_singleton()->compute_list_bind_compute_pipeline(compute_list, pipelines[MODE_BLUR]);
			RD::get_singleton()->compute_list_bind_uniform_set(compute_list, uniform_set_cache->get_cache(shader, 0, u_color, u_motion, u_neighbor_max, u_blurred), 0);
			RD::get_singleton()->compute_list_set_push_constant(compute_list, &push_constant, sizeof(PushConstant));
			RD::get_singleton()->compute_list_dispatch_threads(compute_list, color_size.width, color_size.height, 1);
		}

		RD::get_singleton()->compute_list_end();

		copy_effects->copy_to_rect(blurred, color, Rect2i(0, 0, color_size.width, color_size.height));
	}
}
