//! An audio marker made of `SYMBOL_MS` long symbols. Each symbol is a mix of sine tones from
//! `FREQS`: the first one is always on and gives the decoder a reference level, the next
//! `DATA_BITS` carry the symbol number with the highest bit first, and the last one is a parity
//! bit. The symbol number wraps at `MAX_SYMBOL`.
//!
//! The decoder runs a Goertzel filter over the inner two thirds of the window, which makes it
//! tolerant to a few ms of misalignment. A tone counts as on when its power clearly beats the
//! guard bins `GUARD_OFFSET` Hz on either side of it. Comparing against the neighbours rather than
//! an absolute level is what lets the marker survive the spectral tilt that codecs add.

use crate::{DecodingError, generate_bits};
use bitvec::prelude::*;
use std::f32::consts::PI;

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

#[derive(Debug, PartialEq)]
pub struct Tone {
    sample_rate: u32,
    symbol_length: u32,
}

impl Tone {
    #[must_use]
    pub fn new(sample_rate: u32) -> Self {
        Tone {
            sample_rate,
            symbol_length: (sample_rate * SYMBOL_MS) / 1000,
        }
    }

    #[must_use]
    pub fn symbol_length(&self) -> u32 {
        self.symbol_length
    }

    pub fn encode(&self, samples: &mut [i16], symbol_number: u32) {
        self.check_window_size(samples);
        let bits = generate_bits(symbol_number, DATA_BITS as usize, bitvec![u8, Msb0; 1]);
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

            *sample = (f32::from(*sample) * SOURCE_GAIN + tone)
                .clamp(f32::from(i16::MIN), f32::from(i16::MAX)) as i16;
        }
    }

    /// Finds the sample offset at which the symbols in `samples` start.
    ///
    /// # Errors
    /// Fails with `MarkersNotFound` when no offset decodes enough consecutive symbols.
    pub fn find_alignment(&self, samples: &[i16]) -> Result<u32, DecodingError> {
        let step = (self.symbol_length / 16).max(1) as usize;

        let mut scores: Vec<(u32, u32)> = (0..self.symbol_length)
            .step_by(step)
            .map(|offset| (offset, self.alignment_score(samples, offset)))
            .collect();

        let best_score = scores
            .iter()
            .filter(|(_, score)| *score >= MIN_SCORE)
            .max_by_key(|(_, score)| score)
            .map(|&(_, score)| score);

        match best_score {
            None => Err(DecodingError::MarkersNotFound),
            Some(best_score) => Ok(plateau_center(&mut scores, best_score)),
        }
    }

    fn check_window_size(&self, window: &[i16]) {
        assert_eq!(
            window.len(),
            self.symbol_length as usize,
            "expected a window of {} samples, got {}",
            self.symbol_length,
            window.len()
        );
    }

    fn alignment_score(&self, samples: &[i16], offset: u32) -> u32 {
        let results: Vec<Result<u32, DecodingError>> = samples[offset as usize..]
            .chunks_exact(self.symbol_length as usize)
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

    /// Decodes the symbol carried by one symbol-length window of samples.
    ///
    /// # Errors
    /// Fails with `MarkersNotFound` when the reference tone is missing,
    /// or `ParityMismatch` when the data bits do not match the parity bit.
    pub fn decode(&self, window: &[i16]) -> Result<u32, DecodingError> {
        self.check_window_size(window);
        let margin = self.symbol_length / 6;
        let inner_n = self.symbol_length - 2 * margin;
        let inner = &window[margin as usize..(margin + inner_n) as usize];
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
                u32::from(on)
            })
            .collect();
        let (data, parity) = bits.split_at(DATA_BITS as usize);

        if data.iter().sum::<u32>() % 2 != parity[0] {
            return Err(DecodingError::ParityMismatch);
        }
        Ok(data.iter().fold(0, |acc, bit| acc * 2 + bit))
    }
}

#[must_use]
pub fn max_symbol() -> u32 {
    MAX_SYMBOL
}

#[must_use]
pub fn symbol_ms() -> u32 {
    SYMBOL_MS
}

#[must_use]
pub fn scan_symbols() -> u32 {
    SCAN_SYMBOLS
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

fn goertzel_power(samples: &[i16], n: u32, freq: u32, sample_rate: u32) -> f64 {
    let k = (f64::from(freq * n) / f64::from(sample_rate)).round();
    let omega = 2.0 * std::f64::consts::PI * k / f64::from(n);
    let coeff = 2.0 * f64::cos(omega);
    let (s1, s2) = samples.iter().fold((0.0, 0.0), |(s1, s2), sample| {
        (f64::from(*sample) + coeff * s1 - s2, s1)
    });
    s1 * s1 + s2 * s2 - coeff * s1 * s2
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
            assert_eq!(tone.decode(&samples), Ok(symbol));
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
        let found = tone.find_alignment(&samples).unwrap() as usize;
        let step = symbol_length / 16;
        assert!(
            found.abs_diff(offset) <= step,
            "found {found}, expected {offset}"
        );
    }

    #[test]
    fn find_alignment_in_silence_is_not_a_marker() {
        let tone = Tone::new(48_000);
        let samples = vec![0i16; tone.symbol_length as usize * 8];
        assert_eq!(
            tone.find_alignment(&samples),
            Err(DecodingError::MarkersNotFound)
        );
    }

    #[test]
    #[should_panic(expected = "expected a window of 1440 samples")]
    fn panics_on_a_window_of_the_wrong_size() {
        Tone::new(48_000).decode(&[0; 1000]).ok();
    }

    #[test]
    fn decode_silence_is_not_a_marker() {
        let tone = Tone::new(48_000);
        let window = vec![0i16; tone.symbol_length as usize];
        assert_eq!(tone.decode(&window), Err(DecodingError::MarkersNotFound));
    }
}
