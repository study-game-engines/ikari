use std::fs::File;

use anyhow::Result;
use cpal::{
    traits::{DeviceTrait, HostTrait, StreamTrait},
    Stream,
};
use glam::f32::Vec3;
// use hound::{WavReader, WavSpec};
use oddio::{
    FixedGain, FramesSignal, Gain, Handle, Mixer, SpatialBuffered, SpatialOptions, SpatialScene,
    Stop,
};
use symphonia::core::{
    audio::SampleBuffer, codecs::CODEC_TYPE_NULL, io::MediaSourceStream, probe::Hint,
};

pub struct AudioStreams {
    _spatial_scene_output_stream: Stream,
    _mixer_output_stream: Stream,
}

pub struct AudioManager {
    master_volume: f32,
    device_sample_rate: u32,

    spatial_scene_handle: Handle<SpatialScene>,
    mixer_handle: Handle<Mixer<[f32; 2]>>,
    sounds: Vec<Option<Sound>>,
}

const CHANNEL_COUNT: usize = 2;

#[derive(Debug, Clone)]
pub struct SoundData(Vec<[f32; CHANNEL_COUNT]>);

pub struct Sound {
    volume: f32,
    is_playing: bool,
    signal_handle: SoundSignalHandle,
    data: SoundData,
}

pub enum SoundSignal {
    Mono { signal: FramesSignal<f32> },
    Stereo { signal: FramesSignal<[f32; 2]> },
}

pub enum SoundSignalHandle {
    Spacial {
        signal_handle: Handle<SpatialBuffered<Stop<Gain<FramesSignal<f32>>>>>,
    },
    Ambient {
        signal_handle: Handle<Stop<Gain<FramesSignal<[f32; 2]>>>>,
    },
    AmbientFixed {
        signal_handle: Handle<Stop<FixedGain<FramesSignal<[f32; 2]>>>>,
    },
}

pub enum AudioFileFormat {
    Mp3,
    Wav,
}

#[derive(Debug, Copy, Clone)]
pub struct SpacialParams {
    initial_position: Vec3,
    initial_velocity: Vec3,
}

#[derive(Debug, Clone)]
pub struct SoundParams {
    pub initial_volume: f32,
    pub fixed_volume: bool,
    pub spacial_params: Option<SpacialParams>,
}

impl AudioManager {
    pub fn new() -> Result<(AudioManager, AudioStreams)> {
        let host = cpal::default_host();
        let device = host
            .default_output_device()
            .ok_or_else(|| anyhow::anyhow!("No output device found"))?;
        let device_sample_rate = device.default_output_config()?.sample_rate().0;

        let (spatial_scene_handle, spatial_scene) = oddio::split(oddio::SpatialScene::new());
        let (mixer_handle, mixer) = oddio::split(oddio::Mixer::new());

        let config = cpal::StreamConfig {
            channels: 2,
            sample_rate: cpal::SampleRate(device_sample_rate),
            buffer_size: cpal::BufferSize::Default,
        };

        let spatial_scene_output_stream = device.build_output_stream(
            &config,
            move |out_flat: &mut [f32], _: &cpal::OutputCallbackInfo| {
                let out_stereo = oddio::frame_stereo(out_flat);
                oddio::run(&spatial_scene, device_sample_rate, out_stereo);
            },
            move |err| {
                eprintln!("{}", err);
            },
            None,
        )?;
        let mixer_output_stream = device.build_output_stream(
            &config,
            move |out_flat: &mut [f32], _: &cpal::OutputCallbackInfo| {
                let out_stereo = oddio::frame_stereo(out_flat);
                oddio::run(&mixer, device_sample_rate, out_stereo);
            },
            move |err| {
                eprintln!("{}", err);
            },
            None,
        )?;
        spatial_scene_output_stream.play()?;
        mixer_output_stream.play()?;

        Ok((
            AudioManager {
                master_volume: 1.0,
                device_sample_rate,

                spatial_scene_handle,
                mixer_handle,
                sounds: vec![],
            },
            AudioStreams {
                _spatial_scene_output_stream: spatial_scene_output_stream,
                _mixer_output_stream: mixer_output_stream,
            },
        ))
    }

