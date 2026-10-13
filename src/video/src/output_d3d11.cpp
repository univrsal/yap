/*
Watching on Windows. Decoding happens on a D3D11 device of our own, on
the same adapter as the client's, so neither ever waits for the other's
immediate context and a SINGLETHREADED client device is fine. Each
decoded frame is converted to RGBA there, by a small shader, into one of
three shared textures; present copies the newest of them into a texture
on the client's device, which is what the client draws.

	decoder thread                          client's drawing thread
	NV12 (D3D11VA, or uploaded from memory)
	  -> shader -> slot (shared, keyed mutex) -> CopyResource -> display

The keyed mutexes (always key 0, so a plain mutex between the two
devices) make each device's GPU work on a slot wait for the other's.
Which slot is which is kept on the CPU: at most one is being read and
one is the newest, so there's always a third to write. (OBS shares its
textures between devices the same way, GS_SHARED_KM_TEX in
libobs-d3d11.)
*/
#include "output.h"

#include <atomic>

#include <d3d11_4.h>
#include <d3dcompiler.h>
#include <dxgi1_2.h>
#include <wrl/client.h>

extern "C" {
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_d3d11va.h>
}

using Microsoft::WRL::ComPtr;

namespace yv {

namespace {

const char SHADERS[] = R"(
cbuffer Constants : register(b0) {
	float4 row0;
	float4 row1;
	float4 row2;
	float2 uv_scale; // the picture's part of the (padded) planes
};
Texture2D<float> plane_y : register(t0);
Texture2D<float2> plane_uv : register(t1);
SamplerState linear_clamp : register(s0);

struct Varying {
	float4 pos : SV_Position;
	float2 uv : TEXCOORD0;
};

// One triangle that covers the whole target, from the vertex ids alone.
Varying vs(uint id : SV_VertexID) {
	float2 p = float2((id << 1) & 2, id & 2);
	Varying v;
	v.pos = float4(p.x * 2 - 1, 1 - p.y * 2, 0, 1);
	v.uv = p * uv_scale;
	return v;
}

float4 ps(Varying v) : SV_Target {
	float4 yuv = float4(plane_y.Sample(linear_clamp, v.uv), plane_uv.Sample(linear_clamp, v.uv), 1);
	return float4(dot(row0, yuv), dot(row1, yuv), dot(row2, yuv), 1);
}
)";

struct Constants {
	float rows[3][4];
	float uv_scale[2];
	float pad[2];
};

// DXVA's AV1 profile 0 (dxva.h, which the SDK only has in its newer
// versions).
const GUID AV1_PROFILE0 = {
	0xb8be4ccb, 0xcf53, 0x46ba, {0x8d, 0x59, 0xd6, 0xb8, 0xa6, 0xda, 0x5d, 0x2a}};

constexpr int SLOTS = 3;

enum class Slot_State { Free, Writing, Ready, Reading };

// A shared RGBA texture between the two devices.
struct Slot {
	// The decoder's side.
	ComPtr<ID3D11Texture2D> texture;
	ComPtr<ID3D11RenderTargetView> target;
	ComPtr<IDXGIKeyedMutex> mutex;
	HANDLE handle = nullptr;
	int width = 0, height = 0;
	// Under Output_D3D11::mutex_: what the client may read.
	Slot_State state = Slot_State::Free;
	HANDLE published = nullptr; // `handle` as it was when it became Ready
	int published_w = 0, published_h = 0;
	bool hardware = false;
	uint64_t pts_us = 0;
};

// A slot as the client's device sees it.
struct Opened {
	HANDLE handle = nullptr;
	ComPtr<ID3D11Texture2D> texture;
	ComPtr<IDXGIKeyedMutex> mutex;
};

uint64_t luid_value(LUID l) {
	return (static_cast<uint64_t>(static_cast<uint32_t>(l.HighPart)) << 32) | l.LowPart;
}

class Output_D3D11 final : public Output {
public:
	~Output_D3D11() override {
		drop_device();
		av_buffer_unref(&hw_device_);
	}

	AVBufferRef *hw_device() override {
		if (software_only()) {
			return nullptr;
		}
		ensure_device();
		return hw_device_ ? av_buffer_ref(hw_device_) : nullptr;
	}

