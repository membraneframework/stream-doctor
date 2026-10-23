use rustler::{Atom, Binary, Env, NewBinary, Resource, ResourceArc};
use stream_doctor_core::bar::max_frame as bar_max_frame;
use stream_doctor_core::bar::{DecodingError, Geometry, GeometryError};

mod atoms {
    rustler::atoms! {
        markers_not_found,
        parity_mismatch,
    }
}

struct GeometryResource(Geometry);

#[rustler::resource_impl]
impl Resource for GeometryResource {}

#[rustler::nif(name = "geometry_native")]
fn geometry(width: u32, height: u32) -> Result<ResourceArc<GeometryResource>, String> {
    Geometry::new(width, height)
        .map(|g| ResourceArc::new(GeometryResource(g)))
        .map_err(|e| match e {
            GeometryError::TooNarrow => format!("video is too narrow for the frame-number bar: {width}px"),
            GeometryError::TooShort => format!("video is too short for the frame-number bar: {height}px"),
        })
}

#[rustler::nif]
fn max_frame() -> u32 {
    bar_max_frame()
}

#[rustler::nif(schedule = "DirtyCpu")]
fn encode<'a>(
    env: Env<'a>,
    payload: Binary<'a>,
    geometry: ResourceArc<GeometryResource>,
    frame_number: u32,
) -> Binary<'a> {
    let mut out = NewBinary::new(env, payload.len());
    out.as_mut_slice().copy_from_slice(payload.as_slice());
    geometry.0.encode(out.as_mut_slice(), frame_number);
    out.into()
}

#[rustler::nif(schedule = "DirtyCpu")]
fn decode(payload: Binary, geometry: ResourceArc<GeometryResource>) -> Result<u32, Atom> {
    geometry.0.decode(payload.as_slice()).map_err(|e| match e {
        DecodingError::MarkersNotFound => atoms::markers_not_found(),
        DecodingError::ParityMismatch => atoms::parity_mismatch(),
    })
}

rustler::init!("Elixir.StreamDoctor.Probe.Video.Bar");