    pub fn decode_audio_file(
        sample_rate: u32,
        file_path: &str,
        file_format: Option<AudioFileFormat>,
    ) -> Result<SoundData> {
        let src = File::open(file_path)?;
        let mss = MediaSourceStream::new(Box::new(src), Default::default());

        let mut hint = Hint::new();
        if let Some(file_format) = file_format {
            hint.with_extension(match file_format {
                AudioFileFormat::Mp3 => "mp3",
                AudioFileFormat::Wav => "wav",
            });
        }

        let probed = symphonia::default::get_probe().format(
            &hint,
            mss,
            &Default::default(),
            &Default::default(),
        )?;

        let mut format = probed.format;

        let track = format
            .tracks()
            .iter()
            .find(|t| t.codec_params.codec != CODEC_TYPE_NULL)
            .ok_or(anyhow::anyhow!("no supported audio tracks"))?;

        let mut decoder =
            symphonia::default::get_codecs().make(&track.codec_params, &Default::default())?;

        let track_id = track.id;
        let track_sample_rate = track.codec_params.sample_rate;

        let mut samples_interleaved: Vec<f32> = vec![];

        loop {
            let packet = match format.next_packet() {
                Ok(packet) => packet,
                Err(symphonia::core::errors::Error::ResetRequired) => {
                    // The track list has been changed. Re-examine it and create a new set of decoders,
                    // then restart the decode loop. This is an advanced feature and it is not
                    // unreasonable to consider this "the end." As of v0.5.0, the only usage of this is
                    // for chained OGG physical streams.
                    anyhow::bail!("idk");
                }
                Err(symphonia::core::errors::Error::IoError(err)) => {
                    if err.kind() == std::io::ErrorKind::UnexpectedEof
                        && err.to_string() == "end of stream"
                    {
                        break;
                    }
                    anyhow::bail!(err);
                }
                Err(err) => {
                    anyhow::bail!(err);
                }
            };

            if packet.track_id() != track_id {
                continue;
            }

            match decoder.decode(&packet) {
                Ok(audio_buf) => {
                    let mut sample_buf =
                        SampleBuffer::<f32>::new(audio_buf.capacity() as u64, *audio_buf.spec());

                    sample_buf.copy_interleaved_ref(audio_buf);

                    for sample in sample_buf.samples() {
                        samples_interleaved.push(*sample);
                    }
                }
                Err(symphonia::core::errors::Error::IoError(err)) => {
                    if err.kind() == std::io::ErrorKind::UnexpectedEof
                        && err.to_string() == "end of stream"
                    {
                        dbg!(err);
                        break;
                    }
                    anyhow::bail!(err);
                }
                Err(err) => {
                    anyhow::bail!(err);
                }
            }
        }

        let mut samples: Vec<[f32; CHANNEL_COUNT]> = samples_interleaved
            .chunks(CHANNEL_COUNT)
            .map(|chunk| [chunk[0], chunk[1]])
            .collect();

        if Some(sample_rate) != track_sample_rate {
            // resample the sound to the device sample rate using linear interpolation
            samples = resample_linear(&samples, track_sample_rate.unwrap(), sample_rate);
        }

        Ok(SoundData(samples))
    }

    pub fn get_signal(
        sound_data: &SoundData,
        params: SoundParams,
        device_sample_rate: u32,
    ) -> SoundSignal {
        let SoundParams { spacial_params, .. } = params;

        let SoundData(samples) = sound_data;

        let channels = samples[0].len();

        match spacial_params {
            Some(SpacialParams { .. }) => {
                let signal = FramesSignal::from(oddio::Frames::from_iter(
                    device_sample_rate,
                    samples.iter().map(|sample| sample[0]).collect::<Vec<_>>(),
                ));

                SoundSignal::Mono { signal }
            }
            None => {
                let signal = FramesSignal::from(oddio::Frames::from_iter(
                    device_sample_rate,
                    samples.iter().map(|sample| {
                        [sample[0], if channels > 1 { sample[1] } else { sample[0] }]
                    }),
                ));
                SoundSignal::Stereo { signal }
            }
        }
    }

    pub fn add_sound(
        &mut self,
        sound_data: SoundData,
        params: SoundParams,
        signal: SoundSignal,
    ) -> usize {
        let sound = Sound::new(self, sound_data, params, signal);
        self.sounds.push(Some(sound));
        self.sounds.len() - 1
    }

    pub fn play_sound(&mut self, sound_index: usize) {
        if let Some(sound) = self.sounds[sound_index].as_mut() {
            sound.resume();
        }
    }

    pub fn reload_sound(&mut self, sound_index: usize, params: SoundParams) {
        if let Some(sound) = self.sounds[sound_index].take() {
            let signal = Self::get_signal(&sound.data, params.clone(), self.device_sample_rate);
            self.sounds[sound_index] = Some(Sound::new(self, sound.data, params, signal));
        }
    }

    pub fn _set_sound_volume(&mut self, sound_index: usize, volume: f32) {
        if let Some(sound) = self.sounds[sound_index].as_mut() {
            sound.set_volume(self.master_volume, volume)
        }
    }

    pub fn device_sample_rate(&self) -> u32 {
        self.device_sample_rate
    }
}

fn resample_linear(
    samples: &Vec<[f32; CHANNEL_COUNT]>,
    from_hz: u32,
    to_hz: u32,
) -> Vec<[f32; CHANNEL_COUNT]> {
    let old_sample_count = samples.len();
    let length_seconds = old_sample_count as f32 / from_hz as f32;
    let new_sample_count = (length_seconds * to_hz as f32).ceil() as usize;
    let mut result: Vec<[f32; CHANNEL_COUNT]> = Vec::new();
    result.reserve(new_sample_count);
    for new_sample_number in 1..(new_sample_count + 1) {
        let old_sample_number = new_sample_number as f32 * (from_hz as f32 / to_hz as f32);

        // get the indices of the two samples that surround the old sample number
        let left_index = old_sample_number
            .clamp(1.0, old_sample_count as f32)
            .floor() as usize
            - 1;
        let right_index = (left_index + 1).min(old_sample_count - 1);

        let left_sample = samples[left_index];
        result.push(if left_index == right_index {
            left_sample
        } else {
            let right_sample = samples[right_index];
            let t = old_sample_number - old_sample_number.floor();
            [
                (1.0 - t) * left_sample[0] + t * right_sample[0],
                (1.0 - t) * left_sample[1] + t * right_sample[1],
            ]
        });
    }
    result
}

