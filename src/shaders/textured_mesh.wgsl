// must stay below 128 bytes to fit in push constant in dx12
struct MeshShaderCameraRaw {
    view_proj: mat4x4<f32>,
    position: vec3<f32>,
    far_plane_distance: f32,
}

var<push_constant> CAMERA: MeshShaderCameraRaw;

const MAX_LIGHTS = 32u;
const MAX_BONES = 512u;

struct PointLight {
    position: vec4<f32>,
    color: vec4<f32>,
}
struct DirectionalLight {
    world_space_to_light_space: mat4x4<f32>,
    position: vec4<f32>,
    direction: vec4<f32>,
    color: vec4<f32>,
}
struct Instance {
    model_transform_0: vec4<f32>,
    model_transform_1: vec4<f32>,
    model_transform_2: vec4<f32>,
    model_transform_3: vec4<f32>,
    base_color_factor: vec4<f32>,
    emissive_factor: vec4<f32>,
    mrno: vec4<f32>, // metallicness_factor, roughness_factor, normal scale, occlusion strength
    alpha_cutoff: vec4<f32>,
}

struct PointLightsUniform {
    values: array<PointLight, MAX_LIGHTS>,
}
struct DirectionalLightsUniform {
    values: array<DirectionalLight, MAX_LIGHTS>,
}
struct BonesUniform {
    value: array<mat4x4<f32>>,
}
struct InstancesUniform {
    value: array<Instance>,
}

@group(0) @binding(0)
var<uniform> point_lights: PointLightsUniform;
@group(0) @binding(1)
var<uniform> directional_lights: DirectionalLightsUniform;

@group(2) @binding(0)
var<storage, read> bones_uniform: BonesUniform;
@group(2) @binding(1)
var<storage, read> instances_uniform: InstancesUniform;

@group(1) @binding(0)
var<storage, read> shadow_bones_uniform: BonesUniform;
@group(1) @binding(1)
var<storage, read> shadow_instances_uniform: InstancesUniform;



struct VertexInput {
    @location(0) object_position: vec3<f32>,
    @location(1) object_normal: vec3<f32>,
    @location(2) object_tex_coords: vec2<f32>,
    @location(3) object_tangent: vec3<f32>,
    @location(4) object_bitangent: vec3<f32>,
    @location(5) object_color: vec4<f32>,
    @location(6) bone_indices: vec4<u32>,
    @location(7) bone_weights: vec4<f32>,
}

struct VertexOutput {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) world_position: vec3<f32>,
    @location(1) world_normal: vec3<f32>,
    @location(2) world_tangent: vec3<f32>,
    @location(3) world_bitangent: vec3<f32>,
    @location(4) tex_coords: vec2<f32>,
    @location(5) vertex_color: vec4<f32>,
    @location(6) base_color_factor: vec4<f32>,
    @location(7) emissive_factor: vec4<f32>,
    @location(8) metallicness_factor: f32,
    @location(9) roughness_factor: f32,
    @location(10) normal_scale: f32,
    @location(11) occlusion_strength: f32,
    @location(12) alpha_cutoff: f32,
    @location(13) object_tangent: vec3<f32>,
}

struct FragmentOutput {
    @location(0) color: vec4<f32>,
}

struct ShadowMappingVertexOutput {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) world_position: vec3<f32>,
}

struct ShadowMappingFragmentOutput {
    @builtin(frag_depth) depth: f32,
}

fn do_vertex_shade(
    vshader_input: VertexInput,
    camera_view_proj: mat4x4<f32>,
    model_transform: mat4x4<f32>,
    skin_transform: mat4x4<f32>,
    base_color_factor: vec4<f32>,
    emissive_factor: vec4<f32>,
    metallicness_factor: f32,
    roughness_factor: f32,
    normal_scale: f32,
    occlusion_strength: f32,
    alpha_cutoff: f32
) -> VertexOutput {
    var out: VertexOutput;
    out.world_normal = vshader_input.object_normal;

    let object_position = vec4<f32>(vshader_input.object_position, 1.0);
    let skinned_model_transform = model_transform * skin_transform;
    let world_position = skinned_model_transform * object_position;
    let clip_position = camera_view_proj * skinned_model_transform * object_position;
    let world_normal = normalize((skinned_model_transform * vec4<f32>(vshader_input.object_normal, 0.0)).xyz);
    let world_tangent = normalize((skinned_model_transform * vec4<f32>(vshader_input.object_tangent, 0.0)).xyz);
    let world_bitangent = normalize((skinned_model_transform * vec4<f32>(vshader_input.object_bitangent, 0.0)).xyz);

    out.clip_position = clip_position;
    out.world_position = world_position.xyz;
    out.world_normal = world_normal;
    out.world_tangent = world_tangent;
    out.object_tangent = vshader_input.object_tangent;
    out.world_bitangent = world_bitangent;
    out.tex_coords = vshader_input.object_tex_coords;
    out.vertex_color = vshader_input.object_color;
    out.base_color_factor = base_color_factor;
    out.emissive_factor = emissive_factor;
    out.metallicness_factor = metallicness_factor;
    out.roughness_factor = roughness_factor;
    out.normal_scale = normal_scale;
    out.occlusion_strength = occlusion_strength;
    out.alpha_cutoff = alpha_cutoff;

    return out;
}

