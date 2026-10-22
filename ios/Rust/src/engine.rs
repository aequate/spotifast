use crate::{eq, limiter::Limiter, pcm::Pcm};
use librespot_connect::{
    ConnectConfig, LoadContextOptions, LoadRequest, LoadRequestOptions, Options, PlayingTrack,
    Spirc,
};
use librespot_core::{
    SpotifyUri,
    authentication::Credentials,
    config::{DeviceType, SessionConfig},
    session::Session,
};
use librespot_playback::{
    audio_backend::{Sink, SinkError, SinkResult},
    config::{Bitrate, PlayerConfig},
    convert::Converter,
    decoder::AudioPacket,
    mixer::{self, Mixer, MixerConfig, NoOpVolume},
    player::{Player, PlayerEvent},
};
use serde::{Deserialize, Serialize};
use std::{
    ffi::c_void,
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
    },
    time::{Duration, Instant},
};

pub type Callback = unsafe extern "C" fn(*mut c_void);

#[derive(Clone)]
pub struct Notify(pub Option<Callback>, pub usize);
impl Notify {
    pub fn fire(&self) {
        if let Some(callback) = self.0 {
            // SAFETY: host retains the callback context until sf_destroy returns.
            unsafe { callback(self.1 as *mut c_void) };
        }
    }
}

#[derive(Default, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub generation: u64,
    pub active: bool,
    pub connected: bool,
    pub connecting: bool,
    pub device_id: String,
    pub username: String,
    pub playing: bool,
    pub loading: bool,
    pub uri: Option<String>,
    pub title: String,
    pub artists: Vec<String>,
    pub album: String,
    pub cover_url: Option<String>,
    pub duration_ms: u32,
    pub position_ms: u32,
    pub shuffle: bool,
    pub repeat: String,
    pub volume: u16,
    pub context_uri: String,
    pub queue: Vec<QueueRow>,
    pub error: Option<String>,
    pub revision: u64,
    pub lyrics: Option<serde_json::Value>,
    pub lyrics_uri: Option<String>,
    #[serde(skip)]
    lyrics_request: u64,
    #[serde(skip)]
    pub at: Option<Instant>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QueueRow {
    pub uri: String,
    pub manual: bool,
}

#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
pub enum Command {
    Connect {
        token: Option<String>,
        credentials: Option<Credentials>,
        username: String,
        device_id: String,
        name: String,
        bitrate: u16,
        normalisation: bool,
        gapless: bool,
        cache_directory: Option<String>,
    },
    Disconnect,
    Play,
    Pause,
    Next,
    Previous,
    Transfer,
    Seek {
        position_ms: u32,
    },
    Volume {
        value: u16,
    },
    Shuffle {
        enabled: bool,
    },
    Repeat {
        mode: String,
    },
    Load {
        context: Option<String>,
        uris: Vec<String>,
        offset: Option<u32>,
        #[serde(default)]
        queued: Vec<String>,
    },
    Queue {
        uris: Vec<String>,
    },
    ClearQueue,
    RewriteQueue {
        uris: Vec<String>,
    },
    SkipQueue {
        index: usize,
    },
    Restore {
        context: String,
        uri: String,
        position_ms: u32,
        uris: Vec<String>,
    },
    Lyrics {
        uri: String,
    },
    Eq {
        enabled: bool,
        preamp: f32,
        bands: [f32; 10],
        balance: f32,
        mono: bool,
    },
}

struct Running {
    spirc: Spirc,
    player: Arc<Player>,
    session: Session,
    mixer: Arc<dyn Mixer>,
}

pub struct Engine {
    pub runtime: Option<tokio::runtime::Runtime>,
    pub pcm: Arc<Pcm>,
    pub snapshot: Arc<Mutex<Snapshot>>,
    pub notify: Notify,
    eq: eq::SharedEq,
    current: Arc<Mutex<Option<Running>>>,
    credentials: Arc<Mutex<Option<Credentials>>>,
    generation: Arc<AtomicU64>,
}