	bool hw_decodes(yv_codec codec) override {
		ensure_device();
		if (!video_device_) {
			return false;
		}
		if (codec != YV_CODEC_AV1) {
			return true;
		}
		UINT n = video_device_->GetVideoDecoderProfileCount();
		for (UINT i = 0; i < n; i++) {
			GUID g;
			if (SUCCEEDED(video_device_->GetVideoDecoderProfile(i, &g)) && g == AV1_PROFILE0) {
				return true;
			}
		}
		return false;
	}

	bool device_stale() override {
		if (!device_) {
			return false;
		}
		uint64_t want = wanted_luid_.load();
		return (want != 0 && want != luid_) || device_->GetDeviceRemovedReason() != S_OK;
	}

	void renew_device() override {
		drop_device();
		ensure_device();
	}

	bool submit(const AVFrame *frame) override {
		if (!ensure_device()) {
			return false;
		}
		bool hardware = frame->format == AV_PIX_FMT_D3D11;
		float uv_scale[2] = {1, 1};
		if (hardware && !planes_from_hw(frame, uv_scale)) {
			// The decoder's textures can't be read by shaders here, so
			// take the long way, through memory.
			if (!hw_to_memory_) {
				log(YV_LOG_INFO, "video: copying decoded frames through memory");
				hw_to_memory_ = true;
			}
			AVFrame *sw = av_frame_alloc();
			bool ok = av_hwframe_transfer_data(sw, frame, 0) >= 0 &&
			          av_frame_copy_props(sw, frame) >= 0 && planes_from_memory(sw);
			av_frame_free(&sw);
			if (!ok) {
				return false;
			}
		} else if (!hardware && !planes_from_memory(frame)) {
			return false;
		}
		return draw(frame, uv_scale, hardware);
	}

	void clear() override {
		std::lock_guard<std::mutex> lock(mutex_);
		if (newest_ >= 0 && slots_[newest_].state == Slot_State::Ready) {
			slots_[newest_].state = Slot_State::Free;
		}
		newest_ = -1;
		frames_ = 0;
		cleared_ = true;
	}

	void set_gpu(const yv_gpu *gpu, uint64_t luid) override {
		ID3D11Device *dev = gpu && gpu->kind == YV_GPU_D3D11
		                        ? static_cast<ID3D11Device *>(gpu->d3d11_device)
		                        : nullptr;
		if (dev == client_.Get()) {
			return;
		}
		for (Opened &o : opened_) {
			o = {};
		}
		display_.Reset();
		display_view_.Reset();
		client_ctx_.Reset();
		client_ = dev;
		if (dev) {
			dev->GetImmediateContext(&client_ctx_);
		}
		have_picture_ = false;
		wanted_luid_.store(luid);
	}

	bool present(yv_picture *out) override {
		if (!client_) {
			return false;
		}
		int take = -1;
		HANDLE handle = nullptr;
		int w = 0, h = 0;
		{
			std::lock_guard<std::mutex> lock(mutex_);
			if (cleared_) {
				cleared_ = false;
				have_picture_ = false;
			}
			if (newest_ >= 0 && slots_[newest_].state == Slot_State::Ready) {
				take = newest_;
				newest_ = -1;
				Slot &s = slots_[take];
				s.state = Slot_State::Reading;
				handle = s.published;
				w = s.published_w;
				h = s.published_h;
				hardware_ = s.hardware;
				pts_ = s.pts_us;
			}
			out->frames = frames_;
		}
		if (take >= 0) {
			if (copy_to_display(take, handle, w, h)) {
				have_picture_ = true;
			}
			std::lock_guard<std::mutex> lock(mutex_);
			if (slots_[take].state == Slot_State::Reading) {
				slots_[take].state = Slot_State::Free;
			}
		}
		if (!have_picture_) {
			return false;
		}
		out->texture = reinterpret_cast<uintptr_t>(display_view_.Get());
		out->width = display_w_;
		out->height = display_h_;
		out->hardware = hardware_;
		out->pts_us = pts_;
		return true;
	}

private:
	// The decoder thread's.
	ComPtr<ID3D11Device> device_;
	ComPtr<ID3D11DeviceContext> ctx_;
	ComPtr<ID3D11VideoDevice> video_device_;
	AVBufferRef *hw_device_ = nullptr;
	uint64_t luid_ = 0;
	bool device_failed_ = false; // don't keep trying every frame
	ComPtr<ID3D11VertexShader> vs_;
	ComPtr<ID3D11PixelShader> ps_;
	ComPtr<ID3D11SamplerState> sampler_;
	ComPtr<ID3D11Buffer> constants_;
	// The planes the shader reads: views of the decoder's frame copied
	// into `hw_planes_`, or of the two textures frames in memory go to.
	ComPtr<ID3D11Texture2D> hw_planes_;
	ComPtr<ID3D11ShaderResourceView> hw_y_, hw_uv_;
	ComPtr<ID3D11Texture2D> mem_y_tex_, mem_uv_tex_;
	ComPtr<ID3D11ShaderResourceView> mem_y_, mem_uv_;
	ID3D11ShaderResourceView *plane_y_ = nullptr, *plane_uv_ = nullptr;
	bool hw_to_memory_ = false;
	Nv12 nv12_;

