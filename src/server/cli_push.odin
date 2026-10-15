package server

import "core:fmt"
import "core:os"
import "core:time"

// `yap-server push test`: sends a single push to a manually supplied subscription, to
// check that the server's push config, libcurl and the push service work together. The
// endpoint and keys are the values from a browser's PushSubscription.toJSON() (its
// "endpoint", and the "p256dh" and "auth" fields of "keys", in base64url). The browser
// must have subscribed with the server's VAPID public key (printed by this command) as its
// applicationServerKey.
//
//	yap-server push test [config.json]
//	yap-server push test <endpoint> <p256dh> <auth> [config.json]
//
// Without a subscription it only prints the key. It can be run while the server is
// running.

PUSH_USAGE :: `usage: yap-server push test [<endpoint> <p256dh> <auth>] [config.json]`

// run_push_command runs `yap-server push <args...>` and returns the
// process's exit code.
run_push_command :: proc(args: []string) -> int {
	if len(args) == 0 ||
	   args[0] != "test" ||
	   (len(args) != 1 && len(args) != 2 && len(args) != 4 && len(args) != 5) {
		fmt.eprintln(PUSH_USAGE)
		return 2
	}
	config := DEFAULT_CONFIG_FILE
	if len(args) == 2 || len(args) == 5 {
		config = args[len(args) - 1]
	}
	if !os.exists(config) {
		fmt.eprintfln(
			"%s: config file not found (run the server once to create it, or pass the path to its config)",
			config,
		)
		return 2
	}
	settings, config_ok := load_config(config)
	if !config_ok {
		return 2
	}
	if !settings.push.enabled {
		fmt.eprintfln("%s has push turned off (\"push\": {\"enabled\": false})", config)
		return 2
	}
	p: Push
	push_open(&p, settings.push)
	defer push_close(&p)
	if !p.enabled {
		fmt.eprintln("push could not be started; see the errors above")
		return 1
	}
	fmt.printfln("VAPID public key: %s", base64url(p.public[:], context.temp_allocator))
	fmt.printfln("subject: %s", p.subject)
	if len(args) < 4 {
		return 0
	}

	job := Push_Job {
		endpoint = args[1],
		payload  = transmute([]u8)string(
			`{"title":"yap","body":"A test notification from yap-server"}`,
		),
		ttl      = 60,
		urgency  = .High,
	}
	p256dh, p_ok := base64url_decode(args[2], context.temp_allocator)
	auth, a_ok := base64url_decode(args[3], context.temp_allocator)
	if !p_ok || !a_ok || len(p256dh) != P256_PUBLIC_SIZE || len(auth) != PUSH_AUTH_SIZE {
		fmt.eprintln("p256dh must be 65 bytes and auth 16 bytes, both base64url-encoded")
		return 2
	}
	copy(job.p256dh[:], p256dh)
	copy(job.auth[:], auth)
	if !push_send(&p, job) {
		fmt.eprintfln("%q isn't an https:// endpoint", args[1])
		return 2
	}
	deadline := time.tick_now()
	for {
		if r, ok := push_poll(&p); ok {
			switch r.outcome {
			case .Sent:
				fmt.printfln("sent to %s", push_origin(args[1]))
				return 0
			case .Gone:
				fmt.println("the push service reports that this subscription no longer exists")
				return 1
			case .Failed:
				fmt.println("sending the push failed; see the errors above")
				return 1
			}
		}
		if time.tick_since(deadline) > time.Minute {
			fmt.println("the push service didn't answer within a minute")
			return 1
		}
		time.sleep(50 * time.Millisecond)
	}
}
