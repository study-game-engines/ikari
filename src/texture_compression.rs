use std::path::{Path, PathBuf};

const BASISU_COMPRESSION_FORMAT: basis_universal::BasisTextureFormat =
    basis_universal::BasisTextureFormat::UASTC4x4;

pub struct TextureCompressor(());

pub struct TextureCompressionArgs<'a> {
    pub img_bytes: &'a [u8],
    pub img_width: u32,
    pub img_height: u32,
    pub img_channel_count: u8,
    pub is_normal_map: bool,
    pub is_srgb: bool,
    pub thread_count: u32,
}

pub struct CompressedTexture {
    pub format: basis_universal::transcoding::TranscoderTextureFormat,
    pub width: u32,
    pub height: u32,
    pub raw: Vec<u8>,
    pub mip_count: u32,
}

impl TextureCompressor {
    pub fn new() -> Self {
        Self(())
    }

    /// # Safety
    ///
    /// Compressing with invalid parameters may cause undefined behavior. (The underlying C++
    /// library does not thoroughly validate parameters)
    /// see https://docs.rs/basis-universal/0.2.0/basis_universal/encoding/struct.Compressor.html#method.process
    pub unsafe fn compress_raw_image(
        &self,
        args: TextureCompressionArgs,
    ) -> anyhow::Result<Vec<u8>> {
        basis_universal::encoder_init();

        let TextureCompressionArgs {
            img_bytes,
            img_width,
            img_height,
            img_channel_count,
            is_normal_map,
            is_srgb,
            thread_count,
        } = args;

        let mut params = basis_universal::CompressorParams::new();
        params.set_basis_format(BASISU_COMPRESSION_FORMAT);
        params.set_uastc_quality_level(3); // level 3 takes longer to compress but is higher quality
        params.set_rdo_uastc(Some(1.0)); // default
        params.set_generate_mipmaps(true);
        params.set_mipmap_smallest_dimension(1); // default
        params.set_color_space(if is_srgb {
            basis_universal::ColorSpace::Srgb
        } else {
            basis_universal::ColorSpace::Linear
        });
        params.set_use_global_codebook(false);
        params.set_print_status_to_stdout(false);

        if is_normal_map {
            params.tune_for_normal_maps();
        }

        let mut source_image = params.source_image_mut(0);
        source_image.init(img_bytes, img_width, img_height, img_channel_count);

        if is_normal_map {
            let pixel_count = source_image.pixel_data_u32_mut().len();
            let image_bytes = source_image.pixel_data_u8_mut();
            for pixel_index in 0..pixel_count {
                image_bytes[pixel_index * 4 + 3] = image_bytes[pixel_index * 4 + 1];
                image_bytes[pixel_index * 4 + 1] = image_bytes[pixel_index * 4];
                image_bytes[pixel_index * 4 + 2] = image_bytes[pixel_index * 4];
            }
        }

        let mut basisu_compressor = basis_universal::Compressor::new(thread_count);
        basisu_compressor.init(&params);

        if let Err(error_code) = basisu_compressor.process() {
            anyhow::bail!("Error compressing img to basisu {:?}", error_code);
        }

        // 0 = default compression level
        let zstd_encoded_data = zstd::stream::encode_all(basisu_compressor.basis_file(), 0)?;

        Ok(zstd_encoded_data)
    }

    pub fn transcode_image(
        &self,
        img_bytes: &[u8],
        is_normal_map: bool,
    ) -> anyhow::Result<CompressedTexture> {
        basis_universal::transcoder_init();

        let zstd_decoded_data = zstd::stream::decode_all(img_bytes)?;

        let mut basisu_transcoder = basis_universal::Transcoder::new();

        if !basisu_transcoder.validate_header(&zstd_decoded_data) {
            anyhow::bail!("Image data failed basisu validation");
        }

        if let Err(prep_err) = basisu_transcoder.prepare_transcoding(&zstd_decoded_data) {
            anyhow::bail!("Error calling prepare_transcoding: {:?}", prep_err);
        }

        let mip_levels = basisu_transcoder.image_level_count(&zstd_decoded_data, 0);

        let basis_universal::ImageLevelDescription {
            original_width: img_width,
            original_height: img_height,
            ..
        } = basisu_transcoder
            .image_level_description(&zstd_decoded_data, 0, 0)
            .unwrap();

        let gpu_texture_format = if is_normal_map {
            basis_universal::transcoding::TranscoderTextureFormat::BC5_RG
        } else {
            basis_universal::transcoding::TranscoderTextureFormat::BC7_RGBA
        };

        // full mip chain uses 33% more memory
        // https://en.wikipedia.org/wiki/1/4_%2B_1/16_%2B_1/64_%2B_1/256_%2B_%E2%8B%AF
        let mut full_mip_chain_bytes =
            Vec::with_capacity((img_width as f32 * img_height as f32 * 1.34).ceil() as usize);
        for mip_level in 0..mip_levels {
            match basisu_transcoder.transcode_image_level(
                &zstd_decoded_data,
                gpu_texture_format,
                basis_universal::transcoding::TranscodeParameters {
                    image_index: 0,
                    level_index: mip_level,
                    decode_flags: Some(basis_universal::transcoding::DecodeFlags::HIGH_QUALITY),
                    output_row_pitch_in_blocks_or_pixels: None,
                    output_rows_in_pixels: None,
                },
            ) {
                Ok(mip_level) => {
                    full_mip_chain_bytes.extend(mip_level);
                }
                Err(transcode_error) => {
                    anyhow::bail!("Error transcoding img from basisu {:?}", transcode_error);
                }
            };
        }

        Ok(CompressedTexture {
            format: gpu_texture_format,
            width: img_width,
            height: img_height,
            raw: full_mip_chain_bytes,
            mip_count: mip_levels,
        })
    }
}

impl Default for TextureCompressor {
    fn default() -> Self {
        Self::new()
    }
}

pub fn texture_path_to_compressed_path(path: &Path) -> PathBuf {
    let mut out_path = path.to_path_buf();
    out_path.set_file_name(format!(
        "{:}_compressed.bin",
        out_path.file_stem().unwrap().to_str().unwrap()
    ));
    out_path
}
