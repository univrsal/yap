/*
Capturing on Windows, with Windows.Graphics.Capture (Windows 10 1903 and
later) for monitors and windows alike, the way OBS's libobs-winrt does
it: a frame pool on our own D3D11 device, free threaded, which signals
an event as frames arrive. The newest frame is copied into a texture of
ours (`latest_`), with mipmaps for scaling down without aliasing, and
kept for converting again later.

Conversion to NV12 is two passes of a small shader: Y at full size into
an R8 view of the target, U and V at half size into an R8G8 view, BT.709
limited range. The target is a frame from the encoder's own D3D11 pool,
so the picture stays on the GPU from capture to encoder; an encoder that
only takes frames in memory gets them through a staging texture.

The device is made on the GPU of the encoder's vendor where there's a
choice (NVENC needs an NVIDIA device to take D3D11 frames).

The yellow border Windows draws round what's captured can only be
turned off on Windows 11; on 10 it stays. Desktop duplication, which
has none, is left for later.
*/
#include "pipeline.h"

#include <atomic>
#include <map>

#include <d3d11_4.h>
#include <d3dcompiler.h>
#include <dxgi1_2.h>
#include <wrl/client.h>

#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <winrt/Windows.Foundation.Metadata.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>

#include "ffmpeg.h"

// Only types, so after ffmpeg.h.
extern "C" {
#include <libavutil/hwcontext_d3d11va.h>
}

using Microsoft::WRL::ComPtr;
namespace wgc = winrt::Windows::Graphics::Capture;
namespace wdx = winrt::Windows::Graphics::DirectX;

namespace yv {

namespace {

const char SHADERS[] = R"(
Texture2D<float4> picture : register(t0);
SamplerState trilinear : register(s0);

struct Varying {
	float4 pos : SV_Position;
	float2 uv : TEXCOORD0;
};

Varying vs(uint id : SV_VertexID) {
	float2 p = float2((id << 1) & 2, id & 2);
	Varying v;
	v.pos = float4(p.x * 2 - 1, 1 - p.y * 2, 0, 1);
	v.uv = p;
	return v;
}

// BT.709, limited range.
float luma(float3 c) {
	return dot(c, float3(0.2126, 0.7152, 0.0722));
}

float ps_y(Varying v) : SV_Target {
	return 16.0 / 255 + 219.0 / 255 * luma(picture.Sample(trilinear, v.uv).rgb);
}

// At half size, so each sample is the average of a 2x2 block (the
// mipmaps take care of the rest).
float2 ps_uv(Varying v) : SV_Target {
	float3 c = picture.Sample(trilinear, v.uv).rgb;
	float y = luma(c);
	return 128.0 / 255 + 224.0 / 255 * float2((c.b - y) / 1.8556, (c.r - y) / 1.5748);
}
)";

UINT vendor_of(const char *encoder) {
	if (strstr(encoder, "_nvenc")) {
		return 0x10de;
	}
	if (strstr(encoder, "_amf")) {
		return 0x1002;
	}
	if (strstr(encoder, "_qsv")) {
		return 0x8086;
	}
	return 0;
}

std::string hr_text(const char *what, HRESULT hr) {
	char buf[160];
	snprintf(buf, sizeof(buf), "%s (0x%08lx)", what, static_cast<unsigned long>(hr));
	return buf;
}

class Pipeline_Win final : public Pipeline {
public:
	~Pipeline_Win() override {
		try {
			frame_arrived_.revoke();
			closed_token_.revoke();
			if (session_) {
				session_.Close();
			}
			if (pool_) {
				pool_.Close();
			}
		} catch (...) {
		}
		session_ = nullptr;
		pool_ = nullptr;
		item_ = nullptr;
		av_buffer_unref(&hw_device_);
		if (event_) {
			CloseHandle(event_);
		}
	}

