use crate::DecodingError;
use std::f32::consts::PI;

use bitvec::prelude::*;

const SYMBOL_MS: u32 = 30;

const DATA_BITS: u32 = 7;
const MAX_SYMBOL: u32 = 1 << DATA_BITS;

const FREQS: [u32; 9] = [500, 1000, 1500, 2000, 2500, 3000, 3500, 4000, 4500];

const AMPLITUDE: f32 = 3000.0;
const SOURCE_GAIN: f32 = 0.5;

const GUARD_OFFSET: u32 = 250;
const LOCAL_CONTRAST: f64 = 8.0;
const REF_FLOOR: f64 = 0.01;

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
        let results: Vec<Result<u32, DecodingError>> = samples[(offset * 8) as usize..]
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

    pub fn decode(&self, window: &[u8]) -> Result<u32, DecodingError> {
        let margin = self.symbol_length / 6;
        let inner_n = self.symbol_length - 2 * margin;
        let inner = &window[(margin * 8) as usize..((margin + inner_n) * 8) as usize];
        let power = |freq| goertzel_power(inner, inner_n, freq, self.sample_rate);
        let local_noise = |freq: u32| power(freq - GUARD_OFFSET).max(power(freq + GUARD_OFFSET));

        let ref_power = power(FREQS[0]);
        if ref_power < LOCAL_CONTRAST * local_noise(FREQS[0]).max(1.0e-9) {
            return Err(DecodingError::MarkersNotFound);
        }

        let bits: Vec<u32> = FREQS[1..]
            .iter()
            .map(|&freq| {
                let tone_power = power(freq);
                let on = tone_power > LOCAL_CONTRAST * local_noise(freq)
                    && tone_power > REF_FLOOR * ref_power;
                on as u32
            })
            .collect();
        let (data, parity) = bits.split_at(DATA_BITS as usize);

        if data.iter().sum::<u32>() % 2 != parity[0] {
            return Err(DecodingError::ParityMismatch);
        }
        Ok(data.iter().fold(0, |acc, bit| acc * 2 + bit))
    }
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
    let is_best = |&(_, score_value): &(u32, u32)| score_value == best_score_value;
    let rotation = scores.iter().position(|score| !is_best(score)).unwrap_or(0);
    scores.rotate_left(rotation);
    let plateau = scores
        .chunk_by(|a, b| is_best(a) == is_best(b))
        .filter(|run| is_best(&run[0]))
        .max_by_key(|run| run.len())
        .unwrap();

    plateau[plateau.len() / 2].0
}

fn goertzel_power(samples: &[u8], n: u32, freq: u32, sample_rate: u32) -> f64 {
    let k = ((freq * n) as f64 / sample_rate as f64).round();
    let omega: f64 = 2.0 * PI as f64 * k / n as f64;
    let coeff = 2.0 * f64::cos(omega);
    let (s1, s2) = goertzel_loop(samples, coeff);
    s1 * s1 + s2 * s2 - coeff * s1 * s2
}

fn goertzel_loop(samples: &[u8], coeff: f64) -> (f64, f64) {
    let mut s1 = 0.0;
    let mut s2 = 0.0;
    for sample in samples.as_chunks::<8>().0 {
        let sample = f64::from_le_bytes(*sample);
        let tmp = s1;
        s1 = sample + coeff * s1 - s2;
        s2 = tmp;
    }
    (s1, s2)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decode_round_trip() {
        let tone = Tone::new(48_000);
        for symbol in [0, 1, 42, 127] {
            let mut samples = vec![0i16; tone.symbol_length as usize];
            tone.encode(&mut samples, symbol);
            let window: Vec<u8> = samples
                .iter()
                .flat_map(|s| (*s as f64).to_le_bytes())
                .collect();
            assert_eq!(tone.decode(&window), Ok(symbol));
        }
    }

    #[test]
    fn find_alignment_recovers_symbol_offset() {
        let tone = Tone::new(48_000);
        let symbol_length = tone.symbol_length as usize;
        let offset = symbol_length / 3;
        let mut samples = vec![0i16; symbol_length * (SCAN_SYMBOLS as usize + 2)];
        for (i, chunk) in samples[offset..]
            .chunks_exact_mut(symbol_length)
            .enumerate()
        {
            tone.encode(chunk, 100 + i as u32);
        }
        let bytes: Vec<u8> = samples
            .iter()
            .flat_map(|s| (*s as f64).to_le_bytes())
            .collect();
        let found = tone.find_alignment(&bytes).unwrap() as usize;
        let step = symbol_length / 16;
        assert!(
            found.abs_diff(offset) <= step,
            "found {found}, expected {offset}"
        );
    }

    #[test]
    fn find_alignment_in_silence_is_not_a_marker() {
        let tone = Tone::new(48_000);
        let bytes = vec![0u8; tone.symbol_length as usize * 8 * 8];
        assert_eq!(
            tone.find_alignment(&bytes),
            Err(DecodingError::MarkersNotFound)
        );
    }

    #[test]
    fn decode_silence_is_not_a_marker() {
        let tone = Tone::new(48_000);
        let window = vec![0u8; tone.symbol_length as usize * 8];
        assert_eq!(tone.decode(&window), Err(DecodingError::MarkersNotFound));
    }
}