impl Engine {
    pub fn new(notify: Notify) -> Result<Self, String> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .thread_name("spotifast-ios")
            .build()
            .map_err(|_| "Unable to start playback runtime")?;
        Ok(Self {
            runtime: Some(runtime),
            pcm: Arc::default(),
            snapshot: Arc::default(),
            notify,
            eq: eq::shared(),
            current: Arc::default(),
            credentials: Arc::default(),
            generation: Arc::default(),
        })
    }

    pub fn snapshot(&self) -> Snapshot {
        let mut state = self
            .snapshot
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .clone();
        if state.playing {
            state.position_ms = state
                .position_ms
                .saturating_add(state.at.map_or(0, |at| {
                    at.elapsed().as_millis().min(u128::from(u32::MAX)) as u32
                }))
                .min(state.duration_ms);
        }
        state
    }

    pub fn credentials(&self) -> Option<Credentials> {
        self.credentials
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .clone()
    }

    pub fn fail(&self, message: &str) {
        let mut state = self.snapshot.lock().unwrap_or_else(|p| p.into_inner());
        state.error = Some(message.to_owned());
        state.revision += 1;
        drop(state);
        self.notify.fire();
    }

    pub fn disconnect(&self) {
        let generation = self
            .generation
            .fetch_add(1, Ordering::SeqCst)
            .wrapping_add(1);
        self.pcm.shutdown.store(true, Ordering::Release);
        {
            let _producer = self.pcm.producer.lock().unwrap_or_else(|p| p.into_inner());
            self.pcm.running.store(false, Ordering::Release);
            self.pcm.flush();
        }
        if let Some(current) = self
            .current
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .take()
        {
            let _ = current.spirc.shutdown();
            current.player.stop();
            current.session.shutdown();
        }
        *self.credentials.lock().unwrap_or_else(|p| p.into_inner()) = None;
        *self.snapshot.lock().unwrap_or_else(|p| p.into_inner()) = Snapshot {
            generation,
            ..Snapshot::default()
        };
        self.notify.fire();
    }

    pub fn command(&self, command: Command) -> Result<(), String> {
        match command {
            Command::Connect {
                token,
                credentials,
                username,
                device_id,
                name,
                bitrate,
                normalisation,
                gapless,
                cache_directory,
            } => {
                if username.is_empty() || device_id.len() < 16 || name.len() > 100 {
                    return Err("Invalid playback configuration".into());
                }
                let credentials = credentials
                    .or_else(|| {
                        token
                            .filter(|t| !t.is_empty())
                            .map(Credentials::with_access_token)
                    })
                    .ok_or("Authorize streaming before connecting")?;
                self.disconnect();
                let generation = self.generation.load(Ordering::SeqCst);
                self.pcm.shutdown.store(false, Ordering::Release);
                let shared = self.snapshot.clone();
                *shared.lock().unwrap_or_else(|p| p.into_inner()) = Snapshot {
                    generation,
                    connecting: true,
                    device_id: device_id.clone(),
                    volume: u16::MAX,
                    repeat: "off".into(),
                    ..Snapshot::default()
                };
                self.notify.fire();
                let pcm = self.pcm.clone();
                let eq = self.eq.clone();
                let notify = self.notify.clone();
                let target = self.current.clone();
                let saved = self.credentials.clone();
                let generations = self.generation.clone();
                self.runtime.as_ref().ok_or("Runtime stopped")?.spawn(async move {
                    let cache = match crate::cache::open(cache_directory.as_deref().map(std::path::Path::new)) {
                        Ok(cache) => cache,
                        Err(_) => {
                            let mut state = shared.lock().unwrap_or_else(|p| p.into_inner());
                            if generations.load(Ordering::SeqCst) != generation { return; }
                            state.connecting = false;
                            state.error = Some("The audio cache could not open. Clear the cache in Settings and reconnect.".into());
                            state.revision += 1; drop(state); notify.fire(); return;
                        }
                    };
                    let session = Session::new(SessionConfig { device_id: device_id.clone(), autoplay: Some(false), ..SessionConfig::default() }, Some(cache));
                    let Some(build_mixer) = mixer::find(Some("softvol")) else { return; };
                    let Ok(mixer) = build_mixer(MixerConfig::default()) else { return; };
                    mixer.set_volume(u16::MAX);
                    let output = pcm.clone();
                    let soft_volume = mixer.get_soft_volume();
                    let sink_generations = generations.clone();
                    let sink_notify = notify.clone();
                    let player = Player::new(PlayerConfig {
                        bitrate: match bitrate { 96 => Bitrate::Bitrate96, 320 => Bitrate::Bitrate320, _ => Bitrate::Bitrate160 },
                        normalisation, gapless, position_update_interval: None, ..PlayerConfig::default()
                    }, session.clone(), Box::new(NoOpVolume), move || Box::new(IosSink { pcm: output, eq: eq::Processor::new(eq), limiter: Limiter::new(44_100.0), epoch: 0, volume: soft_volume, generations: sink_generations, generation, notify: sink_notify }));
                    let mut events = player.get_player_event_channel();
                    let result = tokio::time::timeout(Duration::from_secs(75), Spirc::new(ConnectConfig { name, device_type: DeviceType::Smartphone, initial_volume: u16::MAX, emit_set_queue_events: true, ..ConnectConfig::default() }, session.clone(), credentials, player.clone(), mixer.clone())).await;
                    if generations.load(Ordering::SeqCst) != generation { player.stop(); session.shutdown(); return; }
                    let (spirc, task) = match result {
                        Ok(Ok(connected)) => connected,
                        _ => {
                            player.stop(); session.shutdown();
                            let mut state = shared.lock().unwrap_or_else(|p| p.into_inner());
                            if generations.load(Ordering::SeqCst) != generation { return; }
                            state.connecting = false;
                            state.error = Some("Spotify playback could not connect. Check Premium, streaming authorization, and your connection; then reconnect.".into());
                            state.revision += 1; drop(state); notify.fire(); return;
                        }
                    };
                    if session.username() != username {
                        let _ = spirc.shutdown(); player.stop(); session.shutdown();
                        let mut state = shared.lock().unwrap_or_else(|p| p.into_inner());
                        if generations.load(Ordering::SeqCst) != generation { return; }
                        state.connecting = false; state.error = Some("Playback and library must use the same Spotify account".into());
                        state.revision += 1; drop(state); notify.fire(); return;
                    }
                    let mut cluster = spirc.watch_cluster_state();
                    let event_volume = mixer.get_soft_volume();
                    {
                        let mut current = target.lock().unwrap_or_else(|p| p.into_inner());
                        if generations.load(Ordering::SeqCst) != generation { let _ = spirc.shutdown(); player.stop(); session.shutdown(); return; }
                        *saved.lock().unwrap_or_else(|p| p.into_inner()) = session.cache().and_then(|cache| cache.credentials());
                        *current = Some(Running { spirc, player: player.clone(), session: session.clone(), mixer });
                        let mut state = shared.lock().unwrap_or_else(|p| p.into_inner());
                        state.connected = true; state.connecting = false; state.username = session.username(); state.revision += 1;
                    }
                    notify.fire();
                    tokio::pin!(task);
                    let mut request_id = None;
                    loop {
                        tokio::select! {
                            _ = &mut task => break,
                            changed = cluster.changed() => {
                                if changed.is_err() { break; }
                                let mut state = shared.lock().unwrap_or_else(|p| p.into_inner());
                                if generations.load(Ordering::SeqCst) != generation { break; }
                                state.active = cluster.borrow().active_device_id.as_deref() == Some(device_id.as_str());
                                state.revision += 1; drop(state); notify.fire();
                            }
                            event = events.recv() => {
                                let Some(event) = event else { break; };
                                if generations.load(Ordering::SeqCst) != generation { break; }
                                if let PlayerEvent::PlayRequestIdChanged { play_request_id } = &event { request_id = Some(*play_request_id); }
                                if request_id.zip(event.get_play_request_id()).is_some_and(|(current, incoming)| current != incoming) { continue; }
                                {
                                    let mut state = shared.lock().unwrap_or_else(|p| p.into_inner());
                                    if generations.load(Ordering::SeqCst) != generation { break; }
                                    if matches!(event, PlayerEvent::VolumeChanged { .. }) { pcm.gain.store((event_volume.attenuation_factor() as f32).to_bits(), Ordering::Relaxed); }
                                    apply_event(&mut state, &pcm, event);
                                }
                                notify.fire();
                            }
                        }
                    }
                    let mut current = target.lock().unwrap_or_else(|p| p.into_inner());
                    if generations.load(Ordering::SeqCst) == generation {
                        pcm.running.store(false, Ordering::Release);
                        pcm.shutdown.store(true, Ordering::Release);
                        player.stop(); session.shutdown();
                        *current = None;
                        let mut state = shared.lock().unwrap_or_else(|p| p.into_inner());
                        state.connected = false; state.playing = false; state.error = Some("Spotify disconnected. Tap Reconnect in Settings.".into());
                        state.revision += 1; drop(state); notify.fire();
                    }
                });
                return Ok(());
            }
            Command::Disconnect => {
                self.disconnect();
                return Ok(());
            }
            Command::Pause => {
                // iOS may already have stopped the render callback. Release a
                // decoder waiting on a full ring before queuing player pause,
                // including while a connection is being torn down.
                self.pcm.flush();
            }
            Command::Eq {
                enabled,
                preamp,
                bands,
                balance,
                mono,
            } => {
                if !preamp.is_finite()
                    || !balance.is_finite()
                    || bands.iter().any(|g| !g.is_finite())
                {
                    return Err("Equalizer values must be finite".into());
                }
                *self.eq.lock().unwrap_or_else(|p| p.into_inner()) = eq::EqSettings {
                    on: enabled,
                    preamp_db: preamp,
                    bands_db: bands,
                    balance,
                    mono,
                }
                .clamped();
                return Ok(());
            }
            _ => {}
        }
        let current = self.current.lock().unwrap_or_else(|p| p.into_inner());
        let current = current
            .as_ref()
            .ok_or("Connect playback on this iPhone first")?;
        let spirc = &current.spirc;
        if matches!(
            &command,
            Command::Queue { .. }
                | Command::RewriteQueue { .. }
                | Command::ClearQueue
                | Command::SkipQueue { .. }
        ) && !self.snapshot().active
        {
            return Err("Queue changes require this iPhone to be the active player".into());
        }
        let parse =
            |uri: &str| SpotifyUri::from_uri(uri).map_err(|_| "Invalid Spotify URI".to_owned());
        let result = match command {
            Command::Play => spirc.play(),
            Command::Pause => {
                current.player.pause();
                let result = spirc.pause();
                self.pcm.flush();
                result
            }
            Command::Next => {
                self.pcm.flush();
                spirc.next()
            }
            Command::Previous => {
                self.pcm.flush();
                spirc.prev()
            }
            Command::Transfer => spirc.transfer(None),
            Command::Seek { position_ms } => spirc.set_position_ms(position_ms),
            Command::Volume { value } => {
                current.mixer.set_volume(value);
                self.pcm.gain.store(
                    (current.mixer.get_soft_volume().attenuation_factor() as f32).to_bits(),
                    Ordering::Relaxed,
                );
                spirc.set_volume(value)
            }
            Command::Shuffle { enabled } => spirc.shuffle(enabled),
            Command::Repeat { mode } => {
                if !["off", "context", "track"].contains(&mode.as_str()) {
                    return Err("Invalid repeat mode".into());
                }
                spirc
                    .repeat_track(mode == "track")
                    .map_err(|_| "Playback command failed")?;
                spirc.repeat(mode == "context")
            }
            Command::Load {
                context,
                uris,
                offset,
                queued,
            } => {
                let manual = queued
                    .iter()
                    .map(|u| parse(u))
                    .collect::<Result<Vec<_>, _>>()?;
                if let Some(uri) = &context {
                    parse(uri)?;
                }
                for uri in &uris {
                    parse(uri)?;
                }
                if context.is_none() && uris.is_empty() {
                    return Err("Nothing to play".into());
                }
                let state = self.snapshot();
                let options = LoadRequestOptions {
                    start_playing: true,
                    seek_to: 0,
                    playing_track: offset.map(PlayingTrack::Index),
                    context_options: Some(LoadContextOptions::Options(Options {
                        shuffle: state.shuffle,
                        repeat: state.repeat == "context",
                        repeat_track: state.repeat == "track",
                    })),
                };
                let request = match context {
                    Some(uri) => LoadRequest::from_context_uri(uri, options),
                    None => LoadRequest::from_tracks(uris, options),
                };
                self.pcm.flush();
                spirc.activate().map_err(|_| "Unable to activate iPhone")?;
                spirc
                    .load(request)
                    .map_err(|_| "Could not start this collection")?;
                // A load clears librespot's upcoming list. Re-add the manual
                // occurrences only, preserving duplicates and their order.
                for uri in manual {
                    spirc
                        .add_to_queue(uri)
                        .map_err(|_| "Could not preserve every queued song")?;
                }
                Ok(())
            }
            Command::Queue { uris } => {
                let tracks = uris
                    .iter()
                    .map(|u| parse(u))
                    .collect::<Result<Vec<_>, _>>()?;
                for uri in tracks {
                    spirc.add_to_queue(uri).map_err(|_| "Queue update failed")?;
                }
                Ok(())
            }
            Command::RewriteQueue { uris } => {
                let tracks = uris
                    .iter()
                    .map(|u| parse(u))
                    .collect::<Result<Vec<_>, _>>()?;
                spirc
                    .clear_queue()
                    .map_err(|_| "Queue could not be cleared")?;
                for uri in tracks {
                    spirc.add_to_queue(uri).map_err(
                        |_| "Queue rewrite stopped. Reload the queue before trying again.",
                    )?;
                }
                Ok(())
            }
            Command::ClearQueue => spirc.clear_queue(),
            Command::Restore {
                context,
                uri,
                position_ms,
                uris,
            } => {
                parse(&uri)?;
                let tracks = uris
                    .iter()
                    .map(|u| parse(u))
                    .collect::<Result<Vec<_>, _>>()?;
                let options = LoadRequestOptions {
                    start_playing: false,
                    seek_to: position_ms,
                    playing_track: Some(PlayingTrack::Uri(uri.clone())),
                    ..LoadRequestOptions::default()
                };
                let request = if context.is_empty() {
                    LoadRequest::from_tracks(vec![uri], options)
                } else {
                    parse(&context)?;
                    LoadRequest::from_context_uri(context, options)
                };
                spirc.activate().map_err(|_| "Unable to activate iPhone")?;
                spirc
                    .load(request)
                    .map_err(|_| "Could not restore the previous track")?;
                for track in tracks {
                    spirc
                        .add_to_queue(track)
                        .map_err(|_| "Could not restore every queued song")?;
                }
                Ok(())
            }
            Command::Lyrics { uri } => {
                let id = uri
                    .strip_prefix("spotify:track:")
                    .and_then(|id| librespot_core::spotify_id::SpotifyId::from_base62(id).ok())
                    .ok_or("Lyrics are available for Spotify tracks only")?;
                let session = current.session.clone();
                let shared = self.snapshot.clone();
                let notify = self.notify.clone();
                let generations = self.generation.clone();
                let generation = generations.load(Ordering::SeqCst);
                let request = {
                    let mut state = shared.lock().unwrap_or_else(|p| p.into_inner());
                    state.lyrics_request += 1;
                    state.lyrics_request
                };
                self.runtime
                    .as_ref()
                    .ok_or("Runtime stopped")?
                    .spawn(async move {
                        let result = tokio::time::timeout(
                            Duration::from_secs(20),
                            session.spclient().get_lyrics(&id),
                        )
                        .await;
                        if generations.load(Ordering::SeqCst) != generation {
                            return;
                        }
                        let lyrics = match result {
                            Ok(Ok(bytes)) => serde_json::from_slice(&bytes).ok(),
                            _ => None,
                        };
                        let mut state = shared.lock().unwrap_or_else(|p| p.into_inner());
                        if generations.load(Ordering::SeqCst) != generation
                            || state.lyrics_request != request
                        {
                            return;
                        }
                        state.lyrics = lyrics;
                        state.lyrics_uri = Some(uri);
                        state.revision += 1;
                        drop(state);
                        notify.fire();
                    });
                Ok(())
            }
            Command::SkipQueue { index } => {
                let state = self.snapshot();
                if index >= state.queue.len() {
                    return Err("Queue changed. Try again.".into());
                }
                // Each skip goes through Spirc so duplicate occurrences stay distinct.
                self.pcm.flush();
                for _ in 0..=index {
                    spirc.next().map_err(|_| "Queue skip failed")?;
                }
                Ok(())
            }
            _ => return Err("Invalid playback command".into()),
        };
        result.map_err(|_| "Spotify could not accept the playback command".into())
    }
}

