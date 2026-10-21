/*
yv-loopback --play and --share on Windows: a window with a D3D11 device
of its own, standing in for the client's (SINGLETHREADED, like the
client's), which draws what a view presents. Frames are pushed from
another thread, as the client's network thread would: from the file at
the given rate, or as a share of the screen encodes them, with how long
they took printed (capture to encoded, capture to on screen).
*/
#include "play.h"
#include "stream_file.h"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <thread>

#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <dxgi1_2.h>
#include <wrl/client.h>

using Microsoft::WRL::ComPtr;

namespace {

const char SHADERS[] = R"(
Texture2D<float4> picture : register(t0);
SamplerState linear_clamp : register(s0);
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
float4 ps(Varying v) : SV_Target {
	return picture.Sample(linear_clamp, v.uv);
}
)";

std::atomic<bool> quit{false};

LRESULT CALLBACK window_proc(HWND w, UINT msg, WPARAM wp, LPARAM lp) {
	if (msg == WM_CLOSE || (msg == WM_KEYDOWN && wp == VK_ESCAPE)) {
		quit = true;
		return 0;
	}
	return DefWindowProcW(w, msg, wp, lp);
}

bool compile(const char *entry, const char *target, ComPtr<ID3DBlob> &out) {
	ComPtr<ID3DBlob> errors;
	if (FAILED(D3DCompile(SHADERS, sizeof(SHADERS) - 1, "play", nullptr, nullptr, entry, target, 0,
	                      0, &out, &errors))) {
		fprintf(stderr, "shader: %s\n",
		        errors ? static_cast<const char *>(errors->GetBufferPointer()) : "?");
		return false;
	}
	return true;
}

// save_bmp writes the picture behind `view` to a 32-bit BMP.
bool save_bmp(ID3D11Device *dev, ID3D11DeviceContext *ctx, ID3D11ShaderResourceView *view,
              const char *path) {
	ComPtr<ID3D11Resource> res;
	view->GetResource(&res);
	ComPtr<ID3D11Texture2D> tex;
	if (FAILED(res.As(&tex))) {
		return false;
	}
	D3D11_TEXTURE2D_DESC d;
	tex->GetDesc(&d);
	d.Usage = D3D11_USAGE_STAGING;
	d.BindFlags = 0;
	d.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
	d.MiscFlags = 0;
	ComPtr<ID3D11Texture2D> staging;
	if (FAILED(dev->CreateTexture2D(&d, nullptr, &staging))) {
		return false;
	}
	ctx->CopyResource(staging.Get(), tex.Get());
	D3D11_MAPPED_SUBRESOURCE m;
	if (FAILED(ctx->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &m))) {
		return false;
	}
	FILE *f = fopen(path, "wb");
	if (!f) {
		ctx->Unmap(staging.Get(), 0);
		return false;
	}
	BITMAPFILEHEADER fh{};
	BITMAPINFOHEADER ih{};
	ih.biSize = sizeof(ih);
	ih.biWidth = static_cast<LONG>(d.Width);
	ih.biHeight = -static_cast<LONG>(d.Height); // top down
	ih.biPlanes = 1;
	ih.biBitCount = 32;
	ih.biCompression = BI_RGB;
	fh.bfType = 0x4d42;
	fh.bfOffBits = sizeof(fh) + sizeof(ih);
	fh.bfSize = fh.bfOffBits + d.Width * d.Height * 4;
	fwrite(&fh, sizeof(fh), 1, f);
	fwrite(&ih, sizeof(ih), 1, f);
	std::vector<uint8_t> row(d.Width * 4);
	for (UINT y = 0; y < d.Height; y++) {
		const uint8_t *src = static_cast<const uint8_t *>(m.pData) + y * m.RowPitch;
		for (UINT x = 0; x < d.Width; x++) { // RGBA to BGRA
			row[x * 4 + 0] = src[x * 4 + 2];
			row[x * 4 + 1] = src[x * 4 + 1];
			row[x * 4 + 2] = src[x * 4 + 0];
			row[x * 4 + 3] = 255;
		}
		fwrite(row.data(), 1, row.size(), f);
	}
	fclose(f);
	ctx->Unmap(staging.Get(), 0);
	return true;
}

} // namespace