	bool open(const yv_share_config &config, const char *encoder, const std::atomic<bool> &,
	          std::string &error) override {
		/*
		Each share has a thread of its own, in the MTA. C++/WinRT keeps
		the factories it got for good, and they stop working once the MTA
		goes away, which it does when its last thread ends: so the next
		share would crash in them, unless something else (the client's
		audio) happened to be in the MTA. Holding the MTA for the process
		keeps it there, with every thread that hasn't said otherwise in it.
		*/
		static const bool mta = [] {
			CO_MTA_USAGE_COOKIE cookie;
			return SUCCEEDED(CoIncrementMTAUsage(&cookie));
		}();
		if (!mta) {
			error = "can't start COM for capturing";
			return false;
		}
		if (!make_device(vendor_of(encoder), error) || !make_pipeline(error)) {
			return false;
		}
		try {
			return start_capture(config, error);
		} catch (const winrt::hresult_error &e) {
			error = "can't capture: " + winrt::to_string(e.message());
			return false;
		}
	}

	bool wait(int ms, bool &closed) override {
		WaitForSingleObject(event_, static_cast<DWORD>(ms));
		closed = closed_.load();
		if (closed) {
			return false;
		}
		try {
			return take_frames();
		} catch (const winrt::hresult_error &e) {
			log(YV_LOG_WARN, "share: capture: %s", winrt::to_string(e.message()).c_str());
			return false;
		}
	}

	int width() override {
		return latest_w_;
	}

	int height() override {
		return latest_h_;
	}

	AVBufferRef *hw_device() override {
		return hw_device_ ? av_buffer_ref(hw_device_) : nullptr;
	}

	AVBufferRef *hw_frames(int w, int h) override {
		if (!hw_device_) {
			return nullptr;
		}
		AVBufferRef *ref = av_hwframe_ctx_alloc(hw_device_);
		if (!ref) {
			return nullptr;
		}
		auto *fc = reinterpret_cast<AVHWFramesContext *>(ref->data);
		fc->format = AV_PIX_FMT_D3D11;
		fc->sw_format = AV_PIX_FMT_NV12;
		fc->width = w;
		fc->height = h;
		fc->initial_pool_size = 0; // one texture per frame, not an array
		auto *hc = static_cast<AVD3D11VAFramesContext *>(fc->hwctx);
		hc->BindFlags = D3D11_BIND_RENDER_TARGET;
		if (av_hwframe_ctx_init(ref) < 0) {
			log(YV_LOG_WARN, "share: no NV12 render targets here; frames go through memory");
			av_buffer_unref(&ref);
			return nullptr;
		}
		targets_.clear();
		return ref;
	}

	bool convert(AVFrame *out, AVBufferRef *frames, int w, int h) override {
		if (!latest_) {
			return false;
		}
		ctx_->GenerateMips(latest_view_.Get());
		if (frames) {
			if (av_hwframe_get_buffer(frames, out, 0) < 0) {
				return false;
			}
			auto *tex = reinterpret_cast<ID3D11Texture2D *>(out->data[0]);
			UINT index = static_cast<UINT>(reinterpret_cast<intptr_t>(out->data[1]));
			Targets *t = targets_for(tex, index);
			if (!t) {
				return false;
			}
			draw(t->y.Get(), t->uv.Get(), w, h);
			return true;
		}
		return convert_to_memory(out, w, h);
	}

private:
	ComPtr<ID3D11Device> device_;
	ComPtr<ID3D11DeviceContext> ctx_;
	AVBufferRef *hw_device_ = nullptr;
	ComPtr<ID3D11VertexShader> vs_;
	ComPtr<ID3D11PixelShader> ps_y_, ps_uv_;
	ComPtr<ID3D11SamplerState> sampler_;

	wgc::GraphicsCaptureItem item_{nullptr};
	wgc::Direct3D11CaptureFramePool pool_{nullptr};
	wgc::GraphicsCaptureSession session_{nullptr};
	wdx::Direct3D11::IDirect3DDevice winrt_device_{nullptr};
	wgc::Direct3D11CaptureFramePool::FrameArrived_revoker frame_arrived_;
	wgc::GraphicsCaptureItem::Closed_revoker closed_token_;
	winrt::Windows::Graphics::SizeInt32 pool_size_{};
	HANDLE event_ = nullptr;
	std::atomic<bool> closed_{false};

