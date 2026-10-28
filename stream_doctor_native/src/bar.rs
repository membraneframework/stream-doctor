//! A black bar at the bottom of the frame with `TOTAL_SQUARES` squares. The first square is white, the
//! second is black. They show the decoder what white and black look like. The next `DATA_BITS` squares
//! are the frame number, highest bit first. The last square is a parity bit.
//! Works only with I420 frames.

use std::{array::from_fn, iter::zip};

use bitvec::prelude::*;

const DATA_BITS: u32 = 14;
const TOTAL_SQUARES: u32 = 2 + DATA_BITS + 1;
const MAX_FRAME: u32 = 1 << DATA_BITS;

const WHITE: u8 = 235;
const BLACK: u8 = 16;
const NEUTRAL_CHROMA: u8 = 128;

const MIN_CONTRAST: f32 = 32.0;

/// Position and size of the bar and its squares for one resolution.
///
/// Create it once with [`Geometry::new`] and use it for every frame.
#[derive(Debug, PartialEq)]
pub struct Geometry {
    width: u32,
    height: u32,
    square_size: u32,
    bar_top_y: u32,
    square_top_y: u32,
    square_xs: [u32; TOTAL_SQUARES as usize],
}

#[derive(Debug, PartialEq)]
pub enum GeometryError {
    /// The frame is too narrow to fit all squares. Carries the width it would need.
    TooNarrow(u32),
    /// The frame is too short to fit the bar. Carries the height it would need.
    TooShort(u32),
}

#[derive(Debug, PartialEq)]
pub enum DecodingError {
    /// There is no bar in this frame.
    MarkersNotFound,
    /// There is a bar, but the parity bit does not match. The frame is probably damaged.
    ParityMismatch,
}

/// The frame number starts from zero again when it reaches this value.
#[must_use]
pub const fn max_frame() -> u32 {
    MAX_FRAME
}

impl Geometry {
    /// Computes the bar layout for a frame of this size.
    ///
    /// # Errors
    /// Fails when the frame is too small to fit the bar.
    pub fn new(width: u32, height: u32) -> Result<Self, GeometryError> {
        let square_size = round_to_even((width / 24).max(8));
        let gap = round_to_even((square_size / 4).max(2));
        let pad_width = gap;

        let needed_width = pad_width + TOTAL_SQUARES * (square_size + gap);
        if needed_width > width {
            return Err(GeometryError::TooNarrow(needed_width));
        }
        let bar_height = square_size + 2 * pad_width;
        if bar_height > height {
            return Err(GeometryError::TooShort(bar_height));
        }

        Ok(Geometry {
            width,
            height,
            square_size,
            bar_top_y: height - bar_height,
            square_top_y: height - gap - square_size,
            square_xs: from_fn(|i| pad_width + i as u32 * (square_size + gap)),
        })
    }

    /// Draws the bar with `frame_number` on the frame. Changes `binary` in place.
    ///
    /// Numbers bigger than [`max_frame`] wrap around.
    ///
    /// # Panics
    /// When `binary` is not an I420 frame of this geometry's size.
    pub fn encode(&self, binary: &mut [u8], frame_number: u32) {
        let width = self.width as usize;
        let y_size = width * self.height as usize;
        let chroma_size = y_size / 4;
        self.check_frame_size(binary);

        let (y, chroma) = binary.split_at_mut(y_size);
        let (u, v) = chroma.split_at_mut(chroma_size);

        y[self.bar_top_y as usize * width..].fill(BLACK);

        let squares_row = self.squares_row(&generate_bits(frame_number));
        for row in self.square_top_y..self.square_top_y + self.square_size {
            let start = row as usize * width;
            y[start..start + width].copy_from_slice(&squares_row);
        }

        let chroma_kept = (self.bar_top_y / 2 * (self.width / 2)) as usize;
        u[chroma_kept..].fill(NEUTRAL_CHROMA);
        v[chroma_kept..].fill(NEUTRAL_CHROMA);
    }

    fn check_frame_size(&self, binary: &[u8]) {
        let expected = (self.width * self.height * 3 / 2) as usize;
        assert_eq!(
            binary.len(),
            expected,
            "expected an I420 frame of {}x{} ({expected} bytes), got {} bytes",
            self.width,
            self.height,
            binary.len()
        );
    }

