package server

import "core:fmt"
import "core:os"
import "core:time"

/*
`yap-server push test`: sends one push to a subscription given by hand,
to see that the server's push config, libcurl and the push service get
along. The endpoint and the keys are what a browser's
PushSubscription.toJSON() gives (its "endpoint", and "keys"' "p256dh"
and "auth", in base64url), with the server's VAPID public key (printed
here) as the applicationServerKey it subscribed with.

	yap-server push test [config.json]
	yap-server push test <endpoint> <p256dh> <auth> [config.json]

Without a subscription it only prints the key. It can run while the
server does.
*/

PUSH_USAGE :: `usage: yap-server push test [<endpoint> <p256dh> <auth>] [config.json]`

// run_push_command runs `yap-server push <args...>` and returns the
// process's exit code.
run_push_command :: proc(args: []string) -> int {
	if len(args) == 0 || args[0] != "test" || (len(args) != 1 && len(args) != 2 && len(args) != 4 && len(args) != 5) {
		fmt.eprintln(PUSH_USAGE)
		return 2
	}
	config := DEFAULT_CONFIG_FILE
	if len(args) == 2 || len(args) == 5 {
		config = args[len(args) - 1]
	}
	if !os.exists(config) {
		fmt.eprintfln("%s: no such config (run the server once, or name its config)", config)
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
		fmt.eprintln("push could not start; see above")
		return 1
	}
	fmt.printfln("VAPID public key: %s", base64url(p.public[:], context.temp_allocator))
	fmt.printfln("subject: %s", p.subject)
	if len(args) < 4 {
		return 0
	}

	job := Push_Job {
		endpoint = args[1],
		payload  = transmute([]u8)string(`{"title":"yap","body":"A test from yap-server"}`),
		ttl      = 60,
		urgency  = .High,
	}
	p256dh, p_ok := base64url_decode(args[2], context.temp_allocator)
	auth, a_ok := base64url_decode(args[3], context.temp_allocator)
	if !p_ok || !a_ok || len(p256dh) != P256_PUBLIC_SIZE || len(auth) != PUSH_AUTH_SIZE {
		fmt.eprintln("p256dh has to be 65 bytes and auth 16, in base64url")
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
				fmt.println("the push service says this subscription is gone")
				return 1
			case .Failed:
				fmt.println("failed; see above")
				return 1
			}
		}
		if time.tick_since(deadline) > time.Minute {
			fmt.println("no answer within a minute")
			return 1
		}
		time.sleep(50 * time.Millisecond)
	}
}