impl Sound {
    fn new(
        audio_manager: &mut AudioManager,
        sound_data: SoundData,
        params: SoundParams,
        signal: SoundSignal,
    ) -> Self {
        let SoundParams {
            initial_volume,
            fixed_volume,
            spacial_params,
        } = params;

        let mut sound = match (spacial_params, signal) {
            (
                Some(SpacialParams {
                    initial_position,
                    initial_velocity,
                }),
                SoundSignal::Mono { signal },
            ) => {
                let signal = Gain::new(signal);

                let signal_handle = audio_manager
                    .spatial_scene_handle
                    .control::<SpatialScene, _>()
                    .play_buffered(
                        signal,
                        SpatialOptions {
                            position: [initial_position.x, initial_position.y, initial_position.z]
                                .into(),
                            velocity: [initial_velocity.x, initial_velocity.y, initial_velocity.z]
                                .into(),
                            radius: 0.1,
                        },
                        1000.0,
                        audio_manager.device_sample_rate,
                        0.1,
                    );

                Sound {
                    is_playing: true,
                    volume: initial_volume,
                    signal_handle: SoundSignalHandle::Spacial { signal_handle },
                    data: sound_data,
                }
            }
            (None, SoundSignal::Stereo { signal }) => {
                if fixed_volume {
                    let volume_amplitude_ratio =
                        (audio_manager.master_volume * initial_volume).powf(2.0);
                    let volume_db = 20.0 * volume_amplitude_ratio.log10();
                    let signal = FixedGain::new(signal, volume_db);
                    let signal_handle = audio_manager
                        .mixer_handle
                        .control::<Mixer<_>, _>()
                        .play(signal);
                    Sound {
                        is_playing: true,
                        volume: initial_volume,
                        signal_handle: SoundSignalHandle::AmbientFixed { signal_handle },
                        data: sound_data,
                    }
                } else {
                    let signal = Gain::new(signal);
                    let signal_handle = audio_manager
                        .mixer_handle
                        .control::<Mixer<_>, _>()
                        .play(signal);
                    let mut sound = Sound {
                        is_playing: true,
                        volume: initial_volume,
                        signal_handle: SoundSignalHandle::Ambient { signal_handle },
                        data: sound_data,
                    };
                    sound.set_volume(audio_manager.master_volume, initial_volume);
                    sound
                }
            }
            _ => {
                panic!("Signal didn't match spatial params");
            }
        };

        sound.pause();
        sound
    }

    fn pause(&mut self) {
        self.is_playing = false;
        match &mut self.signal_handle {
            SoundSignalHandle::Spacial { signal_handle } => {
                signal_handle.control::<Stop<_>, _>().pause();
            }
            SoundSignalHandle::Ambient { signal_handle } => {
                signal_handle.control::<Stop<_>, _>().pause();
            }
            SoundSignalHandle::AmbientFixed { signal_handle } => {
                signal_handle.control::<Stop<_>, _>().pause();
            }
        }
    }

    fn resume(&mut self) {
        self.is_playing = true;
        match &mut self.signal_handle {
            SoundSignalHandle::Spacial { signal_handle } => {
                signal_handle.control::<Stop<_>, _>().resume();
            }
            SoundSignalHandle::Ambient { signal_handle } => {
                signal_handle.control::<Stop<_>, _>().resume();
            }
            SoundSignalHandle::AmbientFixed { signal_handle } => {
                signal_handle.control::<Stop<_>, _>().resume();
            }
        }
    }

    fn set_volume(&mut self, master_volume: f32, volume: f32) {
        self.volume = volume;
        match &mut self.signal_handle {
            SoundSignalHandle::Spacial { signal_handle } => {
                signal_handle
                    .control::<Gain<_>, _>()
                    .set_amplitude_ratio((master_volume * self.volume).powf(2.0));
            }
            SoundSignalHandle::Ambient { signal_handle } => {
                signal_handle
                    .control::<Gain<_>, _>()
                    .set_amplitude_ratio((master_volume * self.volume).powf(2.0));
            }
            SoundSignalHandle::AmbientFixed { .. } => {}
        }
    }

    fn _set_motion(&mut self, position: Vec3, velocity: Vec3, discontinuity: bool) {
        if let SoundSignalHandle::Spacial { signal_handle } = &mut self.signal_handle {
            signal_handle.control::<SpatialBuffered<_>, _>().set_motion(
                [position.x, position.y, position.z].into(),
                [velocity.x, velocity.y, velocity.z].into(),
                discontinuity,
            );
        }
    }
}