    /// Reads the frame number from the bar on the frame.
    ///
    /// # Errors
    /// Fails when the markers are missing or the parity bit does not match.
    ///
    /// # Panics
    /// When `binary` is not an I420 frame of this geometry's size.
    pub fn decode(&self, binary: &[u8]) -> Result<u32, DecodingError> {
        self.check_frame_size(binary);
        let y_size = (self.width * self.height) as usize;
        let y_plane = &binary[..y_size];

        let square_luma_averages = self.square_xs.map(|x| self.square_luma_average(y_plane, x));
        let white_reference = square_luma_averages[0];
        let black_reference = square_luma_averages[1];

        if white_reference - black_reference < MIN_CONTRAST {
            return Err(DecodingError::MarkersNotFound);
        }

        let threshold = f32::midpoint(white_reference, black_reference);
        let bits: BitVec = square_luma_averages
            .iter()
            .map(|&v| v > threshold)
            .collect();

        let parity_bit = bits[(TOTAL_SQUARES - 1) as usize];

        let data_bits = &bits[2..(TOTAL_SQUARES - 1) as usize];

        if (data_bits.count_ones() % 2 != 0) == parity_bit {
            Ok(data_bits.load_be::<u32>())
        } else {
            Err(DecodingError::ParityMismatch)
        }
    }

    fn squares_row(&self, bits: &BitVec) -> Vec<u8> {
        let mut row = vec![BLACK; self.width as usize];

        for (x, bit) in zip(self.square_xs, bits) {
            if *bit {
                row[x as usize..(x + self.square_size) as usize].fill(WHITE);
            }
        }
        row
    }

    fn square_luma_average(&self, y_plane: &[u8], x: u32) -> f32 {
        let margin = self.square_size / 4;
        let x0 = x + margin;
        let y0 = self.square_top_y + margin;
        let side = self.square_size - 2 * margin;

        (y0..y0 + side)
            .map(|row| {
                let start = row * self.width + x0;
                let sum: u32 = y_plane[start as usize..(start + side) as usize]
                    .iter()
                    .map(|x| u32::from(*x))
                    .sum();
                sum as f32 / side as f32
            })
            .sum::<f32>()
            / side as f32
    }
}

fn generate_bits(frame_number: u32) -> BitVec {
    let n = frame_number % MAX_FRAME;

    //calibration bits
    let mut bits = bitvec![0; TOTAL_SQUARES as usize];
    bits.set(0, true);
    bits.set(1, false);
    // data bits, MSB first
    bits[2..(TOTAL_SQUARES - 1) as usize].store_be(n);
    // parity bit
    bits.set((TOTAL_SQUARES - 1) as usize, n.count_ones() % 2 == 1);

    bits
}

fn round_to_even(n: u32) -> u32 {
    n & !1
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encodes_and_decodes() {
        let (width, height) = (640, 360);
        let geometry = Geometry::new(width, height).unwrap();
        let frame_size = (width * height * 3 / 2) as usize;

        for frame_number in [0, 1, 42, 12_345, MAX_FRAME - 1, MAX_FRAME + 7] {
            let mut frame = vec![128; frame_size];
            geometry.encode(&mut frame, frame_number);
            assert_eq!(geometry.decode(&frame).ok(), Some(frame_number % MAX_FRAME));
        }

        assert!(geometry.decode(&vec![128; frame_size]).is_err());
    }

    #[test]
    #[should_panic(expected = "expected an I420 frame of 640x360")]
    fn panics_on_a_frame_of_the_wrong_size() {
        Geometry::new(640, 360).unwrap().decode(&[128; 1000]).ok();
    }

    #[test]
    fn rejects_frames_too_small_for_the_bar() {
        assert!(matches!(
            Geometry::new(100, 360),
            Err(GeometryError::TooNarrow(needed)) if needed > 100
        ));
        assert!(matches!(
            Geometry::new(640, 10),
            Err(GeometryError::TooShort(needed)) if needed > 10
        ));
    }
}