	// Shared with the drawing thread, under mutex_.
	std::mutex mutex_;
	Slot slots_[SLOTS];
	int newest_ = -1;
	uint64_t frames_ = 0;
	bool cleared_ = false;
	std::atomic<uint64_t> wanted_luid_{0};

	// The drawing thread's.
	ComPtr<ID3D11Device> client_;
	ComPtr<ID3D11DeviceContext> client_ctx_;
	Opened opened_[SLOTS];
	ComPtr<ID3D11Texture2D> display_;
	ComPtr<ID3D11ShaderResourceView> display_view_;
	int display_w_ = 0, display_h_ = 0;
	bool have_picture_ = false;
	bool hardware_ = false;
	uint64_t pts_ = 0;

	void drop_device() {
		std::lock_guard<std::mutex> lock(mutex_);
		for (Slot &s : slots_) {
			// The client has its own reference to what it opened; a slot
			// it's reading stays Reading until it's done.
			s.texture.Reset();
			s.target.Reset();
			s.mutex.Reset();
			s.handle = nullptr;
			s.width = s.height = 0;
			if (s.state != Slot_State::Reading) {
				s.state = Slot_State::Free;
			}
		}
		newest_ = -1;
		hw_planes_.Reset();
		hw_y_.Reset();
		hw_uv_.Reset();
		mem_y_tex_.Reset();
		mem_uv_tex_.Reset();
		mem_y_.Reset();
		mem_uv_.Reset();
		plane_y_ = plane_uv_ = nullptr;
		vs_.Reset();
		ps_.Reset();
		sampler_.Reset();
		constants_.Reset();
		av_buffer_unref(&hw_device_);
		video_device_.Reset();
		ctx_.Reset();
		device_.Reset();
		device_failed_ = false;
		hw_to_memory_ = false;
	}

	ComPtr<IDXGIAdapter1> find_adapter(uint64_t luid) {
		ComPtr<IDXGIFactory1> factory;
		if (luid == 0 || FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) {
			return nullptr;
		}
		ComPtr<IDXGIAdapter1> adapter;
		for (UINT i = 0; factory->EnumAdapters1(i, &adapter) != DXGI_ERROR_NOT_FOUND; i++) {
			DXGI_ADAPTER_DESC1 desc;
			if (SUCCEEDED(adapter->GetDesc1(&desc)) && luid_value(desc.AdapterLuid) == luid) {
				return adapter;
			}
		}
		return nullptr;
	}

