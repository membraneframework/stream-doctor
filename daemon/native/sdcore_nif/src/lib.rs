use rustler::{Atom, Binary, Env, NewBinary, Resource, ResourceArc};
use sdcore::bar::{DecodingError, Geometry};

mod atoms {
    rustler::atoms! {
        markers_not_found,
        parity_mismatch,
    }
}

// orphan rule: `Resource` cannot be implemented for a type from another crate
struct GeometryResource(Geometry);

#[rustler::resource_impl]
impl Resource for GeometryResource {}

#[rustler::nif]
fn geometry(width: u32, height: u32) -> ResourceArc<GeometryResource> {
    ResourceArc::new(GeometryResource(Geometry::new(width, height)))
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
