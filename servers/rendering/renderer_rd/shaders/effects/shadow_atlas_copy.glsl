#[vertex]

#version 450

#VERSION_DEFINES

// Copies a rect of the static shadow cache into the same rect of the shadow atlas.
// The draw list's region is the rect, so this quad covers exactly that rect.

void main() {
	vec2 base_arr[4] = vec2[](vec2(0.0, 0.0), vec2(0.0, 1.0), vec2(1.0, 1.0), vec2(1.0, 0.0));
	gl_Position = vec4(base_arr[gl_VertexIndex] * 2.0 - 1.0, 0.0, 1.0);
}

#[fragment]

#version 450

#VERSION_DEFINES

layout(set = 0, binding = 0) uniform sampler2D source_depth;

void main() {
	// Both atlases share one layout, so the same pixel is read and written.
	gl_FragDepth = texelFetch(source_depth, ivec2(gl_FragCoord.xy), 0).r;
}
