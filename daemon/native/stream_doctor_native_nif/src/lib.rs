use rustler::{Atom, Binary, Env, NewBinary, Resource, ResourceArc};
use stream_doctor_native::DecodingError;
use stream_doctor_native::bar::{self, Geometry, GeometryError};
use stream_doctor_native::tone::Tone;

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

fn copy<'a>(env: Env<'a>, payload: Binary<'a>) -> NewBinary<'a> {
    let mut out = NewBinary::new(env, payload.len());
    out.as_mut_slice().copy_from_slice(payload.as_slice());
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
    let mut out = copy(env, payload);
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

#[rustler::nif(schedule = "DirtyCpu")]
fn tone_encode<'a>(
    env: Env<'a>,
    payload: Binary<'a>,
    tone: &ToneResource,
    symbol_number: u32,
) -> Binary<'a> {
    let mut out = copy(env, payload);
    // NewBinary is VM-allocated and word aligned, so the i16 view has no leftovers.
    let (_, samples, _) = unsafe { out.as_mut_slice().align_to_mut::<i16>() };
    tone.0.encode(samples, symbol_number);
    out.into()
}

// Erlang sub-binaries are not guaranteed to be 8-byte aligned, so copy instead of align_to.
fn f64_samples(payload: Binary) -> Vec<f64> {
    payload
        .as_slice()
        .as_chunks::<8>()
        .0
        .iter()
        .map(|bytes| f64::from_le_bytes(*bytes))
        .collect()
}

#[rustler::nif(schedule = "DirtyCpu")]
fn tone_find_alignment(payload: Binary, tone: &ToneResource) -> Result<u32, Atom> {
    tone.0
        .find_alignment(&f64_samples(payload))
        .map_err(decoding_error)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn tone_decode(payload: Binary, tone: &ToneResource) -> Result<u32, Atom> {
    tone.0.decode(&f64_samples(payload)).map_err(decoding_error)
}

rustler::init!("Elixir.StreamDoctor.Native");