	ComPtr<ID3D11Texture2D> latest_;
	ComPtr<ID3D11ShaderResourceView> latest_view_;
	int latest_w_ = 0, latest_h_ = 0;

	// The two plane views of each of the encoder pool's textures.
	struct Targets {
		ComPtr<ID3D11RenderTargetView> y, uv;
	};
	std::map<std::pair<ID3D11Texture2D *, UINT>, Targets> targets_;

	// For encoders that take frames in memory.
	ComPtr<ID3D11Texture2D> nv12_, staging_;
	Targets nv12_targets_;
	int nv12_w_ = 0, nv12_h_ = 0;

	bool make_device(UINT vendor, std::string &error) {
		ComPtr<IDXGIAdapter1> adapter;
		ComPtr<IDXGIFactory1> factory;
		if (vendor && SUCCEEDED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) {
			ComPtr<IDXGIAdapter1> a;
			for (UINT i = 0; factory->EnumAdapters1(i, &a) != DXGI_ERROR_NOT_FOUND; i++) {
				DXGI_ADAPTER_DESC1 d;
				if (SUCCEEDED(a->GetDesc1(&d)) && d.VendorId == vendor) {
					adapter = a;
					break;
				}
			}
		}
		const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0};
		HRESULT hr = D3D11CreateDevice(
			adapter.Get(), adapter ? D3D_DRIVER_TYPE_UNKNOWN : D3D_DRIVER_TYPE_HARDWARE, nullptr,
			D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT, levels,
			ARRAYSIZE(levels), D3D11_SDK_VERSION, &device_, nullptr, &ctx_);
		if (FAILED(hr)) {
			error = hr_text("no Direct3D 11 device to capture with", hr);
			return false;
		}
		// The capture's threads, FFmpeg's encoder and ours all use it.
		ComPtr<ID3D11Multithread> mt;
		if (SUCCEEDED(ctx_.As(&mt))) {
			mt->SetMultithreadProtected(TRUE);
		}
		AVBufferRef *ref = av_hwdevice_ctx_alloc(AV_HWDEVICE_TYPE_D3D11VA);
		if (ref) {
			auto *hw = static_cast<AVD3D11VADeviceContext *>(
				reinterpret_cast<AVHWDeviceContext *>(ref->data)->hwctx);
			hw->device = device_.Get();
			hw->device->AddRef();
			if (av_hwdevice_ctx_init(ref) < 0) {
				av_buffer_unref(&ref);
			}
			hw_device_ = ref;
		}
		ComPtr<IDXGIDevice> dxgi;
		ComPtr<IDXGIAdapter> used;
		DXGI_ADAPTER_DESC desc{};
		if (SUCCEEDED(device_.As(&dxgi)) && SUCCEEDED(dxgi->GetAdapter(&used))) {
			used->GetDesc(&desc);
		}
		char name[128];
		WideCharToMultiByte(CP_UTF8, 0, desc.Description, -1, name, sizeof(name), nullptr, nullptr);
		log(YV_LOG_INFO, "share: capturing on %s", name);
		return true;
	}

	bool compile(const char *entry, const char *target, ComPtr<ID3DBlob> &out, std::string &error) {
		ComPtr<ID3DBlob> errors;
		HRESULT hr = D3DCompile(SHADERS, sizeof(SHADERS) - 1, "yap_video capture", nullptr, nullptr,
		                        entry, target, D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &out, &errors);
		if (FAILED(hr)) {
			error = std::string("shader ") + entry + ": " +
			        (errors ? static_cast<const char *>(errors->GetBufferPointer()) : "?");
			return false;
		}
		return true;
	}

