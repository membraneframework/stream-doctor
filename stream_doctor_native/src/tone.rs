use crate::DecodingError;
use itertools::Itertools;
use std::{collections, f32::consts::PI};

use bitvec::prelude::*;

const SYMBOL_MS: u32 = 30;

const DATA_BITS: u32 = 7;
const MAX_SYMBOL: u32 = 1 << DATA_BITS;

const FREQS: [u32; 9] = [500, 1000, 1500, 2000, 2500, 3000, 3500, 4000, 4500];

const AMPLITUDE: f32 = 3000.0;
const SOURCE_GAIN: f32 = 0.5;

const MIN_SCORE: u32 = 10;
const SCAN_SYMBOLS: u32 = 6;

pub struct Tone {
    sample_rate: u32,
    symbol_length: u32,
}

impl Tone {
    pub fn new(sample_rate: u32) -> Self {
        Tone {
            sample_rate,
            symbol_length: (sample_rate * SYMBOL_MS) / 1000,
        }
    }

    pub fn encode(&self, samples: &mut [i16], symbol_number: u32) {
        let bits = generate_bits(symbol_number);
        let active_freqs: Vec<f32> = FREQS
            .iter()
            .zip(bits)
            .filter(|(_, bit)| *bit)
            .map(|(freq, _)| *freq as f32)
            .map(|freq| 2.0 * PI * freq / (self.sample_rate as f32))
            .collect();

        for (i, sample) in samples.iter_mut().enumerate() {
            let tone: f32 = active_freqs
                .iter()
                .map(|freq| f32::sin(freq * i as f32) * AMPLITUDE)
                .sum::<f32>()
                .round();

            *sample = ((*sample as f32 * SOURCE_GAIN + tone) as i32).clamp(-32_768, 32_767) as i16;
        }
    }

    pub fn find_alignment(&self, samples: &[u8]) -> Result<u32, DecodingError> {
        let step = (self.symbol_length / 16).max(1) as usize;

        let mut scores: Vec<(u32, u32)> = (0..self.symbol_length)
            .step_by(step)
            .map(|offset| (offset, self.alignment_score(samples, offset)))
            .collect();

        let best_score = scores
            .iter()
            .filter(|(_, score)| *score > MIN_SCORE)
            .max_by_key(|(_, score)| score)
            .map(|&(_, score)| score);

        match best_score {
            None => Err(DecodingError::MarkersNotFound),
            Some(best_score) => Ok(plateau_center(&mut scores, best_score)),
        }
    }

    fn alignment_score(&self, samples: &[u8], offset: u32) -> u32 {
        let symbol_bytes = (self.symbol_length * 8) as usize;
        let results: Vec<Result<u32, DecodingError>> = (&samples)[(offset * 8) as usize..]
            .chunks_exact(symbol_bytes)
            .take(SCAN_SYMBOLS as usize)
            .map(|window| self.decode(window))
            .collect();

        let parity_score = results.iter().filter(|r| r.is_ok()).count() as u32;

        let sequence_score = results
            .windows(2)
            .filter(|pair| match pair {
                [Ok(a), Ok(b)] => (*a + 1) % MAX_SYMBOL == *b,
                _ => false,
            })
            .count() as u32;

        parity_score + 2 * sequence_score
    }

    pub fn decode(&self, window: &[u8]) -> Result<u32, DecodingError> {}
}

fn generate_bits(symbol_number: u32) -> BitVec {
    let n = symbol_number % MAX_SYMBOL;

    //calibration bits
    let mut bits = bitvec![1];
    // data bits, MSB first
    bits.extend((0..DATA_BITS).rev().map(|i| (n >> i) & 1 == 1));
    // parity bit
    bits.push(n.count_ones() % 2 == 1);

    bits
}
fn plateau_center(scores: &mut [(u32, u32)], best_score_value: u32) -> u32 {
    let is_best = |&(_, score_value)| score_value == best_score_value;
    let rotation = scores.iter().position(|score| !is_best(score)).unwrap_or(0);

    scores.rotate_left(rotation);
    let plateau = scores
        .chunk_by(|a, b| is_best(a) == is_best(b))
        .filter(|run| is_best(&run[0]))
        .max_by_key(|run| run.len())
        .unwrap();

    plateau[plateau.len() / 2].0
}
