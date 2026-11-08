/*
No cameras, on the BSDs: there's no V4L2 there (OpenBSD's video(4) is its
own thing), so only the made-up one (camera_fake.cpp), for trying the rest.
*/
#include "pipeline.h"

#include <cstring>

namespace yv {

std::vector<Camera_Info> list_cameras() {
	std::vector<Camera_Info> out;
	Camera_Info fake;
	if (fake_camera(fake)) {
		out.push_back(fake);
	}
	return out;
}

bool camera_allowed(bool, const std::atomic<bool> *) {
	return true;
}

std::unique_ptr<Camera_Source> make_camera_source(const Camera_Info &camera) {
	if (strcmp(camera.camera.id, FAKE_CAMERA_ID) == 0) {
		return make_fake_source();
	}
	return nullptr;
}

} // namespace yv
