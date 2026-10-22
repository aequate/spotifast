//! A bounded single-producer/single-consumer PCM handoff. The render side
//! takes no locks, allocates nothing, and never waits for network/decoding.
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicUsize, Ordering};

pub const CAPACITY: usize = 16_384; // 186 ms of stereo; samples + epoch tags = 128 KiB on arm64.

pub struct Pcm {
    // Held only by decoders, never by the real-time render callback.
    pub producer: std::sync::Mutex<()>,
    samples: Box<[AtomicU32]>,
    frame_epochs: Box<[AtomicUsize]>,
    read: AtomicUsize,
    write: AtomicUsize,
    pub running: AtomicBool,
    pub shutdown: AtomicBool,
    pub epoch: AtomicUsize,
    pub underruns: AtomicUsize,
    pub gain: AtomicU32,
}

impl Default for Pcm {
    fn default() -> Self {
        Self {
            producer: std::sync::Mutex::new(()),
            samples: (0..CAPACITY).map(|_| AtomicU32::new(0)).collect(),
            frame_epochs: (0..CAPACITY / 2).map(|_| AtomicUsize::new(0)).collect(),
            read: AtomicUsize::new(0),
            write: AtomicUsize::new(0),
            running: AtomicBool::new(false),
            shutdown: AtomicBool::new(false),
            epoch: AtomicUsize::new(0),
            underruns: AtomicUsize::new(0),
            gain: AtomicU32::new(1.0f32.to_bits()),
        }
    }
}

impl Pcm {
    pub fn flush(&self) {
        self.epoch.fetch_add(1, Ordering::AcqRel);
    }

    // Only the decoder writes. Samples are published after the whole block.
    pub fn push_at_epoch(&self, input: &[f64], epoch: usize) -> usize {
        let write = self.write.load(Ordering::Relaxed);
        let read = self.read.load(Ordering::Acquire);
        let count = input.len().min(CAPACITY - write.wrapping_sub(read));
        // Always publish complete stereo frames.
        let count = count & !1;
        for (i, value) in input[..count].iter().enumerate() {
            self.samples[write.wrapping_add(i) % CAPACITY]
                .store((*value as f32).to_bits(), Ordering::Relaxed);
        }
        for i in (0..count).step_by(2) {
            self.frame_epochs[write.wrapping_add(i) % CAPACITY / 2].store(epoch, Ordering::Relaxed);
        }
        self.write
            .store(write.wrapping_add(count), Ordering::Release);
        count
    }

    #[cfg(test)]
    pub fn push(&self, input: &[f64]) -> usize {
        self.push_at_epoch(input, self.epoch.load(Ordering::Acquire))
    }

