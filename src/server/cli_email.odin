package server

import "core:fmt"
import "core:strings"
import "core:time"

import "curl"
import "mail"

// `yap-server email test` tries out the email config (see mail/mail.odin) and
// reports what worked. It is meant for whoever is setting up the server.
//
//	yap-server email test [config.json]
//	yap-server email test <someone@example.org> [config.json]
//
// It logs in to the IMAP server and counts the unread mails in the INBOX
// (without marking them as read), and it logs in to the SMTP server. If an
// address is given, it sends a test mail to that address as well. It can run
// while the server is running.

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
	settings, config_ok := cli_config(config)
	if !config_ok {
		return 2
	}
	cfg := settings.email
	if cfg.address == "" {
		fmt.eprintfln(
			"%s has no email address configured (set \"email\": {\"address\": ...})",
			config,
		)
		return 2
	}
	e := mail.Mailer {
		config = cfg,
	}
	if !curl.load(&e.lib) {
		fmt.eprintln("email is unavailable because libcurl could not be loaded")
		return 1
	}

	failed := false
	found := make([dynamic]u8, context.temp_allocator)
	box := fmt.tprintf("%s/INBOX", mail.url_base(cfg.imap))
	// Searching doesn't mark any mail as read.
	if err := mail.curl_request(&e, nil, box, custom = "UID SEARCH UNSEEN", out = &found);
	   err != "" {
		fmt.printfln("IMAP %s: failed: %s", cfg.imap, err)
		failed = true
	} else {
		fmt.printfln(
			"IMAP %s: logged in, %d unread mails in the INBOX",
			cfg.imap,
			len(mail.imap_search_uids(string(found[:]))),
		)
	}

	switch {
	case cfg.smtp == "":
		fmt.println("SMTP: not configured, so the server will not send any mail")
	case to != "":
		message := mail.compose(
			cfg.address,
			strings.to_lower(to, context.temp_allocator),
			"yap: a test",
			"This is a test from yap-server email test.\n",
			time.now(),
		)
		err := mail.curl_request(
			&e,
			nil,
			mail.url_base(cfg.smtp),
			mail_from = cfg.address,
			mail_to = strings.to_lower(to, context.temp_allocator),
			upload = transmute([]u8)message,
		)
		if err != "" {
			fmt.printfln("SMTP %s: failed to send a test mail to %s: %s", cfg.smtp, to, err)
			failed = true
		} else {
			fmt.printfln("SMTP %s: sent a test mail to %s", cfg.smtp, to)
		}
	case:
		if err := mail.curl_request(
			&e,
			nil,
			mail.url_base(cfg.smtp),
			custom = "NOOP",
			no_body = true,
		); err != "" {
			fmt.printfln("SMTP %s: failed: %s", cfg.smtp, err)
			failed = true
		} else {
			fmt.printfln("SMTP %s: logged in (pass an address to send a test mail)", cfg.smtp)
		}
	}
	return 1 if failed else 0
}
