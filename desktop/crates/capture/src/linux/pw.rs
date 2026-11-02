//! The portal's PipeWire stream, on its own thread. Asks for 4-byte RGB
//! formats in shared memory (no DMA-BUF: we read pixels on the CPU) and for
//! cursor metadata, then hands frames to the encoder clock and cursor
//! positions to the pointer log.

use std::os::fd::OwnedFd;
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

use pipewire as pw;
use pw::properties::properties;
use pw::spa;
use pw::spa::param::video::{VideoFormat, VideoInfoRaw};
use pw::spa::pod::{Pod, Property, PropertyFlags, Value};
use pw::spa::utils::{Fraction, Rectangle, SpaTypes};

use crate::pipe::{Frame, FrameSlot, PixelFormat};
use crate::CaptureError;

#[derive(Clone, Copy, Debug)]
pub(crate) struct Negotiated {
    pub width: u32,
    pub height: u32,
    pub format: PixelFormat,
}

/// Cursor position from the stream's metadata, in frame pixels.
pub(crate) type CursorSink = Arc<dyn Fn(f64, f64) + Send + Sync>;

pub(crate) struct PwStream {
    stop: pw::channel::Sender<()>,
    thread: Option<JoinHandle<()>>,
    /// Set once the encoder runs; frames before it are dropped.
    pub slot: Arc<Mutex<Option<FrameSlot>>>,
    pub cursor: Arc<Mutex<Option<CursorSink>>>,
}

struct Data {
    info: VideoInfoRaw,
    size: (u32, u32),
    format: Option<PixelFormat>,
    negotiated: Option<mpsc::Sender<Result<Negotiated, String>>>,
    slot: Arc<Mutex<Option<FrameSlot>>>,
    cursor: Arc<Mutex<Option<CursorSink>>>,
}

fn pixel_format(f: VideoFormat) -> Option<PixelFormat> {
    match f {
        VideoFormat::BGRx => Some(PixelFormat::Bgrx),
        VideoFormat::BGRA => Some(PixelFormat::Bgra),
        VideoFormat::RGBx => Some(PixelFormat::Rgbx),
        VideoFormat::RGBA => Some(PixelFormat::Rgba),
        _ => None,
    }
}

fn pod(value: Value) -> Vec<u8> {
    spa::pod::serialize::PodSerializer::serialize(std::io::Cursor::new(Vec::new()), &value).expect("pod").0.into_inner()
}

fn enum_format(fps: u32) -> Vec<u8> {
    let obj = spa::pod::object!(
        SpaTypes::ObjectParamFormat,
        spa::param::ParamType::EnumFormat,
        spa::pod::property!(spa::param::format::FormatProperties::MediaType, Id, spa::param::format::MediaType::Video),
        spa::pod::property!(spa::param::format::FormatProperties::MediaSubtype, Id, spa::param::format::MediaSubtype::Raw),
        spa::pod::property!(
            spa::param::format::FormatProperties::VideoFormat,
            Choice,
            Enum,
            Id,
            VideoFormat::BGRx,
            VideoFormat::BGRx,
            VideoFormat::BGRA,
            VideoFormat::RGBx,
            VideoFormat::RGBA
        ),
        spa::pod::property!(
            spa::param::format::FormatProperties::VideoSize,
            Choice,
            Range,
            Rectangle,
            Rectangle { width: 1920, height: 1080 },
            Rectangle { width: 1, height: 1 },
            Rectangle { width: 16384, height: 16384 }
        ),
        spa::pod::property!(
            spa::param::format::FormatProperties::VideoFramerate,
            Choice,
            Range,
            Fraction,
            Fraction { num: fps, denom: 1 },
            Fraction { num: 0, denom: 1 },
            Fraction { num: 1000, denom: 1 }
        ),
    );
    pod(Value::Object(obj))
}

/// Buffers in memory we can map (MemPtr or MemFd), not DMA-BUF.
fn buffers_param() -> Vec<u8> {
    let mem = (1 << spa::sys::SPA_DATA_MemPtr) | (1 << spa::sys::SPA_DATA_MemFd);
    pod(Value::Object(spa::pod::Object {
        type_: spa::sys::SPA_TYPE_OBJECT_ParamBuffers,
        id: spa::sys::SPA_PARAM_Buffers,
        properties: vec![Property { key: spa::sys::SPA_PARAM_BUFFERS_dataType, flags: PropertyFlags::empty(), value: Value::Int(mem) }],
    }))
}

/// Cursor metadata, with room for a 64x64 bitmap (we only read the position).
fn cursor_meta_param() -> Vec<u8> {
    let size = std::mem::size_of::<spa::sys::spa_meta_cursor>() + std::mem::size_of::<spa::sys::spa_meta_bitmap>() + 64 * 64 * 4;
    pod(Value::Object(spa::pod::Object {
        type_: spa::sys::SPA_TYPE_OBJECT_ParamMeta,
        id: spa::sys::SPA_PARAM_Meta,
        properties: vec![
            Property { key: spa::sys::SPA_PARAM_META_type, flags: PropertyFlags::empty(), value: Value::Id(spa::utils::Id(spa::sys::SPA_META_Cursor)) },
            Property { key: spa::sys::SPA_PARAM_META_size, flags: PropertyFlags::empty(), value: Value::Int(size as i32) },
        ],
    }))
}