	bool make_pipeline(std::string &error) {
		ComPtr<ID3DBlob> vs, ps_y, ps_uv;
		if (!compile("vs", "vs_4_0", vs, error) || !compile("ps_y", "ps_4_0", ps_y, error) ||
		    !compile("ps_uv", "ps_4_0", ps_uv, error)) {
			return false;
		}
		D3D11_SAMPLER_DESC sd{};
		sd.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
		sd.AddressU = sd.AddressV = sd.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
		sd.MaxLOD = D3D11_FLOAT32_MAX;
		if (FAILED(device_->CreateVertexShader(vs->GetBufferPointer(), vs->GetBufferSize(),
		                                       nullptr, &vs_)) ||
		    FAILED(device_->CreatePixelShader(ps_y->GetBufferPointer(), ps_y->GetBufferSize(),
		                                      nullptr, &ps_y_)) ||
		    FAILED(device_->CreatePixelShader(ps_uv->GetBufferPointer(), ps_uv->GetBufferSize(),
		                                      nullptr, &ps_uv_)) ||
		    FAILED(device_->CreateSamplerState(&sd, &sampler_))) {
			error = "can't set up the colour conversion";
			return false;
		}
		return true;
	}

	bool start_capture(const yv_share_config &config, std::string &error) {
		if (!wgc::GraphicsCaptureSession::IsSupported()) {
			error = "this Windows can't capture the screen (Windows 10 1903 or later is needed)";
			return false;
		}
		auto interop = winrt::get_activation_factory<wgc::GraphicsCaptureItem,
		                                             IGraphicsCaptureItemInterop>();
		HRESULT hr;
		if (config.kind == YV_SOURCE_MONITOR) {
			hr = interop->CreateForMonitor(reinterpret_cast<HMONITOR>(config.source),
			                               winrt::guid_of<wgc::GraphicsCaptureItem>(),
			                               winrt::put_abi(item_));
		} else {
			hr = interop->CreateForWindow(reinterpret_cast<HWND>(config.source),
			                              winrt::guid_of<wgc::GraphicsCaptureItem>(),
			                              winrt::put_abi(item_));
		}
		if (FAILED(hr) || !item_) {
			error = hr_text(config.kind == YV_SOURCE_MONITOR ? "can't capture that monitor"
			                                                 : "can't capture that window",
			                hr);
			return false;
		}

		ComPtr<IDXGIDevice> dxgi;
		device_.As(&dxgi);
		winrt::com_ptr<::IInspectable> inspectable;
		hr = CreateDirect3D11DeviceFromDXGIDevice(dxgi.Get(), inspectable.put());
		if (FAILED(hr)) {
			error = hr_text("can't hand the device to the capture", hr);
			return false;
		}
		winrt_device_ = inspectable.as<wdx::Direct3D11::IDirect3DDevice>();

		event_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
		pool_size_ = item_.Size();
		pool_ = wgc::Direct3D11CaptureFramePool::CreateFreeThreaded(
			winrt_device_, wdx::DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, pool_size_);
		session_ = pool_.CreateCaptureSession(item_);
		using winrt::Windows::Foundation::Metadata::ApiInformation;
		const wchar_t *session_class = L"Windows.Graphics.Capture.GraphicsCaptureSession";
		if (ApiInformation::IsPropertyPresent(session_class, L"IsCursorCaptureEnabled")) {
			session_.IsCursorCaptureEnabled(config.cursor);
		}
		if (ApiInformation::IsPropertyPresent(session_class, L"IsBorderRequired")) {
			try {
				session_.IsBorderRequired(false);
			} catch (const winrt::hresult_error &) {
				// Not allowed for this app; the border stays.
			}
		}
		HANDLE ev = event_;
		frame_arrived_ = pool_.FrameArrived(winrt::auto_revoke, [ev](auto &&, auto &&) {
			SetEvent(ev);
		});
		closed_token_ = item_.Closed(winrt::auto_revoke, [this, ev](auto &&, auto &&) {
			closed_.store(true);
			SetEvent(ev);
		});
		session_.StartCapture();
		log(YV_LOG_INFO, "share: capturing %s, %dx%d", winrt::to_string(item_.DisplayName()).c_str(),
		    pool_size_.Width, pool_size_.Height);
		return true;
	}