	bool ensure_device() {
		if (device_) {
			return true;
		}
		if (device_failed_) {
			return false;
		}
		uint64_t want = wanted_luid_.load();
		ComPtr<IDXGIAdapter1> adapter = find_adapter(want);
		const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0,
		                                    D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0};
		auto create = [&](UINT flags) {
			return D3D11CreateDevice(adapter.Get(),
			                         adapter ? D3D_DRIVER_TYPE_UNKNOWN : D3D_DRIVER_TYPE_HARDWARE,
			                         nullptr, flags, levels, ARRAYSIZE(levels), D3D11_SDK_VERSION,
			                         &device_, nullptr, &ctx_);
		};
		// Without video support (WARP, say), frames are decoded in
		// software and only converted here.
		HRESULT hr = create(D3D11_CREATE_DEVICE_VIDEO_SUPPORT);
		if (FAILED(hr)) {
			hr = create(0);
		}
		if (FAILED(hr)) {
			log(YV_LOG_ERROR, "video: no Direct3D 11 device (0x%08lx)", hr);
			device_failed_ = true;
			return false;
		}
		ComPtr<IDXGIDevice> dxgi;
		ComPtr<IDXGIAdapter> used;
		DXGI_ADAPTER_DESC desc{};
		if (SUCCEEDED(device_.As(&dxgi)) && SUCCEEDED(dxgi->GetAdapter(&used))) {
			used->GetDesc(&desc);
		}
		luid_ = luid_value(desc.AdapterLuid);
		if (!make_pipeline()) {
			drop_device();
			device_failed_ = true;
			return false;
		}
		if (SUCCEEDED(device_.As(&video_device_))) {
			make_hw_device();
		}
		char name[128];
		WideCharToMultiByte(CP_UTF8, 0, desc.Description, -1, name, sizeof(name), nullptr, nullptr);
		log(YV_LOG_INFO, "video: decoding on %s%s", name,
		    hw_device_ ? "" : " (no hardware decoding)");
		return true;
	}

	void make_hw_device() {
		// FFmpeg uses the immediate context from the decoder thread, as
		// we do; this makes D3D11 check that's all.
		ComPtr<ID3D11Multithread> mt;
		if (SUCCEEDED(ctx_.As(&mt))) {
			mt->SetMultithreadProtected(TRUE);
		}
		AVBufferRef *ref = av_hwdevice_ctx_alloc(AV_HWDEVICE_TYPE_D3D11VA);
		if (!ref) {
			return;
		}
		auto *hw = static_cast<AVD3D11VADeviceContext *>(
			reinterpret_cast<AVHWDeviceContext *>(ref->data)->hwctx);
		hw->device = device_.Get();
		hw->device->AddRef(); // FFmpeg releases it with the context
		if (av_hwdevice_ctx_init(ref) < 0) {
			av_buffer_unref(&ref);
			video_device_.Reset();
			return;
		}
		hw_device_ = ref;
	}

	bool compile(const char *entry, const char *target, ComPtr<ID3DBlob> &out) {
		ComPtr<ID3DBlob> errors;
		HRESULT hr = D3DCompile(SHADERS, sizeof(SHADERS) - 1, "yap_video", nullptr, nullptr, entry,
		                        target, D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &out, &errors);
		if (FAILED(hr)) {
			log(YV_LOG_ERROR, "video: shader %s: %s", entry,
			    errors ? static_cast<const char *>(errors->GetBufferPointer()) : "?");
			return false;
		}
		return true;
	}

	bool make_pipeline() {
		ComPtr<ID3DBlob> vs, ps;
		if (!compile("vs", "vs_4_0", vs) || !compile("ps", "ps_4_0", ps)) {
			return false;
		}
		if (FAILED(device_->CreateVertexShader(vs->GetBufferPointer(), vs->GetBufferSize(),
		                                       nullptr, &vs_)) ||
		    FAILED(device_->CreatePixelShader(ps->GetBufferPointer(), ps->GetBufferSize(), nullptr,
		                                      &ps_))) {
			return false;
		}
		D3D11_SAMPLER_DESC sd{};
		sd.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
		sd.AddressU = sd.AddressV = sd.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
		sd.MaxLOD = D3D11_FLOAT32_MAX;
		D3D11_BUFFER_DESC bd{};
		bd.ByteWidth = sizeof(Constants);
		bd.Usage = D3D11_USAGE_DEFAULT;
		bd.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
		return SUCCEEDED(device_->CreateSamplerState(&sd, &sampler_)) &&
		       SUCCEEDED(device_->CreateBuffer(&bd, nullptr, &constants_));
	}

