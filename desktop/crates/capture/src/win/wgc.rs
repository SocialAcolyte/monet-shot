//! Windows.Graphics.Capture: a free-threaded frame pool on a D3D11 device;
//! each frame is copied to a CPU-readable staging texture and handed to the
//! encoder clock. The system cursor is left out (we draw our own) and the
//! yellow capture border is turned off where Windows allows it (Windows 11).

use std::sync::Mutex;

use ::windows::core::{Interface, Ref};
use ::windows::Foundation::TypedEventHandler;
use ::windows::Graphics::Capture::{Direct3D11CaptureFramePool, GraphicsCaptureItem, GraphicsCaptureSession};
use ::windows::Graphics::DirectX::Direct3D11::IDirect3DDevice;
use ::windows::Graphics::DirectX::DirectXPixelFormat;
use ::windows::Graphics::SizeInt32;
use ::windows::Win32::Foundation::HMODULE;
use ::windows::Win32::Graphics::Direct3D::D3D_DRIVER_TYPE_HARDWARE;
use ::windows::Win32::Graphics::Direct3D11::{
    D3D11CreateDevice, ID3D11Device, ID3D11DeviceContext, ID3D11Texture2D, D3D11_CPU_ACCESS_READ,
    D3D11_CREATE_DEVICE_BGRA_SUPPORT, D3D11_MAPPED_SUBRESOURCE, D3D11_MAP_READ, D3D11_SDK_VERSION, D3D11_TEXTURE2D_DESC,
    D3D11_USAGE_STAGING,
};
use ::windows::Win32::Graphics::Dxgi::IDXGIDevice;
use ::windows::Win32::System::WinRT::Direct3D11::{CreateDirect3D11DeviceFromDXGIDevice, IDirect3DDxgiInterfaceAccess};
use ::windows::Win32::System::WinRT::Graphics::Capture::IGraphicsCaptureItemInterop;

use super::Target;
use crate::pipe::{Frame, FrameSlot};
use crate::CaptureError;

const FORMAT: DirectXPixelFormat = DirectXPixelFormat::B8G8R8A8UIntNormalized;

pub(crate) fn supported() -> bool {
    GraphicsCaptureSession::IsSupported().unwrap_or(false)
}

fn err(what: &str) -> impl Fn(::windows::core::Error) -> CaptureError + '_ {
    move |e| CaptureError::Other(format!("{what}: {e}"))
}

/// The device and item, before frames flow.
pub(crate) struct Frames {
    device: ID3D11Device,
    context: ID3D11DeviceContext,
    d3d: IDirect3DDevice,
    item: GraphicsCaptureItem,
    size: SizeInt32,
}

/// D3D objects used only on the frame pool's callback thread, one call at a time.
struct Gpu {
    device: ID3D11Device,
    context: ID3D11DeviceContext,
    d3d: IDirect3DDevice,
    staging: Option<(ID3D11Texture2D, u32, u32)>,
    pool_size: SizeInt32,
}
unsafe impl Send for Gpu {}

pub(crate) struct Running {
    session: GraphicsCaptureSession,
    pool: Direct3D11CaptureFramePool,
}

impl Frames {
    pub fn open(target: &Target) -> Result<Frames, CaptureError> {
        if !supported() {
            return Err(CaptureError::Unsupported("screen capture needs Windows 10 version 1903 or later".into()));
        }
        let (device, context) = unsafe {
            let mut device = None;
            let mut context = None;
            D3D11CreateDevice(
                None,
                D3D_DRIVER_TYPE_HARDWARE,
                HMODULE::default(),
                D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                None,
                D3D11_SDK_VERSION,
                Some(&mut device),
                None,
                Some(&mut context),
            )
            .map_err(err("Direct3D"))?;
            (device.expect("device"), context.expect("context"))
        };
        let dxgi: IDXGIDevice = device.cast().map_err(err("DXGI"))?;
        let d3d: IDirect3DDevice = unsafe { CreateDirect3D11DeviceFromDXGIDevice(&dxgi) }.map_err(err("Direct3D"))?.cast().map_err(err("Direct3D"))?;
        let interop = ::windows::core::factory::<GraphicsCaptureItem, IGraphicsCaptureItemInterop>().map_err(err("capture"))?;
        let item: GraphicsCaptureItem = unsafe {
            match (target.hmonitor(), target.hwnd()) {
                (Some(m), _) => interop.CreateForMonitor(m),
                (_, Some(w)) => interop.CreateForWindow(w),
                _ => unreachable!(),
            }
        }
        .map_err(err("could not capture that"))?;
        let size = item.Size().map_err(err("capture"))?;
        Ok(Frames { device, context, d3d, item, size })
    }

