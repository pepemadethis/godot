/**************************************************************************/
/*  motion_blur.h                                                         */
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

#pragma once

#include "core/math/projection.h"
#include "servers/rendering/renderer_rd/shaders/effects/motion_blur.glsl.gen.h"
#include "servers/rendering/renderer_rd/storage_rd/render_scene_buffers_rd.h"

namespace RendererRD {

// Camera and per-object motion blur from the velocity buffer: McGuire et al.
// 2012's reconstruction filter with Jimenez 2014's changes (see motion_blur.glsl).
class MotionBlur {
public:
	struct Parameters {
		// Blur the upscaled texture (FSR2, MetalFX) instead of the internal one.
		bool use_upscaled_texture = false;
		// Fraction of the frame interval the shutter stays open.
		float shutter = 0.5;
		// Read the exclusion mask the scene shader writes into the velocity buffer.
		bool use_mask = false;

		float z_near = 0.05;
		float z_far = 4000.0;
		bool orthogonal = false;

		Projection cam_projection;
		Transform3D cam_transform;
		Projection prev_cam_projection;
		Transform3D prev_cam_transform;
	};

	MotionBlur();
	~MotionBlur();

	void process(Ref<RenderSceneBuffersRD> p_render_buffers, const Parameters &p_params);

private:
	enum Mode {
		MODE_RESOLVE_VELOCITY,
		MODE_TILE_MAX,
		MODE_NEIGHBOR_MAX,
		MODE_BLUR,
		MODE_MAX,
	};

	enum {
		FLAG_ORTHOGONAL = 1 << 0,
		FLAG_USE_MASK = 1 << 1,
	};

	struct PushConstant {
		float reprojection[16];
		float velocity_scale[2];
		int32_t color_size[2];
		int32_t velocity_size[2];
		int32_t tile_count[2];
		float max_radius;
		float z_near;
		float z_far;
		uint32_t flags;
		uint32_t max_pairs;
		uint32_t max_fast_pairs;
	};
	static_assert(sizeof(PushConstant) == 120);

	MotionBlurShaderRD motion_blur_shader;
	RID shader_version;
	RID pipelines[MODE_MAX];
};

} // namespace RendererRD