	// take_frames takes whatever the pool has, keeps the newest, and
	// says whether there was any.
	bool take_frames() {
		wgc::Direct3D11CaptureFrame newest{nullptr};
		for (;;) {
			wgc::Direct3D11CaptureFrame f = pool_.TryGetNextFrame();
			if (!f) {
				break;
			}
			if (newest) {
				newest.Close();
			}
			newest = f;
		}
		if (!newest) {
			return false;
		}
		auto size = newest.ContentSize();
		auto access = newest.Surface()
		                  .as<::Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
		ComPtr<ID3D11Texture2D> tex;
		bool ok = SUCCEEDED(access->GetInterface(IID_PPV_ARGS(&tex)));
		if (ok) {
			D3D11_TEXTURE2D_DESC d;
			tex->GetDesc(&d);
			// The content size, but never more than the texture.
			int w = std::min(static_cast<int>(d.Width), static_cast<int>(size.Width));
			int h = std::min(static_cast<int>(d.Height), static_cast<int>(size.Height));
			ok = w > 0 && h > 0 && copy_latest(tex.Get(), w, h);
		}
		newest.Close();
		if (size.Width != pool_size_.Width || size.Height != pool_size_.Height) {
			// A window changed size: frames of the new size from now on.
			pool_size_ = size;
			pool_.Recreate(winrt_device_, wdx::DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, size);
		}
		return ok;
	}

	bool copy_latest(ID3D11Texture2D *src, int w, int h) {
		if (!latest_ || latest_w_ != w || latest_h_ != h) {
			latest_.Reset();
			latest_view_.Reset();
			D3D11_TEXTURE2D_DESC d{};
			d.Width = w;
			d.Height = h;
			d.MipLevels = 0; // the whole chain
			d.ArraySize = 1;
			d.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
			d.SampleDesc.Count = 1;
			d.Usage = D3D11_USAGE_DEFAULT;
			d.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET;
			d.MiscFlags = D3D11_RESOURCE_MISC_GENERATE_MIPS;
			if (FAILED(device_->CreateTexture2D(&d, nullptr, &latest_)) ||
			    FAILED(device_->CreateShaderResourceView(latest_.Get(), nullptr, &latest_view_))) {
				latest_.Reset();
				latest_view_.Reset();
				latest_w_ = latest_h_ = 0;
				return false;
			}
			latest_w_ = w;
			latest_h_ = h;
		}
		D3D11_BOX box{0, 0, 0, static_cast<UINT>(w), static_cast<UINT>(h), 1};
		ctx_->CopySubresourceRegion(latest_.Get(), 0, 0, 0, 0, src, 0, &box);
		return true;
	}

	bool plane_views(ID3D11Texture2D *tex, UINT index, Targets &t) {
		D3D11_TEXTURE2D_DESC d;
		tex->GetDesc(&d);
		D3D11_RENDER_TARGET_VIEW_DESC vd{};
		if (d.ArraySize > 1) {
			vd.ViewDimension = D3D11_RTV_DIMENSION_TEXTURE2DARRAY;
			vd.Texture2DArray.FirstArraySlice = index;
			vd.Texture2DArray.ArraySize = 1;
		} else {
			vd.ViewDimension = D3D11_RTV_DIMENSION_TEXTURE2D;
		}
		vd.Format = DXGI_FORMAT_R8_UNORM;
		if (FAILED(device_->CreateRenderTargetView(tex, &vd, &t.y))) {
			return false;
		}
		vd.Format = DXGI_FORMAT_R8G8_UNORM;
		return SUCCEEDED(device_->CreateRenderTargetView(tex, &vd, &t.uv));
	}

	Targets *targets_for(ID3D11Texture2D *tex, UINT index) {
		auto key = std::make_pair(tex, index);
		auto it = targets_.find(key);
		if (it != targets_.end()) {
			return &it->second;
		}
		Targets t;
		if (!plane_views(tex, index, t)) {
			log(YV_LOG_ERROR, "share: can't draw into the encoder's frames");
			return nullptr;
		}
		return &targets_.emplace(key, t).first->second;
	}

