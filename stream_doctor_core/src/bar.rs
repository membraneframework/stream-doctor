use std::{array::from_fn, iter::zip};

use bitvec::prelude::*;

const DATA_BITS: u32 = 14;
const TOTAL_SQUARES: u32 = 2 + DATA_BITS + 1;
const MAX_FRAMES: u32 = 1 << DATA_BITS;

const WHITE: u8 = 235;
const BLACK: u8 = 16;
const NEUTRAL_CHROMA: u8 = 128;

const MIN_CONTRAST: u8 = 32;

pub struct Geometry {
    width: u32,
    height: u32,
    square_size: u32,
    pad_width: u32,
    bar_top_y: u32,
    square_top_y: u32,
    square_xs: [u32; TOTAL_SQUARES as usize],
}

pub enum DecodingError {
    MarkersNotFound,
    ParityMismatch,
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
            pad_width,
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

    pub fn decode(&self, payload: &[u8]) -> Result<u32, DecodingError> {
        todo!()
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

        todo!()
    }
}

fn generate_bits(frame_number: u32) -> BitVec {
    let n = frame_number & MAX_FRAMES;
    let mut bits = bitvec![0; TOTAL_SQUARES as usize];

    // callibration bits
    bits.set(0, true);
    bits.set(1, false);

    // actual data
    let sum = (0..DATA_BITS)
        .rev()
        .reduce(|sum, i| {
            let value = (n >> i) & 1;
            bits.set(i as usize, value != 0);
            i + sum
        })
        .unwrap();

    // parity
    bits.set((DATA_BITS - 1) as usize, (sum % 2) != 0);

    bits
}

fn even(n: u32) -> u32 {
    n & !1
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encodes_bar() {}
}