fn apply_event(state: &mut Snapshot, pcm: &Pcm, event: PlayerEvent) {
    match event {
        PlayerEvent::Loading { position_ms, .. } => {
            state.loading = true;
            state.position_ms = position_ms;
            state.at = None;
        }
        PlayerEvent::Playing { position_ms, .. } => {
            state.playing = true;
            state.loading = false;
            state.position_ms = position_ms;
            state.at = Some(Instant::now());
            state.error = None;
        }
        PlayerEvent::Paused { position_ms, .. } => {
            state.playing = false;
            state.loading = false;
            state.position_ms = position_ms;
            state.at = None;
        }
        PlayerEvent::Stopped { .. } => {
            state.playing = false;
            state.loading = false;
            state.at = None;
            pcm.flush();
        }
        PlayerEvent::PositionChanged { position_ms, .. }
        | PlayerEvent::PositionCorrection { position_ms, .. } => {
            state.position_ms = position_ms;
            state.at = state.playing.then(Instant::now);
        }
        PlayerEvent::Seeked { position_ms, .. } => {
            pcm.flush();
            state.position_ms = position_ms;
            state.at = state.playing.then(Instant::now);
        }
        PlayerEvent::TrackChanged { audio_item } => {
            state.uri = Some(audio_item.track_id.to_uri());
            state.title = audio_item.name.clone();
            state.duration_ms = audio_item.duration_ms;
            state.cover_url = audio_item.covers.first().map(|image| image.url.clone());
            use librespot_metadata::audio::UniqueFields;
            match audio_item.unique_fields {
                UniqueFields::Track { artists, album, .. } => {
                    state.artists = artists.iter().map(|a| a.name.clone()).collect();
                    state.album = album;
                }
                UniqueFields::Episode { show_name, .. } => {
                    state.artists = vec![show_name];
                    state.album.clear();
                }
                UniqueFields::Local { artists, album, .. } => {
                    state.artists = artists.into_iter().collect();
                    state.album = album.unwrap_or_default();
                }
            }
        }
        PlayerEvent::VolumeChanged { volume } => state.volume = volume,
        PlayerEvent::ShuffleChanged { shuffle } => state.shuffle = shuffle,
        PlayerEvent::RepeatChanged { context, track } => {
            state.repeat = if track {
                "track"
            } else if context {
                "context"
            } else {
                "off"
            }
            .into()
        }
        PlayerEvent::SetQueue {
            context_uri,
            next_tracks,
            ..
        } => {
            state.context_uri = context_uri;
            state.queue = next_tracks
                .into_iter()
                .map(|t| QueueRow {
                    uri: t.uri,
                    manual: t.provider == "queue",
                })
                .collect();
        }
        PlayerEvent::Unavailable { .. } | PlayerEvent::AudioKeyUnavailable { .. } => {
            state.loading = false;
            state.error = Some(
                "Spotify could not play this item. Check availability and Premium access.".into(),
            );
        }
        _ => return,
    }
    state.revision += 1;
}

