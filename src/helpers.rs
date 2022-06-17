use cgmath::{Matrix, Matrix4, Quaternion, Rad, Vector3};

pub fn _to_srgb(val: f32) -> f32 {
    val.powf(2.2)
}

pub fn lerp_f32(from: f32, to: f32, alpha: f32) -> f32 {
    (alpha * to) + ((1.0 - alpha) * from)
}

pub fn _lerp_f64(from: f64, to: f64, alpha: f64) -> f64 {
    (alpha * to) + ((1.0 - alpha) * from)
}

pub fn lerp_vec(a: Vector3<f32>, b: Vector3<f32>, alpha: f32) -> Vector3<f32> {
    b * alpha + a * (1.0 - alpha)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn my_test() {
        println!(
            "{:?}",
            make_rotation_matrix(make_quat_from_axis_angle(
                Vector3::new(1.0, 0.0, 0.0),
                cgmath::Deg(-90.0).into()
            ))
        );
        println!(
            "{:?}",
            make_rotation_matrix(make_quat_from_axis_angle(
                Vector3::new(0.0, 1.0, 0.0),
                cgmath::Deg(-90.0).into()
            ))
        );
        println!(
            "{:?}",
            make_rotation_matrix(
                make_quat_from_axis_angle(Vector3::new(1.0, 0.0, 0.0), cgmath::Deg(-90.0).into())
                    * make_quat_from_axis_angle(
                        Vector3::new(0.0, 1.0, 0.0),
                        cgmath::Deg(-90.0).into()
                    )
            )
        );
        println!("{:?}", make_translation_matrix(Vector3::new(2.0, 3.0, 4.0)));
        assert_eq!(true, true);
    }
}

// from https://stackoverflow.com/questions/4436764/rotating-a-quaternion-on-1-axis
pub fn make_quat_from_axis_angle(axis: Vector3<f32>, angle: Rad<f32>) -> Quaternion<f32> {
    let factor = (angle.0 / 2.0).sin();

    let x = axis.x * factor;
    let y = axis.y * factor;
    let z = axis.z * factor;

    let w = (angle.0 / 2.0).cos();

    Quaternion::new(w, x, y, z)
}

// from https://en.wikipedia.org/wiki/Quaternions_and_spatial_rotation#Quaternion-derived_rotation_matrix
pub fn make_rotation_matrix(r: Quaternion<f32>) -> Matrix4<f32> {
    let qr = r.s;
    let qi = r.v.x;
    let qj = r.v.y;
    let qk = r.v.z;
    let qr_2 = qr * qr;
    let qi_2 = qi * qi;
    let qj_2 = qj * qj;
    let qk_2 = qk * qk;
    let s = (qr_2 + qi_2 + qj_2 + qk_2).sqrt();
    #[rustfmt::skip]
    let result = Matrix4::new(
        1.0 - (2.0 * s * (qj_2 + qk_2)),
        2.0 * s * (qi*qj - qk*qr),
        2.0 * s * (qi*qk + qj*qr),
        0.0,
  
        2.0 * s * (qi*qj + qk*qr),
        1.0 - (2.0 * s * (qi_2 + qk_2)),
        2.0 * s * (qj*qk - qi*qr),
        0.0,
  
        
        2.0 * s * (qi*qk - qj*qr),
        2.0 * s * (qj*qk + qi*qr),
        1.0 - (2.0 * s * (qi_2 + qj_2)),
        0.0,
        
        0.0,
        0.0,
        0.0,
        1.0,
    ).transpose();
    result
}

// from https://en.wikipedia.org/wiki/Rotation_matrix
pub fn _make_rotation_matrix_from_eulers(
    pitch: Rad<f32>,
    yaw: Rad<f32>,
    roll: Rad<f32>,
) -> Matrix4<f32> {
    let pitch = pitch.0;
    let yaw = yaw.0;
    let roll = roll.0;
    #[rustfmt::skip]
    let result = Matrix4::new(
        yaw.cos() * pitch.cos(),
        yaw.cos() * pitch.sin() * roll.sin() - yaw.sin() * roll.cos(),
        yaw.cos() * pitch.sin() * roll.cos() + yaw.sin() * roll.sin(),
        0.0,

        yaw.sin() * pitch.cos(),
        yaw.sin() * pitch.sin() * roll.sin() + yaw.cos() * roll.cos(),
        yaw.sin() * pitch.sin() * roll.cos() - yaw.cos() * roll.sin(),
        0.0,

        -pitch.sin(),
        pitch.cos() * roll.sin(),
        pitch.cos() * roll.cos(),
        0.0,
        
        0.0,
        0.0,
        0.0,
        1.0,
    ).transpose();
    result
}

pub fn make_translation_matrix(translation: Vector3<f32>) -> Matrix4<f32> {
    #[rustfmt::skip]
    let result = Matrix4::new(
        1.0, 0.0, 0.0, translation.x,
        0.0, 1.0, 0.0, translation.y,
        0.0, 0.0, 1.0, translation.z,
        0.0, 0.0, 0.0,           1.0,
    ).transpose();
    result
}

pub fn make_scale_matrix(scale: Vector3<f32>) -> Matrix4<f32> {
    #[rustfmt::skip]
    let result = Matrix4::new(
        scale.x, 0.0,     0.0,     0.0,
        0.0,     scale.y, 0.0,     0.0,
        0.0,     0.0,     scale.z, 0.0,
        0.0,     0.0,     0.0,     1.0,
    ).transpose();
    result
}

// from https://vincent-p.github.io/posts/vulkan_perspective_matrix/ and https://thxforthefish.com/posts/reverse_z/
pub fn make_perspective_matrix(
    near_plane_distance: f32,
    far_plane_distance: f32,
    vertical_fov: cgmath::Rad<f32>,
    aspect_ratio: f32,
) -> Matrix4<f32> {
    let n = near_plane_distance;
    let f = far_plane_distance;
    let cot = 1.0 / (vertical_fov.0 / 2.0).tan();
    let ar = aspect_ratio;
    #[rustfmt::skip]
    let persp_matrix = Matrix4::new(
        cot/ar, 0.0, 0.0,     0.0,
        0.0,    cot, 0.0,     0.0,
        0.0,    0.0, f/(n-f), n*f/(n-f),
        0.0,    0.0, -1.0,     0.0,
    ).transpose();
    #[rustfmt::skip]
    let reverse_z = Matrix4::new(
        1.0, 0.0, 0.0,  0.0,
        0.0, 1.0, 0.0,  0.0,
        0.0, 0.0, -1.0, 1.0,
        0.0, 0.0, 0.0,  1.0,
    ).transpose();
    reverse_z * persp_matrix
}