	/*
	planes_from_hw copies the decoder's frame (a slice of its texture
	array, which shaders can't read) into an NV12 or P010 texture of our
	own that they can, through an 8 or 16 bit view per plane.
	*/
	bool planes_from_hw(const AVFrame *frame, float uv_scale[2]) {
		if (hw_to_memory_) {
			return false;
		}
		auto *src = reinterpret_cast<ID3D11Texture2D *>(frame->data[0]);
		UINT index = static_cast<UINT>(reinterpret_cast<intptr_t>(frame->data[1]));
		D3D11_TEXTURE2D_DESC sd;
		src->GetDesc(&sd);
		D3D11_TEXTURE2D_DESC have{};
		if (hw_planes_) {
			hw_planes_->GetDesc(&have);
		}
		if (!hw_planes_ || have.Width != sd.Width || have.Height != sd.Height ||
		    have.Format != sd.Format) {
			hw_planes_.Reset();
			hw_y_.Reset();
			hw_uv_.Reset();
			DXGI_FORMAT y_fmt, uv_fmt;
			if (sd.Format == DXGI_FORMAT_NV12) {
				y_fmt = DXGI_FORMAT_R8_UNORM, uv_fmt = DXGI_FORMAT_R8G8_UNORM;
			} else if (sd.Format == DXGI_FORMAT_P010) {
				y_fmt = DXGI_FORMAT_R16_UNORM, uv_fmt = DXGI_FORMAT_R16G16_UNORM;
			} else {
				return false;
			}
			D3D11_TEXTURE2D_DESC d{};
			d.Width = sd.Width;
			d.Height = sd.Height;
			d.MipLevels = 1;
			d.ArraySize = 1;
			d.Format = sd.Format;
			d.SampleDesc.Count = 1;
			d.Usage = D3D11_USAGE_DEFAULT;
			d.BindFlags = D3D11_BIND_SHADER_RESOURCE;
			D3D11_SHADER_RESOURCE_VIEW_DESC vd{};
			vd.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D;
			vd.Texture2D.MipLevels = 1;
			if (FAILED(device_->CreateTexture2D(&d, nullptr, &hw_planes_))) {
				return false;
			}
			vd.Format = y_fmt;
			if (FAILED(device_->CreateShaderResourceView(hw_planes_.Get(), &vd, &hw_y_))) {
				hw_planes_.Reset();
				return false;
			}
			vd.Format = uv_fmt;
			if (FAILED(device_->CreateShaderResourceView(hw_planes_.Get(), &vd, &hw_uv_))) {
				hw_planes_.Reset();
				hw_y_.Reset();
				return false;
			}
		}
		ctx_->CopySubresourceRegion(hw_planes_.Get(), 0, 0, 0, 0, src, index, nullptr);
		plane_y_ = hw_y_.Get();
		plane_uv_ = hw_uv_.Get();
		uv_scale[0] = static_cast<float>(frame->width) / static_cast<float>(sd.Width);
		uv_scale[1] = static_cast<float>(frame->height) / static_cast<float>(sd.Height);
		return true;
	}

	bool make_plane(int w, int h, DXGI_FORMAT fmt, ComPtr<ID3D11Texture2D> &tex,
	                ComPtr<ID3D11ShaderResourceView> &view) {
		D3D11_TEXTURE2D_DESC have{};
		if (tex) {
			tex->GetDesc(&have);
			if (static_cast<int>(have.Width) == w && static_cast<int>(have.Height) == h) {
				return true;
			}
		}
		tex.Reset();
		view.Reset();
		D3D11_TEXTURE2D_DESC d{};
		d.Width = w;
		d.Height = h;
		d.MipLevels = 1;
		d.ArraySize = 1;
		d.Format = fmt;
		d.SampleDesc.Count = 1;
		d.Usage = D3D11_USAGE_DYNAMIC;
		d.BindFlags = D3D11_BIND_SHADER_RESOURCE;
		d.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
		return SUCCEEDED(device_->CreateTexture2D(&d, nullptr, &tex)) &&
		       SUCCEEDED(device_->CreateShaderResourceView(tex.Get(), nullptr, &view));
	}