@vertex
fn vs_main(
    vshader_input: VertexInput,
    @builtin(instance_index) instance_index: u32,
) -> VertexOutput {
    let instance = instances_uniform.value[instance_index];

    let model_transform = mat4x4<f32>(
        instance.model_transform_0,
        instance.model_transform_1,
        instance.model_transform_2,
        instance.model_transform_3,
    );

    let bone_indices = vshader_input.bone_indices;
    let bone_weights = vshader_input.bone_weights; // one f32 per weight
    let skin_transform_0 = bone_weights.x * bones_uniform.value[bone_indices.x];
    let skin_transform_1 = bone_weights.y * bones_uniform.value[bone_indices.y];
    let skin_transform_2 = bone_weights.z * bones_uniform.value[bone_indices.z];
    let skin_transform_3 = bone_weights.w * bones_uniform.value[bone_indices.w];
    let skin_transform = skin_transform_0 + skin_transform_1 + skin_transform_2 + skin_transform_3;

    return do_vertex_shade(
        vshader_input,
        CAMERA.view_proj,
        model_transform,
        skin_transform,
        instance.base_color_factor,
        instance.emissive_factor,
        instance.mrno[0],
        instance.mrno[1],
        instance.mrno[2],
        instance.mrno[3],
        instance.alpha_cutoff[0],
    );
}

@vertex
fn shadow_map_vs_main(
    vshader_input: VertexInput,
    @builtin(instance_index) instance_index: u32,
) -> ShadowMappingVertexOutput {
    let instance = shadow_instances_uniform.value[instance_index];

    let model_transform = mat4x4<f32>(
        instance.model_transform_0,
        instance.model_transform_1,
        instance.model_transform_2,
        instance.model_transform_3,
    );

    let bone_indices = vshader_input.bone_indices;
    let bone_weights = vshader_input.bone_weights; // one f32 per weight
    let skin_transform_0 = bone_weights.x * shadow_bones_uniform.value[bone_indices.x];
    let skin_transform_1 = bone_weights.y * shadow_bones_uniform.value[bone_indices.y];
    let skin_transform_2 = bone_weights.z * shadow_bones_uniform.value[bone_indices.z];
    let skin_transform_3 = bone_weights.w * shadow_bones_uniform.value[bone_indices.w];
    let skin_transform = skin_transform_0 + skin_transform_1 + skin_transform_2 + skin_transform_3;

    let object_position = vec4<f32>(vshader_input.object_position, 1.0);
    let skinned_model_transform = model_transform * skin_transform;
    let world_position = skinned_model_transform * object_position;
    let clip_position = CAMERA.view_proj * skinned_model_transform * object_position;


    var out: ShadowMappingVertexOutput;
    out.clip_position = clip_position;
    out.world_position = world_position.xyz;
    return out;
}

@fragment
fn point_shadow_map_fs_main(
    in: ShadowMappingVertexOutput
) -> ShadowMappingFragmentOutput {
    var out: ShadowMappingFragmentOutput;
    let light_distance = length(in.world_position - CAMERA.position.xyz);
    out.depth = light_distance / CAMERA.far_plane_distance;
    return out;
}

