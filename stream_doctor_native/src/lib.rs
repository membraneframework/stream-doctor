pub mod bar;
pub mod tone;

#[derive(Debug, PartialEq)]
pub enum DecodingError {
    /// There is no marker in this frame
    MarkersNotFound,
    /// There is a marker, but the parity bit does not match. The frame is probably damaged.
    ParityMismatch,
}