	bool upload(ID3D11Texture2D *tex, const uint8_t *src, int pitch, int row_bytes, int rows) {
		D3D11_MAPPED_SUBRESOURCE m;
		if (FAILED(ctx_->Map(tex, 0, D3D11_MAP_WRITE_DISCARD, 0, &m))) {
			return false;
		}
		for (int y = 0; y < rows; y++) {
			memcpy(static_cast<uint8_t *>(m.pData) + y * m.RowPitch, src + y * pitch, row_bytes);
		}
		ctx_->Unmap(tex, 0);
		return true;
	}

	// planes_from_memory uploads a frame decoded in software.
	bool planes_from_memory(const AVFrame *frame) {
		const AVFrame *f = nv12_.convert(frame);
		if (!f) {
			return false;
		}
		int cw = (f->width + 1) / 2, ch = (f->height + 1) / 2;
		if (!make_plane(f->width, f->height, DXGI_FORMAT_R8_UNORM, mem_y_tex_, mem_y_) ||
		    !make_plane(cw, ch, DXGI_FORMAT_R8G8_UNORM, mem_uv_tex_, mem_uv_)) {
			return false;
		}
		if (!upload(mem_y_tex_.Get(), f->data[0], f->linesize[0], f->width, f->height) ||
		    !upload(mem_uv_tex_.Get(), f->data[1], f->linesize[1], cw * 2, ch)) {
			return false;
		}
		plane_y_ = mem_y_.Get();
		plane_uv_ = mem_uv_.Get();
		return true;
	}

	bool make_slot(Slot &s, int w, int h) {
		if (s.texture && s.width == w && s.height == h) {
			return true;
		}
		s.texture.Reset();
		s.target.Reset();
		s.mutex.Reset();
		s.handle = nullptr;
		D3D11_TEXTURE2D_DESC d{};
		d.Width = w;
		d.Height = h;
		d.MipLevels = 1;
		d.ArraySize = 1;
		d.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
		d.SampleDesc.Count = 1;
		d.Usage = D3D11_USAGE_DEFAULT;
		d.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
		d.MiscFlags = D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX;
		ComPtr<IDXGIResource> res;
		if (FAILED(device_->CreateTexture2D(&d, nullptr, &s.texture)) ||
		    FAILED(device_->CreateRenderTargetView(s.texture.Get(), nullptr, &s.target)) ||
		    FAILED(s.texture.As(&s.mutex)) || FAILED(s.texture.As(&res)) ||
		    FAILED(res->GetSharedHandle(&s.handle))) {
			log(YV_LOG_ERROR, "video: no %dx%d shared texture", w, h);
			s.texture.Reset();
			s.target.Reset();
			s.mutex.Reset();
			s.handle = nullptr;
			return false;
		}
		s.width = w;
		s.height = h;
		return true;
	}