@group(3) @binding(0)
var diffuse_texture: texture_2d<f32>;
@group(3) @binding(1)
var diffuse_sampler: sampler;
@group(3) @binding(2)
var normal_map_texture: texture_2d<f32>;
@group(3) @binding(3)
var normal_map_sampler: sampler;
@group(3) @binding(4)
var metallic_roughness_map_texture: texture_2d<f32>;
@group(3) @binding(5)
var metallic_roughness_map_sampler: sampler;
@group(3) @binding(6)
var emissive_map_texture: texture_2d<f32>;
@group(3) @binding(7)
var emissive_map_sampler: sampler;
@group(3) @binding(8)
var ambient_occlusion_map_texture: texture_2d<f32>;
@group(3) @binding(9)
var ambient_occlusion_map_sampler: sampler;

@group(1) @binding(0)
var skybox_texture: texture_cube<f32>;
@group(1) @binding(1)
var skybox_sampler: sampler;
@group(1) @binding(2)
var diffuse_env_map_texture: texture_cube<f32>;
@group(1) @binding(3)
var diffuse_env_map_sampler: sampler;
@group(1) @binding(4)
var specular_env_map_texture: texture_cube<f32>;
@group(1) @binding(5)
var specular_env_map_sampler: sampler;
@group(1) @binding(6)
var brdf_lut_texture: texture_2d<f32>;
@group(1) @binding(7)
var brdf_lut_sampler: sampler;
@group(1) @binding(8)
var point_shadow_map_textures: texture_cube_array<f32>;
@group(1) @binding(9)
var point_shadow_map_sampler: sampler;
@group(1) @binding(10)
var directional_shadow_map_textures: texture_2d_array<f32>;
@group(1) @binding(11)
var directional_shadow_map_sampler: sampler;


const pi: f32 = 3.141592653589793;
const two_pi: f32 = 6.283185307179586;
const half_pi: f32 = 1.570796326794897;
const epsilon: f32 = 0.00001;

// https://learnopengl.com/PBR/Theory
fn normal_distribution_func_tr_ggx(
    a: f32,
    n: vec3<f32>,
    h: vec3<f32>,
) -> f32 {
    let a2 = a * a;
    let n_dot_h = dot(n, h);
    let n_dot_h_2 = n_dot_h * n_dot_h;
    let denom_temp = n_dot_h_2 * (a2 - 1.0) + 1.0;
    return a2 / (pi * denom_temp * denom_temp + epsilon);
}

fn geometry_func_schlick_ggx_k_direct(
    a: f32,
) -> f32 {
    let a_plus_1 = a + 1.0;
    return (a_plus_1 * a_plus_1) / 8.0;
}

fn geometry_func_schlick_ggx_k_ibl(
    a: f32,
) -> f32 {
    return (a * a) / 2.0;
}

fn geometry_func_schlick_ggx(
    n_dot_v: f32,
    k: f32,
) -> f32 {
    return n_dot_v / (n_dot_v * (1.0 - k) + k + epsilon);
}

fn geometry_func_smith_ggx(
    k: f32,
    n: vec3<f32>,
    v: vec3<f32>,
    l: vec3<f32>,
) -> f32 {
    let n_dot_v = max(dot(n, v), 0.0);
    let n_dot_l = max(dot(n, l), 0.0);
    let ggx_1 = geometry_func_schlick_ggx(n_dot_v, k);
    let ggx_2 = geometry_func_schlick_ggx(n_dot_l, k);
    return ggx_1 * ggx_2;
}

fn fresnel_func_schlick(
    cos_theta: f32,
    f0: vec3<f32>,
) -> vec3<f32> {
    return f0 + (1.0 - f0) * pow(clamp(1.0 - cos_theta, 0.0, 1.0), 5.0);
}

fn fresnel_func_schlick_with_roughness(
    cos_theta: f32,
    f0: vec3<f32>,
    a: f32,
) -> vec3<f32> {
    return f0 + (max(vec3<f32>(1.0 - a), f0) - f0) * pow(clamp(1.0 - cos_theta, 0.0, 1.0), 5.0);
    // return f0 + (max(vec3<f32>(1.0 - a), f0) - f0) * pow(1.0 - h_dot_v, 5.0);
}

fn radical_inverse_vdc(
    bits: u32,
) -> f32 {
    var out = bits;
    out = (out << 16u) | (out >> 16u);
    out = ((out & 0x55555555u) << 1u) | ((out & 0xAAAAAAAAu) >> 1u);
    out = ((out & 0x33333333u) << 2u) | ((out & 0xCCCCCCCCu) >> 2u);
    out = ((out & 0x0F0F0F0Fu) << 4u) | ((out & 0xF0F0F0F0u) >> 4u);
    out = ((out & 0x00FF00FFu) << 8u) | ((out & 0xFF00FF00u) >> 8u);
    return f32(out) * 2.3283064365386963e-10; // / 0x100000000
}