	void pass(ID3D11RenderTargetView *target, ID3D11PixelShader *ps, int w, int h) {
		D3D11_VIEWPORT vp{0, 0, static_cast<float>(w), static_cast<float>(h), 0, 1};
		ctx_->OMSetRenderTargets(1, &target, nullptr);
		ctx_->RSSetViewports(1, &vp);
		ctx_->PSSetShader(ps, nullptr, 0);
		ctx_->Draw(3, 0);
	}

	void draw(ID3D11RenderTargetView *y, ID3D11RenderTargetView *uv, int w, int h) {
		ctx_->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
		ctx_->IASetInputLayout(nullptr);
		ctx_->VSSetShader(vs_.Get(), nullptr, 0);
		ID3D11ShaderResourceView *src = latest_view_.Get();
		ctx_->PSSetShaderResources(0, 1, &src);
		ctx_->PSSetSamplers(0, 1, sampler_.GetAddressOf());
		pass(y, ps_y_.Get(), w, h);
		pass(uv, ps_uv_.Get(), w / 2, h / 2);
		ID3D11ShaderResourceView *none = nullptr;
		ctx_->PSSetShaderResources(0, 1, &none);
		ctx_->OMSetRenderTargets(0, nullptr, nullptr);
	}

	// For encoders that only take frames in memory: draw into an NV12
	// texture of our own and read it back.
	bool convert_to_memory(AVFrame *out, int w, int h) {
		if (!nv12_ || nv12_w_ != w || nv12_h_ != h) {
			nv12_.Reset();
			staging_.Reset();
			nv12_targets_ = {};
			D3D11_TEXTURE2D_DESC d{};
			d.Width = w;
			d.Height = h;
			d.MipLevels = 1;
			d.ArraySize = 1;
			d.Format = DXGI_FORMAT_NV12;
			d.SampleDesc.Count = 1;
			d.Usage = D3D11_USAGE_DEFAULT;
			d.BindFlags = D3D11_BIND_RENDER_TARGET;
			if (FAILED(device_->CreateTexture2D(&d, nullptr, &nv12_)) ||
			    !plane_views(nv12_.Get(), 0, nv12_targets_)) {
				nv12_.Reset();
				return false;
			}
			d.Usage = D3D11_USAGE_STAGING;
			d.BindFlags = 0;
			d.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
			if (FAILED(device_->CreateTexture2D(&d, nullptr, &staging_))) {
				nv12_.Reset();
				return false;
			}
			nv12_w_ = w;
			nv12_h_ = h;
		}
		draw(nv12_targets_.y.Get(), nv12_targets_.uv.Get(), w, h);
		ctx_->CopyResource(staging_.Get(), nv12_.Get());
		D3D11_MAPPED_SUBRESOURCE m;
		if (FAILED(ctx_->Map(staging_.Get(), 0, D3D11_MAP_READ, 0, &m))) {
			return false;
		}
		out->format = AV_PIX_FMT_NV12;
		out->width = w;
		out->height = h;
		bool ok = av_frame_get_buffer(out, 0) >= 0;
		if (ok) {
			const auto *src = static_cast<const uint8_t *>(m.pData);
			for (int y = 0; y < h; y++) {
				memcpy(out->data[0] + y * out->linesize[0], src + y * m.RowPitch, w);
			}
			// The UV plane follows the Y plane, at the same pitch.
			const uint8_t *uv = src + static_cast<size_t>(m.RowPitch) * h;
			for (int y = 0; y < h / 2; y++) {
				memcpy(out->data[1] + y * out->linesize[1], uv + y * m.RowPitch, w);
			}
		}
		ctx_->Unmap(staging_.Get(), 0);
		return ok;
	}
};

} // namespace

std::unique_ptr<Pipeline> make_pipeline() {
	return std::make_unique<Pipeline_Win>();
}

} // namespace yv