struct IosSink {
    pcm: Arc<Pcm>,
    eq: eq::Processor,
    limiter: Limiter,
    epoch: usize,
    volume: Box<dyn librespot_playback::mixer::VolumeGetter + Send>,
    generations: Arc<AtomicU64>,
    generation: u64,
    notify: Notify,
}
impl Sink for IosSink {
    fn start(&mut self) -> SinkResult<()> {
        let _producer = self.pcm.producer.lock().unwrap_or_else(|p| p.into_inner());
        if self.generations.load(Ordering::SeqCst) == self.generation {
            self.pcm.running.store(true, Ordering::Release);
            self.notify.fire();
        }
        Ok(())
    }
    fn stop(&mut self) -> SinkResult<()> {
        let _producer = self.pcm.producer.lock().unwrap_or_else(|p| p.into_inner());
        if self.generations.load(Ordering::SeqCst) == self.generation {
            self.pcm.running.store(false, Ordering::Release);
            self.notify.fire();
        }
        Ok(())
    }
    fn write(&mut self, packet: AudioPacket, _: &mut Converter) -> SinkResult<()> {
        let pcm = self.pcm.clone();
        let _producer = pcm.producer.lock().unwrap_or_else(|p| p.into_inner());
        let AudioPacket::Samples(mut samples) = packet else {
            return Err(SinkError::InvalidParams("PCM required".into()));
        };
        let epoch = self.pcm.epoch.load(Ordering::Acquire);
        if epoch != self.epoch {
            self.eq.reset();
            self.limiter = Limiter::new(44_100.0);
            self.epoch = epoch;
        }
        self.eq.process(&mut samples);
        // Volume is applied to queued audio at render time.
        let gain = self.volume.attenuation_factor();
        self.pcm
            .gain
            .store((gain as f32).to_bits(), Ordering::Relaxed);
        self.limiter
            .process(&mut samples, if gain > 0.0 { 1.0 / gain } else { 1.0 });
        let mut sent = 0;
        let mut progressed = Instant::now();
        while sent < samples.len() {
            if self.pcm.shutdown.load(Ordering::Acquire)
                || self.generations.load(Ordering::SeqCst) != self.generation
            {
                return Err(SinkError::NotConnected("Playback stopped".into()));
            }
            if epoch != self.pcm.epoch.load(Ordering::Acquire) {
                return Ok(());
            }
            let count = self.pcm.push_at_epoch(&samples[sent..], epoch);
            sent += count;
            if count > 0 {
                progressed = Instant::now();
            } else if progressed.elapsed() >= Duration::from_secs(2) {
                // A failed native audio route must not keep a decoder thread
                // spinning indefinitely if a pause races the last packet.
                return Err(SinkError::NotConnected("Audio output stopped".into()));
            }
            if sent < samples.len() {
                std::thread::sleep(Duration::from_millis(10));
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn snapshots_distinguish_replaced_connections_after_revision_resets() {
        let engine = super::Engine::new(super::Notify(None, 0)).unwrap();
        let initial = serde_json::to_value(engine.snapshot()).unwrap();
        let mut previous = initial["generation"]
            .as_u64()
            .expect("snapshot needs a connection generation");
        for _ in 0..32 {
            engine.disconnect();
            let next = serde_json::to_value(engine.snapshot()).unwrap();
            let current = next["generation"].as_u64().unwrap();
            assert!(current > previous);
            previous = current;
        }
    }
    use super::*;
    use librespot_playback::player::QueueTrack;

    fn apply_event(shared: &Mutex<Snapshot>, pcm: &Pcm, event: PlayerEvent) {
        super::apply_event(&mut shared.lock().unwrap(), pcm, event);
    }

    #[test]
    fn playback_credential_is_retained_in_memory_for_the_native_keychain_handoff() {
        let cache = crate::cache::open(None).unwrap();
        assert!(cache.credentials().is_none());
        let grant = Credentials::with_access_token("temporary-test-grant");
        cache.save_credentials(&grant);
        assert_eq!(cache.credentials(), Some(grant));
    }

    #[test]
    fn sink_notifies_native_audio_even_without_another_player_event() {
        use std::sync::atomic::AtomicUsize;
        unsafe extern "C" fn changed(context: *mut c_void) {
            // SAFETY: this test keeps the counter alive for both calls.
            unsafe { &*context.cast::<AtomicUsize>() }.fetch_add(1, Ordering::Relaxed);
        }
        let changes = AtomicUsize::new(0);
        let pcm = Arc::new(Pcm::default());
        let mut sink = IosSink {
            pcm: pcm.clone(),
            eq: eq::Processor::new(eq::shared()),
            limiter: Limiter::new(44_100.0),
            epoch: 0,
            volume: Box::new(NoOpVolume),
            generations: Arc::new(AtomicU64::new(1)),
            generation: 1,
            notify: Notify(Some(changed), (&changes as *const AtomicUsize) as usize),
        };
        sink.start().unwrap();
        assert!(pcm.running.load(Ordering::Relaxed));
        sink.stop().unwrap();
        assert!(!pcm.running.load(Ordering::Relaxed));
        assert_eq!(changes.load(Ordering::Relaxed), 2);
    }

    #[test]
    fn pause_releases_a_decoder_when_native_output_has_stopped() {
        let engine = Engine::new(Notify(None, 0)).unwrap();
        engine.pcm.push(&vec![0.25; crate::pcm::CAPACITY]);
        let mut sink = IosSink {
            pcm: engine.pcm.clone(),
            eq: eq::Processor::new(eq::shared()),
            limiter: Limiter::new(44_100.0),
            epoch: 0,
            volume: Box::new(NoOpVolume),
            generations: engine.generation.clone(),
            generation: 0,
            notify: Notify(None, 0),
        };
        let (finished, completion) = std::sync::mpsc::channel();
        let writer = std::thread::spawn(move || {
            let result = sink.write(
                AudioPacket::Samples(vec![0.5; 2]),
                &mut Converter::new(None),
            );
            finished.send(result.is_ok()).unwrap();
        });
        // The ring is full and there is deliberately no render consumer.
        assert!(completion.recv_timeout(Duration::from_millis(50)).is_err());
        // A session is not needed to test the preemption. An absent Spirc may
        // reject pause, but it must still release the blocked audio writer.
        let _ = engine.command(Command::Pause);
        let completed = completion.recv_timeout(Duration::from_millis(500));
        engine.pcm.shutdown.store(true, Ordering::Release);
        writer.join().unwrap();
        assert_eq!(completed.ok(), Some(true));
    }

    #[test]
    fn stalled_native_output_has_a_bounded_decoder_wait() {
        let pcm = Arc::new(Pcm::default());
        pcm.push(&vec![0.25; crate::pcm::CAPACITY]);
        let mut sink = IosSink {
            pcm,
            eq: eq::Processor::new(eq::shared()),
            limiter: Limiter::new(44_100.0),
            epoch: 0,
            volume: Box::new(NoOpVolume),
            generations: Arc::new(AtomicU64::new(0)),
            generation: 0,
            notify: Notify(None, 0),
        };
        let began = Instant::now();
        assert!(
            sink.write(
                AudioPacket::Samples(vec![0.5; 2]),
                &mut Converter::new(None)
            )
            .is_err()
        );
        assert!(began.elapsed() < Duration::from_secs(4));
    }

    #[test]
    fn queue_snapshot_preserves_duplicate_occurrences_and_manual_context_boundary() {
        let state = Mutex::new(Snapshot::default());
        let pcm = Pcm::default();
        apply_event(
            &state,
            &pcm,
            PlayerEvent::SetQueue {
                context_uri: "spotify:album:collection".into(),
                current_track: None,
                prev_tracks: vec![],
                next_tracks: vec![
                    QueueTrack {
                        uri: "spotify:track:repeat".into(),
                        provider: "queue".into(),
                    },
                    QueueTrack {
                        uri: "spotify:track:repeat".into(),
                        provider: "queue".into(),
                    },
                    QueueTrack {
                        uri: "spotify:track:repeat".into(),
                        provider: "context".into(),
                    },
                ],
            },
        );
        let state = state.lock().unwrap();
        assert_eq!(state.queue.len(), 3);
        assert!(state.queue[0].manual && state.queue[1].manual);
        assert!(!state.queue[2].manual);
    }

    #[test]
    fn pause_retains_audio_but_confirmed_seek_invalidates_old_pcm() {
        let state = Mutex::new(Snapshot::default());
        let pcm = Pcm::default();
        let track_id = SpotifyUri::from_uri("spotify:track:4uLU6hMCjMI75M1A2tKUQC").unwrap();
        apply_event(
            &state,
            &pcm,
            PlayerEvent::Playing {
                play_request_id: 1,
                track_id: track_id.clone(),
                position_ms: 100,
            },
        );
        assert!(state.lock().unwrap().playing);
        apply_event(
            &state,
            &pcm,
            PlayerEvent::Paused {
                play_request_id: 1,
                track_id: track_id.clone(),
                position_ms: 200,
            },
        );
        assert!(!state.lock().unwrap().playing);
        assert_eq!(pcm.epoch.load(Ordering::Relaxed), 0);
        apply_event(
            &state,
            &pcm,
            PlayerEvent::Seeked {
                play_request_id: 1,
                track_id,
                position_ms: 1000,
            },
        );
        assert_eq!(pcm.epoch.load(Ordering::Relaxed), 1);
        assert_eq!(state.lock().unwrap().position_ms, 1000);
    }

    #[test]
    fn replaced_decoder_cannot_publish_or_stop_its_replacement() {
        let pcm = Arc::new(Pcm::default());
        let generations = Arc::new(AtomicU64::new(2));
        let mut sink = IosSink {
            pcm: pcm.clone(),
            eq: eq::Processor::new(eq::shared()),
            limiter: Limiter::new(44_100.0),
            epoch: 0,
            volume: Box::new(NoOpVolume),
            generations,
            generation: 1,
            notify: Notify(None, 0),
        };
        sink.start().unwrap();
        assert!(!pcm.running.load(Ordering::Relaxed));
        pcm.running.store(true, Ordering::Relaxed);
        sink.stop().unwrap();
        assert!(pcm.running.load(Ordering::Relaxed));
        let mut converter = Converter::new(None);
        assert!(
            sink.write(AudioPacket::Samples(vec![0.5; 10]), &mut converter)
                .is_err()
        );
        let (mut l, mut r) = ([9.0; 5], [9.0; 5]);
        pcm.render(&mut l, &mut r);
        assert_eq!(l, [0.0; 5]);
    }

    #[test]
    fn queue_payloads_and_settings_use_the_real_abi_schema() {
        let command: Command = serde_json::from_value(serde_json::json!({"op":"load", "context":null, "uris":["spotify:track:4uLU6hMCjMI75M1A2tKUQC"], "offset":null, "queued":["a","a"]})).unwrap();
        assert!(matches!(command, Command::Load { queued, .. } if queued == ["a", "a"]));
        let engine = Engine::new(Notify(None, 0)).unwrap();
        assert!(
            engine
                .command(Command::Eq {
                    enabled: true,
                    preamp: f32::NAN,
                    bands: [0.0; 10],
                    balance: 0.0,
                    mono: false
                })
                .is_err()
        );
        assert!(engine.command(Command::Queue { uris: vec![] }).is_err());
    }
}