fn hammersley(
    i_u: u32,
    num_samples_u: u32,
) -> vec2<f32> {
    let i = f32(i_u);
    let num_samples = f32(num_samples_u);
    return vec2<f32>(i / num_samples, radical_inverse_vdc(i_u));
}

fn world_normal_to_cubemap_vec(world_pos: vec3<f32>) -> vec3<f32> {
    return vec3<f32>(-world_pos.x, world_pos.y, world_pos.z);
}

fn rand(co: vec2<f32>) -> f32 {
    let a = 12.9898;
    let b = 78.233;
    let c = 43758.5453;
    let dt = dot(co, vec2<f32>(a, b));
    let sn = dt % 3.14;
    return fract(sin(sn) * c);
}

fn compute_direct_lighting(
    world_normal: vec3<f32>,
    to_viewer_vec: vec3<f32>,
    to_light_vec: vec3<f32>,
    light_color_scaled: vec3<f32>,
    light_attenuation_factor: f32,
    base_color: vec3<f32>,
    roughness: f32,
    metallicness: f32,
    f0: vec3<f32>
) -> vec3<f32> {
    // copy variable names from the math formulas
    let n = world_normal;
    let w0 = to_viewer_vec;
    let v = w0;
    let a = roughness;

    let halfway_vec = normalize(to_viewer_vec + to_light_vec);
    
    // let surface_reflection_at_zero_incidence = vec3<f32>(0.95, 0.93, 0.88);

    // copy variable names from the math formulas
    let wi = to_light_vec;
    let l = wi;
    let h = halfway_vec;

    // specular
    let h_dot_v = max(dot(h, v), 0.0);
    let normal_distribution = normal_distribution_func_tr_ggx(a, n, h);
    let k = geometry_func_schlick_ggx_k_direct(a);
    let geometry = geometry_func_smith_ggx(k, n, v, l);
    let fresnel = fresnel_func_schlick(h_dot_v, f0);
    let cook_torrance_denominator = 4.0 * max(dot(n, w0), 0.0) * max(dot(n, wi), 0.0) + epsilon;
    let specular_component = normal_distribution * geometry * fresnel / cook_torrance_denominator;
    let ks = fresnel;

    // diffuse
    let diffuse_component = base_color / pi; // lambertian
    let kd = (vec3<f32>(1.0) - ks) * (1.0 - metallicness);

    let incident_angle_factor = max(dot(n, wi), 0.0);      
    //                                  ks was already multiplied by fresnel so it's omitted here       
    let bdrf = kd * diffuse_component + specular_component;
    return bdrf * incident_angle_factor * light_attenuation_factor * light_color_scaled;
}