int play(yv_context *ctx, const Play_Options &opt) {
	Stream_File file;
	std::string error;
	yv_share *share = nullptr;
	if (opt.share) {
		share = start_share(ctx, opt);
	} else {
		if (!load_stream(opt.path, file, error)) {
			fprintf(stderr, "%s: %s\n", opt.path, error.c_str());
			return 1;
		}
		printf("%s: %zu frames\n", opt.path, file.frames.size());
	}

	WNDCLASSW wc{};
	wc.lpfnWndProc = window_proc;
	wc.hInstance = GetModuleHandleW(nullptr);
	wc.lpszClassName = L"yv-loopback";
	wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
	RegisterClassW(&wc);
	HWND hwnd = CreateWindowW(L"yv-loopback", L"yv-loopback", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
	                          CW_USEDEFAULT, CW_USEDEFAULT, 1280, 720, nullptr, nullptr,
	                          wc.hInstance, nullptr);

	ComPtr<ID3D11Device> dev;
	ComPtr<ID3D11DeviceContext> dc;
	if (FAILED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
	                             D3D11_CREATE_DEVICE_SINGLETHREADED, nullptr, 0, D3D11_SDK_VERSION,
	                             &dev, nullptr, &dc))) {
		fprintf(stderr, "no D3D11 device\n");
		return 1;
	}
	ComPtr<IDXGIDevice> dxgi_dev;
	ComPtr<IDXGIAdapter> adapter;
	ComPtr<IDXGIFactory2> factory;
	dev.As(&dxgi_dev);
	dxgi_dev->GetAdapter(&adapter);
	adapter->GetParent(IID_PPV_ARGS(&factory));
	DXGI_SWAP_CHAIN_DESC1 sd{};
	sd.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
	sd.SampleDesc.Count = 1;
	sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
	sd.BufferCount = 2;
	sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
	ComPtr<IDXGISwapChain1> swap;
	if (FAILED(factory->CreateSwapChainForHwnd(dev.Get(), hwnd, &sd, nullptr, nullptr, &swap))) {
		fprintf(stderr, "no swap chain\n");
		return 1;
	}
	ComPtr<ID3DBlob> vsb, psb;
	ComPtr<ID3D11VertexShader> vs;
	ComPtr<ID3D11PixelShader> ps;
	ComPtr<ID3D11SamplerState> sampler;
	if (!compile("vs", "vs_4_0", vsb) || !compile("ps", "ps_4_0", psb)) {
		return 1;
	}
	dev->CreateVertexShader(vsb->GetBufferPointer(), vsb->GetBufferSize(), nullptr, &vs);
	dev->CreatePixelShader(psb->GetBufferPointer(), psb->GetBufferSize(), nullptr, &ps);
	D3D11_SAMPLER_DESC smp{};
	smp.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
	smp.AddressU = smp.AddressV = smp.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
	dev->CreateSamplerState(&smp, &sampler);

	yv_gpu gpu{};
	gpu.kind = YV_GPU_D3D11;
	gpu.d3d11_device = dev.Get();
	yv_set_gpu(ctx, &gpu);
	yv_view *view = yv_view_create(ctx);

	// The network thread's part: frames at the file's rate, round and
	// round, with a keyframe request answered by starting over.
	std::atomic<uint64_t> pushed{0};
	std::atomic<uint64_t> bytes{0}, keys{0}, encode_us{0};
	std::atomic<bool> share_failed{false};
	// --out: the stream, in a file named for its codec once it's known.
	FILE *out = nullptr;
	auto save = [&](const yv_packet &p) {
		if (opt.out && !out) {
			std::string path = std::string(opt.out) + stream_extension(p.codec);
			out = fopen(path.c_str(), "wb");
			if (out) {
				printf("saving the stream to %s\n", path.c_str());
			}
		}
		if (out) {
			fwrite(p.data, 1, p.size, out);
		}
	};
	auto share_feeder = [&] {
		bool live = false;
		auto began = std::chrono::steady_clock::now();
		bool switched = false;
		while (!quit) {
			follow_then(share, opt,
			            std::chrono::duration<double>(std::chrono::steady_clock::now() - began).count(),
			            switched);
			yv_share_state st = yv_share_get_state(share);
			if (st == YV_SHARE_FAILED) {
				fprintf(stderr, "share failed: %s\n", yv_share_error(share));
				share_failed = true;
				quit = true;
				break;
			}
			if (st == YV_SHARE_LIVE && !live) {
				printf("share is live\n");
				live = true;
			}
			if (yv_view_take_failed(view)) {
				yv_share_request_key(share);
			}
			yv_packet p;
			bool any = false;
			while (yv_share_pull(share, &p)) {
				any = true;
				save(p);
				encode_us += yv_clock_us() - p.pts_us;
				bytes += p.size;
				keys += p.key ? 1 : 0;
				yv_view_push(view, p.data, p.size, p.codec, p.pts_us, p.key);
				pushed++;
			}
			if (!any) {
				std::this_thread::sleep_for(std::chrono::milliseconds(1));
			}
		}
	};
	auto file_feeder = [&] {
		auto interval = std::chrono::microseconds(1'000'000 / opt.fps);
		auto next = std::chrono::steady_clock::now();
		size_t i = 0;
		while (!quit) {
			if (yv_view_take_failed(view)) {
				printf("decoder asked for a keyframe; starting over\n");
				i = 0;
			}
			const Stream_Frame &f = file.frames[i];
			uint64_t pts = pushed * 1'000'000 / opt.fps;
			yv_view_push(view, file.data.data() + f.offset, f.size, file.codec, pts, f.key);
			pushed++;
			if (++i == file.frames.size()) {
				if (opt.once) {
					break;
				}
				i = 0;
			}
			next += interval;
			std::this_thread::sleep_until(next);
		}
	};
	std::thread feeder = opt.share ? std::thread(share_feeder) : std::thread(file_feeder);

	UINT bw = 0, bh = 0;
	ComPtr<ID3D11RenderTargetView> target;
	auto start = std::chrono::steady_clock::now();
	auto last_stats = start;
	uint64_t drawn = 0, last_frames = 0, last_pushed = 0, last_bytes = 0, last_encode = 0;
	uint64_t shown_us = 0, shown_n = 0, last_pts = 0;
	yv_picture pic{};
	bool have = false;
	while (!quit) {
		MSG msg;
		while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
			TranslateMessage(&msg);
			DispatchMessageW(&msg);
		}
		RECT rc;
		GetClientRect(hwnd, &rc);
		UINT w = static_cast<UINT>(rc.right - rc.left), h = static_cast<UINT>(rc.bottom - rc.top);
		if (w == 0 || h == 0) {
			Sleep(10);
			continue;
		}
		if (w != bw || h != bh) {
			target.Reset();
			swap->ResizeBuffers(0, w, h, DXGI_FORMAT_UNKNOWN, 0);
			ComPtr<ID3D11Texture2D> back;
			swap->GetBuffer(0, IID_PPV_ARGS(&back));
			dev->CreateRenderTargetView(back.Get(), nullptr, &target);
			bw = w, bh = h;
		}
		have = yv_view_present(view, &pic);
		if (have && pic.pts_us != last_pts && opt.share) {
			// Capture to the picture being handed to us to draw.
			shown_us += yv_clock_us() - pic.pts_us;
			shown_n++;
			last_pts = pic.pts_us;
		}
		float black[4] = {0, 0, 0, 1};
		dc->ClearRenderTargetView(target.Get(), black);
		if (have) {
			// As big as fits, keeping its shape.
			float s = std::min(static_cast<float>(w) / pic.width, static_cast<float>(h) / pic.height);
			D3D11_VIEWPORT vp{(w - pic.width * s) / 2, (h - pic.height * s) / 2, pic.width * s,
			                  pic.height * s, 0, 1};
			auto *srv = reinterpret_cast<ID3D11ShaderResourceView *>(pic.texture);
			dc->OMSetRenderTargets(1, target.GetAddressOf(), nullptr);
			dc->RSSetViewports(1, &vp);
			dc->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
			dc->VSSetShader(vs.Get(), nullptr, 0);
			dc->PSSetShader(ps.Get(), nullptr, 0);
			dc->PSSetShaderResources(0, 1, &srv);
			dc->PSSetSamplers(0, 1, sampler.GetAddressOf());
			dc->Draw(3, 0);
			drawn++;
		}
		swap->Present(1, 0);

		auto now = std::chrono::steady_clock::now();
		double since = std::chrono::duration<double>(now - last_stats).count();
		if (since >= 1.0) {
			printf("pushed %llu, decoded %llu (%.0f/s), %dx%d, %s",
			       static_cast<unsigned long long>(pushed.load()),
			       static_cast<unsigned long long>(pic.frames), (pic.frames - last_frames) / since,
			       pic.width, pic.height, pic.hardware ? "hardware" : "software");
			if (opt.share) {
				uint64_t n = pushed - last_pushed;
				printf(", %.1f Mbit/s, encoded after %.1f ms, on screen after %.1f ms, %llu keyframes",
				       (bytes - last_bytes) * 8 / since / 1e6,
				       n ? (encode_us - last_encode) / 1000.0 / n : 0.0,
				       shown_n ? shown_us / 1000.0 / shown_n : 0.0,
				       static_cast<unsigned long long>(keys.load()));
				last_pushed = pushed;
				last_bytes = bytes;
				last_encode = encode_us;
				shown_us = shown_n = 0;
			}
			printf("\n");
			last_frames = pic.frames;
			last_stats = now;
		}
		if (opt.seconds > 0 && std::chrono::duration<double>(now - start).count() >= opt.seconds) {
			quit = true;
		}
	}
	feeder.join();
	int rc = 0;
	if (opt.dump) {
		if (have && save_bmp(dev.Get(), dc.Get(),
		                     reinterpret_cast<ID3D11ShaderResourceView *>(pic.texture), opt.dump)) {
			printf("saved the last picture to %s\n", opt.dump);
		} else {
			fprintf(stderr, "no picture to save\n");
			rc = 1;
		}
	}
	printf("decoded %llu frames, drew %llu\n", static_cast<unsigned long long>(pic.frames),
	       static_cast<unsigned long long>(drawn));
	if (pic.frames == 0 || share_failed) {
		rc = 1;
	}
	if (share) {
		yv_share_stop(share);
	}
	if (out) {
		fclose(out);
	}
	yv_set_gpu(ctx, nullptr);
	yv_view_destroy(view);
	DestroyWindow(hwnd);
	return rc;
}
