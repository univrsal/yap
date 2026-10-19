// Cameras where they aren't captured yet (macOS: misc/video-chat, phase 8):
// only the fake one (camera_fake.cpp).
#include "pipeline.h"

#include <cstring>

namespace yv {

std::vector<Camera_Info> list_cameras() {
	Camera_Info fake;
	if (fake_camera(fake)) {
		return {fake};
	}
	return {};
}

bool camera_allowed(bool) {
	return true;
}

std::unique_ptr<Camera_Source> make_camera_source(const Camera_Info &camera) {
	if (strcmp(camera.camera.id, FAKE_CAMERA_ID) == 0) {
		return make_fake_source();
	}
	return nullptr;
}

} // namespace yv