    pub fn size(&self) -> (u32, u32) {
        (self.size.Width.max(2) as u32, self.size.Height.max(2) as u32)
    }

    pub fn start(self, slot: FrameSlot) -> Result<Running, CaptureError> {
        let pool = Direct3D11CaptureFramePool::CreateFreeThreaded(&self.d3d, FORMAT, 2, self.size).map_err(err("capture"))?;
        let session = pool.CreateCaptureSession(&self.item).map_err(err("capture"))?;
        let _ = session.SetIsCursorCaptureEnabled(false);
        if session.SetIsBorderRequired(false).is_err() {
            log::info!("capture border can't be turned off on this Windows");
        }
        let gpu = Mutex::new(Gpu { device: self.device, context: self.context, d3d: self.d3d, staging: None, pool_size: self.size });
        pool.FrameArrived(&TypedEventHandler::new(move |pool: Ref<Direct3D11CaptureFramePool>, _| {
            if let Some(pool) = pool.as_ref() {
                if let Err(e) = on_frame(pool, &mut gpu.lock().unwrap(), &slot) {
                    log::error!("capture frame: {e}");
                }
            }
            Ok(())
        }))
        .map_err(err("capture"))?;
        session.StartCapture().map_err(err("could not start capture"))?;
        Ok(Running { session, pool })
    }
}

impl Running {
    pub fn stop(self) {
        let _ = self.session.Close();
        let _ = self.pool.Close();
    }
}

fn on_frame(pool: &Direct3D11CaptureFramePool, gpu: &mut Gpu, slot: &FrameSlot) -> ::windows::core::Result<()> {
    let frame = pool.TryGetNextFrame()?;
    let content = frame.ContentSize()?;
    let access: IDirect3DDxgiInterfaceAccess = frame.Surface()?.cast()?;
    let tex: ID3D11Texture2D = unsafe { access.GetInterface()? };
    let mut desc = D3D11_TEXTURE2D_DESC::default();
    unsafe { tex.GetDesc(&mut desc) };
    let (tw, th) = (desc.Width, desc.Height);
    if gpu.staging.as_ref().map(|s| (s.1, s.2)) != Some((tw, th)) {
        let sd = D3D11_TEXTURE2D_DESC {
            Usage: D3D11_USAGE_STAGING,
            BindFlags: 0,
            CPUAccessFlags: D3D11_CPU_ACCESS_READ.0 as u32,
            MiscFlags: 0,
            ..desc
        };
        let mut staging = None;
        unsafe { gpu.device.CreateTexture2D(&sd, None, Some(&mut staging))? };
        gpu.staging = Some((staging.expect("staging"), tw, th));
    }
    let staging = &gpu.staging.as_ref().unwrap().0;
    let (w, h) = ((content.Width.max(1) as u32).min(tw), (content.Height.max(1) as u32).min(th));
    unsafe {
        gpu.context.CopyResource(staging, &tex);
        let mut m = D3D11_MAPPED_SUBRESOURCE::default();
        gpu.context.Map(staging, 0, D3D11_MAP_READ, 0, Some(&mut m))?;
        let stride = m.RowPitch as usize;
        let data = std::slice::from_raw_parts(m.pData as *const u8, stride * h as usize).to_vec();
        gpu.context.Unmap(staging, 0);
        slot.put(Frame { width: w, height: h, stride, data });
    }
    drop(frame);
    // A window that changed size: the pool follows, the file keeps its size
    // (the encoder pads or crops).
    if content.Width != gpu.pool_size.Width || content.Height != gpu.pool_size.Height {
        gpu.pool_size = content;
        pool.Recreate(&gpu.d3d, FORMAT, 2, content)?;
    }
    Ok(())
}