	// draw converts the planes into a free slot and makes it the newest.
	bool draw(const AVFrame *frame, const float uv_scale[2], bool hardware) {
		int i = -1;
		{
			std::lock_guard<std::mutex> lock(mutex_);
			for (int j = 0; j < SLOTS; j++) {
				Slot_State st = slots_[j].state;
				if (st == Slot_State::Free || (st == Slot_State::Ready && j != newest_)) {
					i = j;
					break;
				}
			}
			if (i < 0) {
				return false; // can't be: one Reading, one newest, three slots
			}
			slots_[i].state = Slot_State::Writing;
		}
		Slot &s = slots_[i];
		bool ok = make_slot(s, frame->width, frame->height);
		if (ok) {
			Constants c{};
			Yuv_Matrix m = yuv_matrix(frame);
			memcpy(c.rows, m.rows, sizeof(c.rows));
			c.uv_scale[0] = uv_scale[0];
			c.uv_scale[1] = uv_scale[1];
			ctx_->UpdateSubresource(constants_.Get(), 0, nullptr, &c, 0, 0);

			s.mutex->AcquireSync(0, INFINITE);
			D3D11_VIEWPORT vp{0, 0, static_cast<float>(frame->width),
			                  static_cast<float>(frame->height), 0, 1};
			ID3D11ShaderResourceView *planes[2] = {plane_y_, plane_uv_};
			ctx_->OMSetRenderTargets(1, s.target.GetAddressOf(), nullptr);
			ctx_->RSSetViewports(1, &vp);
			ctx_->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
			ctx_->IASetInputLayout(nullptr);
			ctx_->VSSetShader(vs_.Get(), nullptr, 0);
			ctx_->VSSetConstantBuffers(0, 1, constants_.GetAddressOf());
			ctx_->PSSetShader(ps_.Get(), nullptr, 0);
			ctx_->PSSetConstantBuffers(0, 1, constants_.GetAddressOf());
			ctx_->PSSetShaderResources(0, 2, planes);
			ctx_->PSSetSamplers(0, 1, sampler_.GetAddressOf());
			ctx_->Draw(3, 0);
			// Let go of the planes, which the next frame writes.
			ID3D11ShaderResourceView *none[2] = {};
			ctx_->PSSetShaderResources(0, 2, none);
			ctx_->OMSetRenderTargets(0, nullptr, nullptr);
			s.mutex->ReleaseSync(0);
		}
		std::lock_guard<std::mutex> lock(mutex_);
		if (!ok) {
			s.state = Slot_State::Free;
			return false;
		}
		if (newest_ >= 0 && slots_[newest_].state == Slot_State::Ready) {
			slots_[newest_].state = Slot_State::Free;
		}
		s.state = Slot_State::Ready;
		s.published = s.handle;
		s.published_w = s.width;
		s.published_h = s.height;
		s.hardware = hardware;
		s.pts_us = static_cast<uint64_t>(frame->pts);
		newest_ = i;
		frames_++;
		cleared_ = false;
		return true;
	}

	// copy_to_display brings slot `i` over to the client's device.
	bool copy_to_display(int i, HANDLE handle, int w, int h) {
		Opened &o = opened_[i];
		if (o.handle != handle) {
			o = {};
			if (FAILED(client_->OpenSharedResource(handle, IID_PPV_ARGS(&o.texture))) ||
			    FAILED(o.texture.As(&o.mutex))) {
				log(YV_LOG_ERROR, "video: can't open the decoder's texture on the client's device");
				o = {};
				return false;
			}
			o.handle = handle;
		}
		if (!display_ || display_w_ != w || display_h_ != h) {
			display_.Reset();
			display_view_.Reset();
			D3D11_TEXTURE2D_DESC d{};
			d.Width = w;
			d.Height = h;
			d.MipLevels = 1;
			d.ArraySize = 1;
			d.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
			d.SampleDesc.Count = 1;
			d.Usage = D3D11_USAGE_DEFAULT;
			d.BindFlags = D3D11_BIND_SHADER_RESOURCE;
			if (FAILED(client_->CreateTexture2D(&d, nullptr, &display_)) ||
			    FAILED(client_->CreateShaderResourceView(display_.Get(), nullptr, &display_view_))) {
				display_.Reset();
				display_view_.Reset();
				return false;
			}
			display_w_ = w;
			display_h_ = h;
		}
		if (o.mutex->AcquireSync(0, 100) != S_OK) {
			return false;
		}
		client_ctx_->CopyResource(display_.Get(), o.texture.Get());
		o.mutex->ReleaseSync(0);
		return true;
	}
};

} // namespace

std::unique_ptr<Output> make_output() {
	return std::make_unique<Output_D3D11>();
}

uint64_t gpu_luid(const yv_gpu *gpu) {
	if (!gpu || gpu->kind != YV_GPU_D3D11 || !gpu->d3d11_device) {
		return 0;
	}
	auto *dev = static_cast<ID3D11Device *>(gpu->d3d11_device);
	ComPtr<IDXGIDevice> dxgi;
	ComPtr<IDXGIAdapter> adapter;
	DXGI_ADAPTER_DESC desc;
	if (FAILED(dev->QueryInterface(IID_PPV_ARGS(&dxgi))) || FAILED(dxgi->GetAdapter(&adapter)) ||
	    FAILED(adapter->GetDesc(&desc))) {
		return 0;
	}
	return luid_value(desc.AdapterLuid);
}

} // namespace yv
