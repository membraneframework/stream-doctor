pub mod bar;
pub mod tone;
use bitvec::prelude::*;

#[derive(Debug, PartialEq)]
#[non_exhaustive]
pub enum DecodingError {
    /// There is no marker in this frame
    MarkersNotFound,
    /// There is a marker, but the parity bit does not match. The frame is probably damaged.
    ParityMismatch,
}

/// Encodes `number` as marker bits, prefixed with the calibration bits and
/// followed by a parity bit. Data bits are stored with the highest bit first.
pub fn generate_bits(number: u32, data_bits: usize, calibration_bits: BitVec) -> BitVec {
    let n = number % (1 << data_bits);

    let mut bits = calibration_bits;
    // data bits, MSB first
    bits.extend((0..data_bits).rev().map(|i| (n >> i) & 1 == 1));
    // parity bit
    bits.push(n.count_ones() % 2 == 1);

    bits
}
