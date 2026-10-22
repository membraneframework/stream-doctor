use std::{arch::aarch64::float16x4x2_t, iter::zip};

use bitvec::prelude::*;

const DATA_BITS = 14;
const TOTAL_SQUARES=2 + DATA_BITS + 1;
const MAX_FRAMES = 1 << DATA_BITS;

const WHITE: u8 = 235;
const BLACK: u8 = 16;
const NEUTRAL_CHROMA: u8 = 128;

const MIN_CONTRAST = 32;

pub struct Geometry {
    width: u32,
    height: u32,
    square: u32,
    pad: u32,
    bar_top: u32,
    square_top: u32,
    xs: [u32; TOTAL_SQUARES],
}

pub enum DecodingError{
    MarkersNotFound,
    ParityMismatch
}


impl Geometry {
    pub fn new(width: u32, height: u32) -> Self {
        let square = even((width / 24).max(8));
        let gap = even((square / 4).max(2));
        let pad = gap;

        let needed_width = pad + TOTAL_SQUARES*(square + gap);
        if needed_width > width {
            panic!("Video is too narrow for the frame-number bar: \n\
                {width}px available, #{needed_width}px needed");
        }
        let bar_height = square + 2*pad;

        Geometry {
            width: width,
            height: height,
            square: square,
            pad: pad,
            bar_top: height.wrapping_sub(bar_height),
            square_top: height.wrapping_sub(gap).wrapping_sub(square),
            xs: (0..TOTAL_SQUARES).map(|i| (pad + i*(square+gap)) as i32).collect()
        }
    }

    
    pub fn encode(&self, binary: &mut [u8], frame_number: u32) {
        let y_size = (self.width * self.height) as usize;
        let chroma_size = y_size / 4;

        let y = &mut binary[..y_size];

        let bits = self.generate_bits(frame_number);

        let background_row = vec![BLACK; self.width as usize];
        let squares_row = self.squares_row(&bits);

        let bar_rows: Vec<&[u8]> = (self.bar_top..self.height-1).map(|row|
            if self.square_top<=row && row < self.square_top+self.square {
                &squares_row[..]
          } else {
                &background_row[..]
            }
        ).collect();

        let bar_rows: Vec<u8> = bar_rows.concat();

        y[..(self.bar_top*self.width) as usize].copy_from_slice(&bar_rows);
        
        let chroma_width = self.width / 2;
        let chroma_bar_top = self.bar_top / 2;
        let chroma_kept = chroma_bar_top * chroma_width;
        let chroma_fill = vec![NEUTRAL_CHROMA; chroma_size - chroma_kept as usize];

        let u = &mut binary[y_size..y_size+chroma_size];
        u[chroma_kept as usize..].copy_from_slice(&chroma_fill);
        let v = &mut binary[y_size+chroma_size..];
        v[chroma_kept as usize..].copy_from_slice(&chroma_fill);
    }

    pub fn decode(&self, payload: &[u8]) -> Result<u32, DecodingError>{

        Err(DecodingError::MarkersNotFound)
    }

    fn generate_bits(&self, frame_number: u32) -> BitVec {
        let n = frame_number & MAX_FRAMES;
        let mut bits =  bitvec![0; TOTAL_SQUARES];

        // callibration bits
        bits.set(0, true);
        bits.set(1, false);

        // actual data
        let sum = (DATA_BITS-1..0).reduce(|i, sum| {
            let value = (n >> i) & 1;
            bits.set(i, value != 0);
            i+sum
        });

        // parity
        bits.set(DATA_BITS-1, (sum % 2) != 0);

        bits
    }

    fn squares_row(&self, bits: &BitVec) -> Vec<u8> {
        let mut row = vec![BLACK; self.width as usize];

        for (&x, &bit) in zip(self.xs, bits) {
            if bit {
                row[x as usize..(x+self.square) as usize].fill(WHITE);
            }
            
        }
        row
    }

    fn square_luma_average(&self, y_plane: &[u8], x: u32) -> f32 {
        let margin = self.square / 4;
        x0 = x + margin
        y0 = self.square_top + margin
        side = self.square - 2*margin

        0.0
    
    }
}


fn even(n: u32) -> u32 {
    n & !1
}
