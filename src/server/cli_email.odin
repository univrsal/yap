package server

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

/*
`yap-server email test`: tries the email config out (email.odin) and
says what worked, for whoever is setting it up.

	yap-server email test [config.json]
	yap-server email test <someone@example.org> [config.json]

It logs in to the IMAP server and counts the mails in the INBOX that
haven't been read (without marking them read), and logs in to the SMTP
server; given an address, it mails that a test instead. It can run
while the server does.
*/

EMAIL_USAGE :: `usage: yap-server email test [address to mail] [config.json]`

// run_email_command runs `yap-server email <args...>` and returns the
// process's exit code.
run_email_command :: proc(args: []string) -> int {
	if len(args) == 0 || args[0] != "test" || len(args) > 3 {
		fmt.eprintln(EMAIL_USAGE)
		return 2
	}
	to, config := "", DEFAULT_CONFIG_FILE
	for arg in args[1:] {
		if strings.contains_rune(arg, '@') {
			to = arg
		} else {
			config = arg
		}
	}
	if !os.exists(config) {
		fmt.eprintfln("%s: no such config (run the server once, or name its config)", config)
		return 2
	}
	settings, config_ok := load_config(config)
	if !config_ok {
		return 2
	}
	cfg := settings.email
	if cfg.address == "" {
		fmt.eprintfln("%s has no email address configured (\"email\": {\"address\": ...})", config)
		return 2
	}
	e := Email {
		config = cfg,
	}
	if !curl_load(&e.curl) {
		fmt.eprintln("no email without libcurl")
		return 1
	}

	failed := false
	found := make([dynamic]u8, context.temp_allocator)
	box := fmt.tprintf("%s/INBOX", url_base(cfg.imap))
	// Searching marks nothing seen.
	if err := curl_request(&e, nil, box, custom = "UID SEARCH UNSEEN", out = &found); err != "" {
		fmt.printfln("IMAP %s: failed: %s", cfg.imap, err)
		failed = true
	} else {
		fmt.printfln(
			"IMAP %s: logged in, %d unread mails in the INBOX",
			cfg.imap,
			len(imap_search_uids(string(found[:]))),
		)
	}

	switch {
	case cfg.smtp == "":
		fmt.println("SMTP: none configured, so the server sends no mail")
	case to != "":
		message := mail_compose(
			cfg.address,
			strings.to_lower(to, context.temp_allocator),
			"yap: a test",
			"This is a test from yap-server email test.\n",
			time.now(),
		)
		err := curl_request(
			&e,
			nil,
			url_base(cfg.smtp),
			mail_from = cfg.address,
			mail_to = strings.to_lower(to, context.temp_allocator),
			upload = transmute([]u8)message,
		)
		if err != "" {
			fmt.printfln("SMTP %s: mailing %s failed: %s", cfg.smtp, to, err)
			failed = true
		} else {
			fmt.printfln("SMTP %s: mailed %s", cfg.smtp, to)
		}
	case:
		if err := curl_request(&e, nil, url_base(cfg.smtp), custom = "NOOP", no_body = true); err != "" {
			fmt.printfln("SMTP %s: failed: %s", cfg.smtp, err)
			failed = true
		} else {
			fmt.printfln("SMTP %s: logged in (give an address to mail a test)", cfg.smtp)
		}
	}
	return 1 if failed else 0
}