    /// Only the audio render callback consumes. Buffers are planar stereo.
    pub fn render(&self, left: &mut [f32], right: &mut [f32]) {
        let epoch = self.epoch.load(Ordering::Acquire);
        if !self.running.load(Ordering::Acquire) {
            left.fill(0.0);
            right.fill(0.0);
            return;
        }
        let read = self.read.load(Ordering::Relaxed);
        let write = self.write.load(Ordering::Acquire);
        let frames = left.len().min(right.len());
        let gain = f32::from_bits(self.gain.load(Ordering::Relaxed));
        let mut consumed = 0;
        let mut rendered = 0;
        while consumed < write.wrapping_sub(read) && rendered < frames {
            let slot = read.wrapping_add(consumed) % CAPACITY;
            consumed += 2;
            // Discard only frames from before the flush. The decoder may have
            // already published replacement audio before the next callback.
            if self.frame_epochs[slot / 2].load(Ordering::Relaxed) != epoch {
                continue;
            }
            left[rendered] = (f32::from_bits(self.samples[slot].load(Ordering::Relaxed)) * gain)
                .clamp(-1.0, 1.0);
            right[rendered] = (f32::from_bits(self.samples[slot + 1].load(Ordering::Relaxed))
                * gain)
                .clamp(-1.0, 1.0);
            rendered += 1;
        }
        left[rendered..].fill(0.0);
        right[rendered..].fill(0.0);
        self.read
            .store(read.wrapping_add(consumed), Ordering::Release);
        if rendered < frames {
            self.underruns.fetch_add(1, Ordering::Relaxed);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn bounded_fifo_wraps_without_losing_stereo_order() {
        let pcm = Pcm::default();
        pcm.running.store(true, Ordering::Relaxed);
        for _ in 0..40 {
            let input: Vec<_> = (0..1000).map(|v| f64::from(v) / 1000.0).collect();
            assert_eq!(pcm.push(&input), input.len());
            let (mut l, mut r) = ([0.0; 500], [0.0; 500]);
            pcm.render(&mut l, &mut r);
            for i in 0..500 {
                assert!((l[i] - (i * 2) as f32 / 1000.0).abs() < 1e-7);
                assert!((r[i] - (i * 2 + 1) as f32 / 1000.0).abs() < 1e-7);
            }
        }
        assert_eq!(pcm.push(&vec![1.0; CAPACITY * 2]), CAPACITY);
        assert_eq!(pcm.push(&[2.0; 2]), 0);
    }
    #[test]
    fn pause_preserves_audio_flush_discards_it_and_underrun_is_silence() {
        let pcm = Pcm::default();
        pcm.push(&[0.5, -0.5]);
        let (mut l, mut r) = ([9.0; 2], [9.0; 2]);
        pcm.render(&mut l, &mut r);
        assert_eq!(l, [0.0; 2]);
        pcm.running.store(true, Ordering::Relaxed);
        pcm.render(&mut l, &mut r);
        assert_eq!(l, [0.5, 0.0]);
        assert_eq!(r, [-0.5, 0.0]);
        pcm.push(&[0.7, 0.7]);
        pcm.flush();
        pcm.render(&mut l, &mut r);
        assert_eq!(l, [0.0; 2]);
    }
    #[test]
    fn flushing_old_audio_keeps_the_first_samples_of_its_replacement() {
        let pcm = Pcm::default();
        pcm.running.store(true, Ordering::Relaxed);
        pcm.push(&[0.1, 0.1]);
        pcm.flush();
        pcm.push(&[0.7, -0.7]);
        let (mut l, mut r) = ([0.0; 1], [0.0; 1]);
        pcm.render(&mut l, &mut r);
        assert_eq!(l, [0.7]);
        assert_eq!(r, [-0.7]);
    }
    #[test]
    fn a_packet_published_during_flush_cannot_leak_old_audio() {
        let pcm = Pcm::default();
        pcm.running.store(true, Ordering::Relaxed);
        let old_epoch = pcm.epoch.load(Ordering::Acquire);
        pcm.flush();
        // A decoder that started before the flush still tags its packet with
        // the captured epoch, even if publication happens just after it.
        pcm.push_at_epoch(&[0.1, 0.1], old_epoch);
        pcm.push(&[0.7, -0.7]);
        let (mut l, mut r) = ([0.0; 1], [0.0; 1]);
        pcm.render(&mut l, &mut r);
        assert_eq!(l, [0.7]);
        assert_eq!(r, [-0.7]);
    }
    #[test]
    fn producer_consumer_stress_keeps_each_frame_in_order() {
        let pcm = std::sync::Arc::new(Pcm::default());
        pcm.running.store(true, Ordering::Relaxed);
        let producer = pcm.clone();
        let thread = std::thread::spawn(move || {
            for i in 1..=100_000 {
                while producer.push(&[f64::from(i) / 100_000.0, -f64::from(i) / 100_000.0]) == 0 {
                    std::thread::yield_now();
                }
            }
        });
        let mut expected = 1;
        while expected <= 100_000 {
            let (mut l, mut r) = ([0.0; 63], [0.0; 63]);
            pcm.render(&mut l, &mut r);
            for (l, r) in l.into_iter().zip(r) {
                if l != 0.0 {
                    assert!((l - expected as f32 / 100_000.0).abs() < 1e-7);
                    assert!((r + expected as f32 / 100_000.0).abs() < 1e-7);
                    expected += 1;
                }
            }
        }
        thread.join().unwrap();
    }
}