impl PwStream {
    /// Connects to `node` over the portal's `fd` and waits for the format.
    pub fn open(fd: OwnedFd, node: u32, fps: u32) -> Result<(PwStream, Negotiated), CaptureError> {
        let slot = Arc::new(Mutex::new(None));
        let cursor = Arc::new(Mutex::new(None));
        let (neg_tx, neg_rx) = mpsc::channel();
        let (stop_tx, stop_rx) = pw::channel::channel::<()>();
        let (s2, c2) = (slot.clone(), cursor.clone());
        let thread = std::thread::Builder::new()
            .name("monetshot-pipewire".into())
            .spawn(move || {
                let tx = neg_tx.clone();
                if let Err(e) = run(fd, node, fps, s2, c2, neg_tx, stop_rx) {
                    let _ = tx.send(Err(e.to_string()));
                }
            })
            .map_err(|e| CaptureError::Other(e.to_string()))?;
        let stream = PwStream { stop: stop_tx, thread: Some(thread), slot, cursor };
        match neg_rx.recv_timeout(Duration::from_secs(10)) {
            Ok(Ok(n)) => Ok((stream, n)),
            Ok(Err(e)) => Err(CaptureError::Other(format!("PipeWire: {e}"))),
            Err(_) => Err(CaptureError::Other("PipeWire: the screen stream never started".into())),
        }
    }

    pub fn stop(mut self) {
        self.halt();
    }

    fn halt(&mut self) {
        let _ = self.stop.send(());
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

impl Drop for PwStream {
    fn drop(&mut self) {
        self.halt();
    }
}

fn run(
    fd: OwnedFd,
    node: u32,
    fps: u32,
    slot: Arc<Mutex<Option<FrameSlot>>>,
    cursor: Arc<Mutex<Option<CursorSink>>>,
    negotiated: mpsc::Sender<Result<Negotiated, String>>,
    stop: pw::channel::Receiver<()>,
) -> Result<(), pw::Error> {
    pw::init();
    let mainloop = pw::main_loop::MainLoopRc::new(None)?;
    let context = pw::context::ContextRc::new(&mainloop, None)?;
    let core = context.connect_fd_rc(fd, None)?;
    let stream = pw::stream::StreamRc::new(
        core,
        "monet-shot",
        properties! {
            *pw::keys::MEDIA_TYPE => "Video",
            *pw::keys::MEDIA_CATEGORY => "Capture",
            *pw::keys::MEDIA_ROLE => "Screen",
        },
    )?;
    let ml = mainloop.clone();
    let _stop = stop.attach(mainloop.loop_(), move |_| ml.quit());

    let data = Data { info: VideoInfoRaw::default(), size: (0, 0), format: None, negotiated: Some(negotiated), slot, cursor };
    let _listener = stream
        .add_local_listener_with_user_data(data)
        .state_changed(|_, d, _, new| {
            if let pw::stream::StreamState::Error(e) = new {
                log::error!("PipeWire stream: {e}");
                if let Some(tx) = d.negotiated.take() {
                    let _ = tx.send(Err(e));
                }
            }
        })
        .param_changed(|stream, d, id, param| {
            let Some(param) = param else { return };
            if id != spa::param::ParamType::Format.as_raw() {
                return;
            }
            let Ok((mt, ms)) = spa::param::format_utils::parse_format(param) else { return };
            if mt != spa::param::format::MediaType::Video || ms != spa::param::format::MediaSubtype::Raw {
                return;
            }
            if d.info.parse(param).is_err() {
                return;
            }
            let size = d.info.size();
            d.size = (size.width, size.height);
            d.format = pixel_format(d.info.format());
            log::info!("PipeWire format {:?} {}x{}", d.info.format(), size.width, size.height);
            let (b, m) = (buffers_param(), cursor_meta_param());
            let mut params = [Pod::from_bytes(&b).unwrap(), Pod::from_bytes(&m).unwrap()];
            if let Err(e) = stream.update_params(&mut params) {
                log::error!("PipeWire params: {e}");
            }
            if let Some(tx) = d.negotiated.take() {
                let _ = tx.send(match d.format {
                    Some(format) => Ok(Negotiated { width: size.width, height: size.height, format }),
                    None => Err(format!("unsupported pixel format {:?}", d.info.format())),
                });
            }
        })
        .process(|stream, d| {
            let Some(mut buffer) = stream.dequeue_buffer() else { return };
            if let Some(c) = buffer.find_meta::<spa::buffer::meta::MetaCursor>() {
                if c.is_valid() {
                    if let Some(sink) = d.cursor.lock().unwrap().as_ref() {
                        let p = c.position();
                        sink(p.x as f64, p.y as f64);
                    }
                }
            }
            let Some(slot) = d.slot.lock().unwrap().clone() else { return };
            let (w, h) = d.size;
            let datas = buffer.datas_mut();
            let Some(data) = datas.first_mut() else { return };
            let chunk = data.chunk();
            let (offset, size, stride) = (chunk.offset() as usize, chunk.size() as usize, chunk.stride());
            // Cursor-only updates carry no picture.
            if size == 0 || w == 0 || h == 0 {
                return;
            }
            let stride = if stride > 0 { stride as usize } else { w as usize * 4 };
            let Some(bytes) = data.data() else { return };
            let need = stride * h as usize;
            if bytes.len() < offset + need {
                return;
            }
            slot.put(Frame { width: w, height: h, stride, data: bytes[offset..offset + need].to_vec() });
        })
        .register()?;

    let ef = enum_format(fps);
    let mut params = [Pod::from_bytes(&ef).unwrap()];
    stream.connect(
        spa::utils::Direction::Input,
        Some(node),
        pw::stream::StreamFlags::AUTOCONNECT | pw::stream::StreamFlags::MAP_BUFFERS,
        &mut params,
    )?;
    mainloop.run();
    let _ = stream.disconnect();
    Ok(())
}
