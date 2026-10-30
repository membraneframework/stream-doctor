use rustler::{Atom, Binary, Env, NewBinary, Resource, ResourceArc};
use stream_doctor_native::DecodingError;
use stream_doctor_native::bar::{self, Bar, BarError};
use stream_doctor_native::tone::{self, Tone};

mod atoms {
    rustler::atoms! {
        markers_not_found,
        parity_mismatch,
    }
}

struct BarResource(Bar);

#[rustler::resource_impl]
impl Resource for BarResource {}

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
fn bar_new(width: u32, height: u32) -> Result<ResourceArc<BarResource>, String> {
    match Bar::new(width, height) {
        Ok(bar) => Ok(ResourceArc::new(BarResource(bar))),
        Err(BarError::TooNarrow(needed)) => Err(format!(
            "video is too narrow for the frame-number bar: {width}px, needs {needed}px"
        )),
        Err(BarError::TooShort(needed)) => Err(format!(
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
    bar: &BarResource,
    frame_number: u32,
) -> Binary<'a> {
    let mut out = copy(env, payload.as_slice());
    bar.0.encode(out.as_mut_slice(), frame_number);
    out.into()
}

#[rustler::nif(schedule = "DirtyCpu")]
fn bar_decode(payload: Binary, bar: &BarResource) -> Result<u32, Atom> {
    bar.0.decode(payload.as_slice()).map_err(decoding_error)
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
fn tone_symbol_bytes(tone: &ToneResource) -> u32 {
    tone.0.symbol_bytes()
}

#[rustler::nif(schedule = "DirtyCpu")]
fn tone_encode<'a>(
    env: Env<'a>,
    payload: Binary<'a>,
    tone: &ToneResource,
    symbol_number: u32,
) -> Binary<'a> {
    let mut out = copy(env, payload.as_slice());
    tone.0.encode(out.as_mut_slice(), symbol_number);
    out.into()
}

#[rustler::nif(schedule = "DirtyCpu")]
fn tone_find_alignment(payload: Binary, tone: &ToneResource) -> Result<u32, Atom> {
    tone.0
        .find_alignment(payload.as_slice())
        .map_err(decoding_error)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn tone_decode(payload: Binary, tone: &ToneResource) -> Result<u32, Atom> {
    tone.0.decode(payload.as_slice()).map_err(decoding_error)
}

rustler::init!("Elixir.StreamDoctor.Native");