fn do_fragment_shade(
    world_position: vec3<f32>,
    world_normal: vec3<f32>,
    tex_coords: vec2<f32>,
    vertex_color: vec4<f32>,
    camera_position: vec3<f32>,
    base_color_factor: vec4<f32>,
    emissive_factor: vec4<f32>,
    metallicness_factor: f32,
    roughness_factor: f32,
    occlusion_strength: f32,
    alpha_cutoff: f32
) -> FragmentOutput {

    // let roughness = 0.12;
    // let metallicness = 0.8;
    let base_color_t = textureSample(
        diffuse_texture,
        diffuse_sampler,
        tex_coords
    );
    let base_color = base_color_t.rgb * base_color_factor.rgb * vertex_color.rgb;
    let metallic_roughness = textureSample(
        metallic_roughness_map_texture,
        metallic_roughness_map_sampler,
        tex_coords
    ).rgb;
    let metallicness = metallic_roughness.z * metallicness_factor;
    let roughness = metallic_roughness.y * roughness_factor;
    let ambient_occlusion = textureSample(
        ambient_occlusion_map_texture,
        ambient_occlusion_map_sampler,
        tex_coords
    ).r;
    let emissive = textureSample(
        emissive_map_texture,
        emissive_map_sampler,
        tex_coords
    ).rgb * emissive_factor.rgb;

    let to_viewer_vec = normalize(camera_position - world_position);
    let reflection_vec = reflect(-to_viewer_vec, normalize(world_normal));
    let surface_reflection_at_zero_incidence_dialectric = vec3<f32>(0.04);
    let surface_reflection_at_zero_incidence = mix(
        surface_reflection_at_zero_incidence_dialectric,
        base_color,
        metallicness
    );

    let MAX_REFLECTION_LOD = 4.0;
    let pre_filtered_color = textureSampleLevel(
        specular_env_map_texture,
        specular_env_map_sampler,
        world_normal_to_cubemap_vec(reflection_vec),
        roughness * MAX_REFLECTION_LOD
    ).rgb;

    // copy variable names from the math formulas
    let n = world_normal;
    let w0 = to_viewer_vec;
    let v = w0;
    let a = roughness;
    let f0 = surface_reflection_at_zero_incidence;

    let n_dot_v = max(dot(n, v), 0.0);
    let brdf_lut_res = textureSample(brdf_lut_texture, brdf_lut_sampler, vec2<f32>(n_dot_v, roughness));
    let env_map_diffuse_irradiance = textureSample(diffuse_env_map_texture, diffuse_env_map_sampler, world_normal_to_cubemap_vec(world_normal)).rgb;


    let random_seed = vec2<f32>(
        round(100000.0 * (world_position.x + world_position.y)),
        round(100000.0 * (world_position.y + world_position.z)),
    );

    var total_light_irradiance = vec3<f32>(0.0);
    for (var light_index = 0u; light_index < MAX_LIGHTS; light_index = light_index + 1u) {
        let light = point_lights.values[light_index];
        let light_color_scaled = light.color.xyz * light.color.w;

        if light_color_scaled.x < epsilon && light_color_scaled.y < epsilon && light_color_scaled.z < epsilon {
            continue;
        }

        let from_shadow_vec = world_position - light.position.xyz;
        let shadow_camera_far_plane_distance = 1000.0;
        let current_depth = length(from_shadow_vec) / shadow_camera_far_plane_distance;
        let bias = 0.0001;

        // soft shadows
        // irregular shadow sampling
        var shadow_occlusion_acc = 0.0;
        let sample_count = 4.0;
        let max_offset_x = 0.01 + 0.04 * rand(random_seed * 1.0);
        let max_offset_y = 0.01 + 0.04 * rand(random_seed * 2.0);
        let max_offset_z = 0.01 + 0.04 * rand(random_seed * 3.0);
        for (var x = 0.0; x < sample_count; x = x + 1.0) {
            for (var y = 0.0; y < sample_count; y = y + 1.0) {
                for (var z = 0.0; z < sample_count; z = z + 1.0) {
                    let irregular_offset = vec3<f32>(
                        max_offset_x * ((2.0 * x / (sample_count - 1.0)) - 1.0),
                        max_offset_y * ((2.0 * y / (sample_count - 1.0)) - 1.0),
                        max_offset_z * ((2.0 * z / (sample_count - 1.0)) - 1.0),
                    );
                    let closest_depth = textureSample(
                        point_shadow_map_textures,
                        point_shadow_map_sampler,
                        world_normal_to_cubemap_vec(from_shadow_vec + irregular_offset),
                        i32(light_index)
                    ).r;
                    if current_depth - bias < closest_depth {
                        shadow_occlusion_acc = shadow_occlusion_acc + 1.0;
                    }
                }
            }
        }
        let shadow_occlusion_factor = shadow_occlusion_acc / (sample_count * sample_count * sample_count);

        // regular shadow sampling
        // var shadow_occlusion_acc = 0.0;
        // let bias = 0.0001;
        // let sample_count = 4.0;
        // let offset = 0.01;

        // let max_offset = 0.1;
        // for (var x = -max_offset; x < max_offset; x = x + max_offset / (sample_count * 0.5)) {
        //     for (var y = -max_offset; y < max_offset; y = y + max_offset / (sample_count * 0.5)) {
        //         for (var z = -max_offset; z < max_offset; z = z + max_offset / (sample_count * 0.5)) {
        //             let closest_depth = textureSample(
        //                 shadow_map_textures,
        //                 shadow_map_sampler,
        //                 world_normal_to_cubemap_vec(from_shadow_vec + vec3<f32>(x, y, z)),
        //                 i32(light_index)
        //             ).r;
        //             if (current_depth - bias < closest_depth) {
        //                 shadow_occlusion_acc = shadow_occlusion_acc + 1.0;
        //             }
        //         }
        //     }
        // }
        // let shadow_occlusion_factor = shadow_occlusion_acc / (sample_count * sample_count * sample_count);

        // hard shadows
        // var shadow_occlusion_factor = 1.0;
        // let closest_depth = textureSample(
        //     point_shadow_map_textures,
        //     point_shadow_map_sampler,
        //     world_normal_to_cubemap_vec(from_shadow_vec),
        //     i32(light_index)
        // ).r;
        // if (current_depth - bias < closest_depth) {
        //     shadow_occlusion_factor = 1.0;
        // }

        if shadow_occlusion_factor < epsilon {
                continue;
        }

        let to_light_vec = light.position.xyz - world_position;
        let to_light_vec_norm = normalize(to_light_vec);

        let distance_from_light = length(to_light_vec);
        // https://learnopengl.com/Lighting/Light-casters
        // let light_attenuation_factor_d20 = 1.0 / (1.0 + 0.22 * distance_from_light + 0.20 * distance_from_light * distance_from_light);
        // let light_attenuation_factor_d100 = 1.0 / (1.0 + 0.045 * distance_from_light + 0.0075 * distance_from_light * distance_from_light);
        let light_attenuation_factor_d600 = 1.0 / (1.0 + 0.007 * distance_from_light + 0.0002 * distance_from_light * distance_from_light);
        // let light_attenuation_factor_d3250 = 1.0 / (1.0 + 0.0014 * distance_from_light + 0.000007 * distance_from_light * distance_from_light);
        let light_attenuation_factor = light_attenuation_factor_d600;

        let light_irradiance = compute_direct_lighting(
            world_normal,
            to_viewer_vec,
            to_light_vec_norm,
            light_color_scaled,
            light_attenuation_factor,
            base_color,
            roughness,
            metallicness,
            f0
        );
        total_light_irradiance = total_light_irradiance + light_irradiance * shadow_occlusion_factor;
    }

    for (var light_index = 0u; light_index < MAX_LIGHTS; light_index = light_index + 1u) {
        let light = directional_lights.values[light_index];
        let light_color_scaled = light.color.xyz * light.color.w;

        if light_color_scaled.x < epsilon && light_color_scaled.y < epsilon && light_color_scaled.z < epsilon {
            continue;
        }

        // let from_shadow_vec = world_position - light.position.xyz;
        // let shadow_camera_far_plane_distance = 40.0;
        // let current_depth = length(from_shadow_vec) / shadow_camera_far_plane_distance;
        let light_space_position_nopersp = light.world_space_to_light_space * vec4<f32>(world_position, 1.0);
        let light_space_position = light_space_position_nopersp / light_space_position_nopersp.w;
        let light_space_position_uv = vec2<f32>(
            light_space_position.x * 0.5 + 0.5,
            1.0 - (light_space_position.y * 0.5 + 0.5),
        );
        let current_depth = light_space_position.z;
        let bias = 0.0001;

        // soft shadows
        var shadow_occlusion_acc = 0.0;
        let sample_count = 4.0;
        let max_offset_x = 0.0001 + 0.0005 * rand(random_seed * 1.0);
        let max_offset_y = 0.0001 + 0.0005 * rand(random_seed * 2.0);
        for (var x = 0.0; x < sample_count; x = x + 1.0) {
            for (var y = 0.0; y < sample_count; y = y + 1.0) {
                let irregular_offset = vec2<f32>(
                    max_offset_x * ((2.0 * x / (sample_count - 1.0)) - 1.0),
                    max_offset_y * ((2.0 * y / (sample_count - 1.0)) - 1.0)
                );
                let closest_depth = textureSample(
                    directional_shadow_map_textures,
                    directional_shadow_map_sampler,
                    light_space_position_uv + irregular_offset,
                    i32(light_index)
                ).r;
                if light_space_position.x >= -1.0 && light_space_position.x <= 1.0 && light_space_position.y >= -1.0 && light_space_position.y <= 1.0 && light_space_position.z >= 0.0 && light_space_position.z <= 1.0 {
                    if current_depth - bias < closest_depth {
                        shadow_occlusion_acc = shadow_occlusion_acc + 1.0;
                    }
                } else {
                    shadow_occlusion_acc = shadow_occlusion_acc + 1.0;
                }
            }
        }
        let shadow_occlusion_factor = shadow_occlusion_acc / (sample_count * sample_count);

        // hard shadows
        // var shadow_occlusion_factor = 1.0;
        // let closest_depth = textureSample(
        //     directional_shadow_map_textures,
        //     directional_shadow_map_sampler,
        //     light_space_position_uv,
        //     i32(light_index)
        // ).r;
        // if (light_space_position.x >= -1.0 && light_space_position.x <= 1.0 && light_space_position.y >= -1.0 && light_space_position.y <= 1.0 && light_space_position.z >= 0.0 && light_space_position.z <= 1.0) {
        //     if (current_depth - bias < closest_depth) {
        //         shadow_occlusion_factor = 1.0;
        //     }
        // } else {
        //     shadow_occlusion_factor = 1.0;
        // }


        if shadow_occlusion_factor < epsilon {
                continue;
        }

        let to_light_vec = -light.direction.xyz;
        let to_light_vec_norm = normalize(to_light_vec);
        let light_attenuation_factor = 1.0;

        let light_irradiance = compute_direct_lighting(
            world_normal,
            to_viewer_vec,
            to_light_vec_norm,
            light_color_scaled,
            light_attenuation_factor,
            base_color,
            roughness,
            metallicness,
            f0
        );
        total_light_irradiance = total_light_irradiance + light_irradiance * shadow_occlusion_factor;
    }





    let fresnel_ambient = fresnel_func_schlick_with_roughness(n_dot_v, f0, a);
    // mip level count - 1
    
    // let pre_filtered_color = textureSample(
    //     specular_env_map_texture,
    //     specular_env_map_sampler,
    //     world_normal_to_cubemap_vec(reflection_vec)
    // ).rgb;

    let ambient_specular_irradiance = pre_filtered_color * (fresnel_ambient * brdf_lut_res.r + brdf_lut_res.g);

    let kd_ambient = (vec3<f32>(1.0) - fresnel_ambient) * (1.0 - metallicness);

    let ambient_diffuse_irradiance = env_map_diffuse_irradiance * base_color;

    let ambient_irradiance_pre_ao = (kd_ambient * ambient_diffuse_irradiance + ambient_specular_irradiance);
    let ambient_irradiance = mix(
        ambient_irradiance_pre_ao,
        ambient_irradiance_pre_ao * ambient_occlusion,
        occlusion_strength
    );
    // let ambient_irradiance = ambient_irradiance_pre_ao;

    let combined_irradiance_hdr = ambient_irradiance + total_light_irradiance + emissive;
    // let combined_irradiance_hdr = total_light_irradiance;
    // let combined_irradiance_ldr = (combined_irradiance_hdr / (combined_irradiance_hdr + vec3<f32>(1.0, 1.0, 1.0))) + emissive;

    // let hi = textureSample(shadow_map_texture, shadow_map_sampler, vec2<f32>(0.1, 0.1));

    // let final_color = vec4<f32>(combined_irradiance_ldr, 1.0);
    let final_color = vec4<f32>(combined_irradiance_hdr, 1.0);

    if base_color_t.a <= alpha_cutoff {
        discard;
    }

    var out: FragmentOutput;
    out.color = final_color;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> FragmentOutput {
    let tbn = (mat3x3<f32>(
        in.world_tangent,
        in.world_bitangent,
        in.world_normal,
    ));
    let normal_map_normal = textureSample(
        normal_map_texture,
        normal_map_sampler,
        in.tex_coords
    ) * 2.0 - 1.0;
    let tangent_space_normal = vec3<f32>(
        normal_map_normal.x,
        -normal_map_normal.y, // I guess this is needed due to differing uv-mapping conventions
        sqrt(1.0 - clamp(normal_map_normal.x * normal_map_normal.x - normal_map_normal.y * normal_map_normal.y, 0.0, 1.0))
    );
    // normal scale helpful comment:
    // https://github.com/KhronosGroup/glTF/issues/885#issuecomment-288320363
    let transformed_normal = normalize(
        tbn * normalize(
            tangent_space_normal * vec3<f32>(in.normal_scale, in.normal_scale, 1.0)
        )
    );

    //  var out: FragmentOutput;
    // out.color = vec4<f32>(in.object_tangent, 1.0);;
    // return out;

    return do_fragment_shade(
        in.world_position,
        transformed_normal,
        in.tex_coords,
        in.vertex_color,
        CAMERA.position.xyz,
        in.base_color_factor,
        in.emissive_factor,
        in.metallicness_factor,
        in.roughness_factor,
        in.occlusion_strength,
        in.alpha_cutoff
    );
}