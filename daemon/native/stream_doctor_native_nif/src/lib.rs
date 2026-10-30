use rustler::{Atom, Binary, Env, NewBinary, Resource, ResourceArc};
use stream_doctor_native::DecodingError;
use stream_doctor_native::bar::{self, Geometry, GeometryError};
use stream_doctor_native::tone::{self, Tone};

mod atoms {
    rustler::atoms! {
        markers_not_found,
        parity_mismatch,
    }
}

struct GeometryResource(Geometry);

#[rustler::resource_impl]
impl Resource for GeometryResource {}

struct ToneResource(Tone);

#[rustler::resource_impl]
impl Resource for ToneResource {}

fn copy<'a>(env: Env<'a>, bytes: &[u8]) -> NewBinary<'a> {
    let mut out = NewBinary::new(env, bytes.len());
    out.as_mut_slice().copy_from_slice(bytes);
    out
}

fn decoding_error(error: DecodingError) -> Atom {
    match error {
        DecodingError::MarkersNotFound => atoms::markers_not_found(),
        DecodingError::ParityMismatch => atoms::parity_mismatch(),
    }
}

#[rustler::nif]
fn bar_geometry(width: u32, height: u32) -> Result<ResourceArc<GeometryResource>, String> {
    match Geometry::new(width, height) {
        Ok(g) => Ok(ResourceArc::new(GeometryResource(g))),
        Err(GeometryError::TooNarrow(needed)) => Err(format!(
            "video is too narrow for the frame-number bar: {width}px, needs {needed}px"
        )),
        Err(GeometryError::TooShort(needed)) => Err(format!(
            "video is too short for the frame-number bar: {height}px, needs {needed}px"
        )),
    }
}

#[rustler::nif]
fn bar_max_frame() -> u32 {
    bar::max_frame()
}

#[rustler::nif(schedule = "DirtyCpu")]
fn bar_encode<'a>(
    env: Env<'a>,
    payload: Binary<'a>,
    geometry: &GeometryResource,
    frame_number: u32,
) -> Binary<'a> {
    let mut out = copy(env, payload.as_slice());
    geometry.0.encode(out.as_mut_slice(), frame_number);
    out.into()
}

#[rustler::nif(schedule = "DirtyCpu")]
fn bar_decode(payload: Binary, geometry: &GeometryResource) -> Result<u32, Atom> {
    geometry
        .0
        .decode(payload.as_slice())
        .map_err(decoding_error)
}

#[rustler::nif]
fn tone_new(sample_rate: u32) -> ResourceArc<ToneResource> {
    ResourceArc::new(ToneResource(Tone::new(sample_rate)))
}

#[rustler::nif]
fn tone_max_symbol() -> u32 {
    tone::max_symbol()
}

#[rustler::nif]
fn tone_symbol_ms() -> u32 {
    tone::symbol_ms()
}

#[rustler::nif]
fn tone_scan_symbols() -> u32 {
    tone::scan_symbols()
}

#[rustler::nif]
fn tone_symbol_length(tone: &ToneResource) -> u32 {
    tone.0.symbol_length()
}

// Erlang sub-binaries are not guaranteed to be aligned, so copy instead of align_to.
fn i16_samples(payload: Binary) -> Vec<i16> {
    payload
        .as_slice()
        .as_chunks::<2>()
        .0
        .iter()
        .map(|bytes| i16::from_le_bytes(*bytes))
        .collect()
}

#[rustler::nif(schedule = "DirtyCpu")]
fn tone_encode<'a>(
    env: Env<'a>,
    payload: Binary<'a>,
    tone: &ToneResource,
    symbol_number: u32,
) -> Binary<'a> {
    let mut samples = i16_samples(payload);
    tone.0.encode(&mut samples, symbol_number);

    let bytes: Vec<u8> = samples.iter().flat_map(|s| s.to_le_bytes()).collect();
    copy(env, &bytes).into()
}

#[rustler::nif(schedule = "DirtyCpu")]
fn tone_find_alignment(payload: Binary, tone: &ToneResource) -> Result<u32, Atom> {
    tone.0
        .find_alignment(&i16_samples(payload))
        .map_err(decoding_error)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn tone_decode(payload: Binary, tone: &ToneResource) -> Result<u32, Atom> {
    tone.0.decode(&i16_samples(payload)).map_err(decoding_error)
}

rustler::init!("Elixir.StreamDoctor.Native");
