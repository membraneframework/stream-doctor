use std::{array::from_fn, iter::zip};

use bitvec::prelude::*;

const DATA_BITS: u32 = 14;
const TOTAL_SQUARES: u32 = 2 + DATA_BITS + 1;
const MAX_FRAME: u32 = 1 << DATA_BITS;

const WHITE: u8 = 235;
const BLACK: u8 = 16;
const NEUTRAL_CHROMA: u8 = 128;

const MIN_CONTRAST: u8 = 32;

pub struct Geometry {
    width: u32,
    height: u32,
    square_size: u32,
    bar_top_y: u32,
    square_top_y: u32,
    square_xs: [u32; TOTAL_SQUARES as usize],
}

pub enum DecodingError {
    MarkersNotFound,
    ParityMismatch,
}

pub fn max_frame() -> u32 {
    MAX_FRAME
}

impl Geometry {
    pub fn new(width: u32, height: u32) -> Self {
        let square_size = even((width / 24).max(8));
        let gap = even((square_size / 4).max(2));
        let pad_width = gap;

        let needed_width = pad_width + TOTAL_SQUARES * (square_size + gap);
        if needed_width > width {
            panic!(
                "Video is too narrow for the frame-number bar: \n\
                {width}px available, #{needed_width}px needed"
            );
        }
        let bar_height = square_size + 2 * pad_width;

        Geometry {
            width,
            height,
            square_size,
            bar_top_y: height.wrapping_sub(bar_height),
            square_top_y: height.wrapping_sub(gap).wrapping_sub(square_size),
            square_xs: from_fn(|i| pad_width + i as u32 * (square_size + gap)),
        }
    }

    pub fn encode(&self, binary: &mut [u8], frame_number: u32) {
        let y_size = (self.width * self.height) as usize;
        let chroma_size = y_size / 4;

        let y = &mut binary[..y_size];

        let bits = generate_bits(frame_number);

        let background_row = vec![BLACK; self.width as usize];
        let squares_row = self.squares_row(&bits);

        let bar_rows: Vec<&[u8]> = (self.bar_top_y..self.height)
            .map(|row| {
                if self.square_top_y <= row && row < self.square_top_y + self.square_size {
                    &squares_row[..]
                } else {
                    &background_row[..]
                }
            })
            .collect();

        let bar_rows: Vec<u8> = bar_rows.concat();

        y[(self.bar_top_y * self.width) as usize..].copy_from_slice(&bar_rows);

        let chroma_width = self.width / 2;
        let chroma_bar_top_y = self.bar_top_y / 2;
        let chroma_kept = chroma_bar_top_y * chroma_width;
        let chroma_fill = vec![NEUTRAL_CHROMA; chroma_size - chroma_kept as usize];

        let u = &mut binary[y_size..y_size + chroma_size];
        u[chroma_kept as usize..].copy_from_slice(&chroma_fill);
        let v = &mut binary[y_size + chroma_size..];
        v[chroma_kept as usize..].copy_from_slice(&chroma_fill);
    }

    pub fn decode(&self, binary: &[u8]) -> Result<u32, DecodingError> {
        let y_size = (self.width * self.height) as usize;
        let y_plane = &binary[..y_size];

        let square_luma_averages = self.square_xs.map(|x| self.square_luma_average(y_plane, x));
        let white_reference = square_luma_averages[0];
        let black_reference = square_luma_averages[1];

        if white_reference - black_reference < MIN_CONTRAST as f32 {
            return Err(DecodingError::MarkersNotFound);
        }

        let threshold = (white_reference + black_reference) / 2.0;
        let bits: BitVec = square_luma_averages
            .iter()
            .map(|&v| v > threshold)
            .collect();

        let parity_bit = bits.last().unwrap();

        let data_bits = &bits[2..(TOTAL_SQUARES - 1) as usize];

        if (data_bits.count_ones() % 2 != 0) != *parity_bit {
            Err(DecodingError::ParityMismatch)
        } else {
            Ok(data_bits.iter().fold(0, |n, bit| (n << 1) | *bit as u32))
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
                    .map(|x| *x as u32)
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
    let mut bits = bitvec![1, 0];
    // data bits, MSB first
    bits.extend((0..DATA_BITS).rev().map(|i| (n >> i) & 1 == 1));
    // parity bit
    bits.push(n.count_ones() % 2 == 1);

    bits
}

fn even(n: u32) -> u32 {
    n & !1
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encodes_and_decodes() {
        let (width, height) = (640, 360);
        let geometry = Geometry::new(width, height);
        let frame_size = (width * height * 3 / 2) as usize;

        for frame_number in [0, 1, 42, 12_345, MAX_FRAME - 1, MAX_FRAME + 7] {
            let mut frame = vec![128; frame_size];
            geometry.encode(&mut frame, frame_number);
            assert_eq!(geometry.decode(&frame).ok(), Some(frame_number % MAX_FRAME));
        }

        assert!(geometry.decode(&vec![128; frame_size]).is_err());
    }
}
