package mattermost

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import "common:imagekind"
import "common:proto"

// Pass 1 of the importer: read the whole export once, keep what the later
// steps need, and say what is wrong or will be left out. Users, channels and
// the like are kept whole; posts only as a small reference each (Post_Ref),
// because there can be a million of them, and are read again, in time order,
// by pass 2.

// The files of an export folder.
IMPORT_FILE :: "import.jsonl"
EXTRAS_FILE :: "extras.jsonl"
DATA_DIR :: "data"

// The allocator the scan keeps what it reads in.
Allocator :: runtime.Allocator

// How many lines are read between two calls of the progress callback.
PROGRESS_LINES :: 256

// What is wrong or is left out, which the report lists with the number of
// times it happened and a few examples.
Issue_Kind :: enum {
	Unknown_Line, // a line of a type that isn't known; skipped
	Duplicate_User, // two users or bots with one username; the later one is skipped
	Author_Not_Member, // wrote in an imported channel without being a member of the team
	Author_Unknown, // wrote something but has no user line (an account that is gone)
	Post_Channel_Unknown, // a post of the team in a channel that isn't in the export
	Direct_Member_Gone, // a direct channel with someone who isn't imported; left out
	Direct_Channel_Unknown, // a direct post whose channel isn't in the export
	Reactions_Channel_Unknown, // extras.jsonl's reactions to a post of an unknown channel
	Attachment_Missing, // a file that a post names isn't under data/
	Profile_Image_Missing, // the same for a profile picture
	Emoji_Image_Missing, // the same for a custom emoji
	Emoji_Unusable, // a custom emoji's picture that is too big, not a picture yap reads, or can't be read; skipped
	Emoji_Over_Limit, // custom emoji beyond what a server can have; the least used are left out
	Emoji_Exists, // a custom emoji whose file the server's emoji folder has already; skipped
	Attachments_Cut, // files beyond the number a message can have; left out
	Attachment_Empty, // a file with nothing in it; left out
	Attachment_Over_Limit, // a file bigger than this server lets people upload; kept
	Attachment_Failed, // a file that couldn't be read or stored; left out
	// Found by build_plan (plan.odin), which applies the mapping rules:
	Username_Changed, // a username yap wouldn't accept, or that another account has
	Email_Invalid, // an address yap doesn't accept; the account gets none
	Email_Taken, // an address that another account has; the later one gets none
	Channel_Renamed, // a channel whose display name another channel has too
	Name_Cut, // a name that was longer than yap's limit
	Topic_Cut, // a topic that was longer than yap's limit
	Emoji_Renamed, // a custom emoji whose name yap doesn't accept, or that another has
	System_Dropped, // system posts of a type that yap has no use for, by type
	System_Unknown, // system posts of a type this importer doesn't know, by type
	Reaction_Tone, // reactions with a skin tone, which become the emoji without one
	Reaction_Unknown, // reactions with an emoji name that isn't known; left out
	Channel_Scheme, // a channel with a scheme, whose rights are not imported
	Post_Empty, // a post with no text to show, by type; not imported yet (files: step 8, cards: step 10)
	Text_Cut, // a message longer than yap's limit
	System_Skipped, // a system post that couldn't be made one: who it was done to is not imported
	Thread_Root_Missing, // a reply whose first post wasn't imported; it is a message of its own
	Post_Failed, // a post that couldn't be read or written
	Reaction_User_Gone, // reactions by someone who isn't imported; left out
	Reactions_Cut, // reactions beyond yap's limit of different emoji on a message
	Saved_User_Gone, // a post saved by someone who isn't imported
	Pins_Cut, // pins beyond the limit of a conversation; the oldest are not kept
	Bookmarks_Cut, // saved posts beyond the limit of an account; the oldest are not kept
	Persona_Dropped, // an integration posing under the name of an account; it keeps its own name, which the post starts with
	Icon_Failed, // a picture that an integration poses with that couldn't be fetched
	// Found by the writing steps:
	Group_Too_Big, // a group message of more people than yap's groups have; left out, with its posts
	Guest_Disabled, // a guest, which yap has no kind of account for; made disabled
	Avatar_Failed, // a profile picture that couldn't be read or made small enough
}

// How many examples of each issue are kept.
EXAMPLES :: 5

Issue :: struct {
	count:    int,
	examples: [dynamic]string,
}

// Post_Ref is what pass 1 keeps of a post (or of a reply inside a post's line).
Post_Ref :: struct {
	time:   i64, // create_at, for a reply not before its post's: the order to insert in
	offset: i64, // where its line starts in import.jsonl
	length: i32, // of the line, without its newline
	reply:  i32, // -1 for the line's own post, else the index in its `replies`
	conv:   i32, // an index into Scan.channels or Scan.directs
	direct: bool,
}

// Stats is what the report counts.
Stats :: struct {
	roles:                 int,
	posts:                 int, // of the team, with their replies
	replies:               int,
	direct_posts:          int, // in imported direct channels, with their replies
	direct_posts_left_out: int, // in direct channels that aren't imported
	posts_other_teams:     int, // left out: another team's
	system:                int, // posts whose type is system_...
	pinned:                int,
	edited:                int,
	saved:                 int, // flagged_by entries
	reactions:             int,
	attachments:           int,
	first_time, last_time: i64,
	extra_reactions_posts: int, // posts that extras.jsonl adds reactions to
	by_type:               map[string]int, // posts by their type
	reaction_names:        map[string]int, // how many reactions there are of each emoji name
	webhook_posts:         int, // posts in channels that webhooks made
	bot_overrides:         int, // posts of bots that pose under another name
	cards:                 int, // posts with cards (props.attachments)
	text_tokens:           map[string]int, // how often each `:name:` is written in messages
}

// Scan is the result of pass 1. Everything in it is allocated from its own
// arena, so scan_destroy frees it all.
Scan :: struct {
	arena:           virtual.Arena,
	dir:             string,
	team:            string,
	info:            Version_Info,
	teams:           [dynamic]Team,
	team_found:      bool,
	channels:        [dynamic]Channel, // of the team
	channel_index:   map[string]int, // by name
	users:           [dynamic]User, // all, but with the memberships of the team only
	user_index:      map[string]int,
	members:         map[string]bool, // usernames of the team's members
	bots:            [dynamic]Bot,
	bot_index:       map[string]int,
	directs:         [dynamic]Direct_Channel, // those whose members are all imported
	direct_index:    map[string]int, // by direct_key
	directs_left:    int, // direct channels with a member who isn't imported
	left_out:        map[string]bool, // the keys of those
	posts:           [dynamic]Post_Ref,
	emoji:           [dynamic]Emoji,
	stats:           Stats,
	issues:          [Issue_Kind]Issue,
	lines:           int, // read, in both files
	// Names already reported as authors without a membership or a user line.
	reported:        map[string]bool,
	// The people who wrote in the team's channels without being members, in
	// the order they were first seen (see check_author).
	authors_only:    [dynamic]string,
	// Those who wrote something but have no user line at all, in the order
	// they were first seen.
	authors_gone:    [dynamic]string,
	has_extras:      bool, // extras.jsonl was read
	plan:            Plan, // filled in by build_plan
	// Every change of a channel's privacy, and which way each went (see
	// resolve_privacy_changes).
	privacy:         [dynamic]Privacy_Change,
	privacy_dir:     map[Privacy_Key]bool, // true: made private
	// The reactions that extras.jsonl adds to the first post of direct
	// channels, by extra_key.
	extra_reactions: map[string][]Reaction,
	// What each of the custom emoji (in `emoji`, in the same order) is as a file.
	emoji_files:     [dynamic]Emoji_File,
	// The webhooks that posted in channels, by the name they post as, in the order
	// they were first seen, and the addresses of the pictures that integrations
	// pose with, by how many posts have each.
	webhooks:        [dynamic]string,
	webhook_index:   map[string]int,
	icons:           map[string]int,
	// What made the scan stop, as a sentence (see scan_file).
	fatal:           string,
}

// Options is how a scan is asked for.
Options :: struct {
	dir:           string, // the unpacked export
	team:          string, // the team to import
	// Called every PROGRESS_LINES lines with how much of the file has been
	// read (`done` of `total` bytes) and which file it is. Optional.
	progress:      proc(file: string, done, total: i64, data: rawptr),
	progress_data: rawptr,
}

scan_destroy :: proc(s: ^Scan) {
	virtual.arena_destroy(&s.arena)
	free(s)
}

// join makes a path with the temp allocator.
join :: proc(parts: ..string) -> string {
	path, _ := filepath.join(parts, context.temp_allocator)
	return path
}

// data_file returns the path of a file that the export names (a path under
// data/), and false if it can't be one: an empty or absolute path, or one that
// leaves data/ by `..`. An export from another server mustn't be able to have a
// file of this one, such as /etc/passwd, imported into a chat where everyone
// could read it.
data_file :: proc(dir, relative: string) -> (path: string, ok: bool) {
	if relative == "" ||
	   filepath.is_abs(relative) ||
	   strings.has_prefix(relative, "\\") ||
	   (len(relative) > 1 && relative[1] == ':') {
		return
	}
	root := join(dir, DATA_DIR)
	path = join(root, relative)
	return path,
		strings.has_prefix(path, strings.concatenate({root, "/"}, context.temp_allocator)) ||
		strings.has_prefix(path, strings.concatenate({root, "\\"}, context.temp_allocator))
}

// scan reads an export. If it can't be read, `err` says why (a sentence, with
// the line number where it applies) and the Scan is destroyed. Problems that
// only mean something is left out are in `issues`.
scan :: proc(opts: Options) -> (s: ^Scan, err: string) {
	s = new(Scan)
	if virtual.arena_init_growing(&s.arena) != nil {
		free(s)
		return nil, "out of memory"
	}
	a := virtual.arena_allocator(&s.arena)
	s.dir = strings.clone(opts.dir, a)
	s.team = strings.clone(opts.team, a)
	s.teams.allocator = a
	s.channels.allocator = a
	s.channel_index = make(map[string]int, a)
	s.users.allocator = a
	s.user_index = make(map[string]int, a)
	s.members = make(map[string]bool, a)
	s.bots.allocator = a
	s.bot_index = make(map[string]int, a)
	s.directs.allocator = a
	s.direct_index = make(map[string]int, a)
	s.left_out = make(map[string]bool, a)
	s.posts.allocator = a
	s.emoji.allocator = a
	s.stats.by_type = make(map[string]int, a)
	s.stats.reaction_names = make(map[string]int, a)
	s.stats.text_tokens = make(map[string]int, a)
	s.reported = make(map[string]bool, a)
	s.authors_only.allocator = a
	s.authors_gone.allocator = a
	s.privacy.allocator = a
	s.webhooks.allocator = a
	s.webhook_index = make(map[string]int, a)
	s.icons = make(map[string]int, a)
	s.emoji_files.allocator = a
	s.extra_reactions = make(map[string][]Reaction, a)
	s.privacy_dir = make(map[Privacy_Key]bool, a)
	for &i in s.issues {
		i.examples.allocator = a
	}

	// What one line is read into is freed after the line, so that the memory
	// doesn't grow with the number of posts.
	tmp: virtual.Arena
	if virtual.arena_init_growing(&tmp) != nil {
		scan_destroy(s)
		return nil, "out of memory"
	}
	defer virtual.arena_destroy(&tmp)

	err = scan_file(s, &tmp, opts, IMPORT_FILE, false)
	if err == "" && s.info.version == "" && s.lines == 0 {
		err = "import.jsonl is empty"
	}
	if err == "" && !s.team_found {
		names := make([dynamic]string, 0, len(s.teams), context.temp_allocator)
		for t in s.teams {
			append(&names, t.name)
		}
		err = fmt.aprintf(
			"there is no team called %q in the export (it has: %s)",
			s.team,
			strings.join(names[:], ", ", context.temp_allocator),
			allocator = context.temp_allocator,
		)
	}
	if err == "" && os.exists(join(opts.dir, EXTRAS_FILE)) {
		s.has_extras = true
		err = scan_file(s, &tmp, opts, EXTRAS_FILE, true)
	}
	if err != "" {
		err = strings.clone(err)
		scan_destroy(s)
		return nil, err
	}
	scan_check_files(s)
	resolve_privacy_changes(s)
	return s, ""
}

// scan_file reads import.jsonl, or extras.jsonl if `extras`.
@(private = "file")
scan_file :: proc(
	s: ^Scan,
	tmp: ^virtual.Arena,
	opts: Options,
	name: string,
	extras: bool,
) -> string {
	path := join(opts.dir, name)
	l: Lines
	if msg := lines_open(&l, path); msg != "" {
		return fmt.tprintf("%s: %s", path, msg)
	}
	defer lines_close(&l)
	a := virtual.arena_allocator(&s.arena)
	scratch := virtual.arena_allocator(tmp)
	first := true
	for {
		virtual.arena_free_all(tmp)
		line, at, ok := lines_next(&l, scratch)
		if !ok {
			break
		}
		s.lines += 1
		kind := peek_kind(line, scratch)
		if first && !extras {
			first = false
			if kind != .Version {
				return fmt.tprintf(
					"%s: the first line has to be the version, not %q",
					name,
					line[:min(len(line), 40)],
				)
			}
		}
		if !scan_line(s, kind, line, at, extras, a, scratch) {
			return fmt.tprintf("%s, line %d: %s", name, l.number, s.fatal)
		}
		if opts.progress != nil && l.number % PROGRESS_LINES == 0 {
			opts.progress(name, l.offset, l.size, opts.progress_data)
		}
	}
	if opts.progress != nil {
		opts.progress(name, l.size, l.size, opts.progress_data)
	}
	return ""
}

// peek_kind reads the type of a line. The export writes it first, so it is
// found without reading the line; if it isn't there, the whole line is read.
@(private = "file")
peek_kind :: proc(line: []u8, allocator := context.allocator) -> Line_Kind {
	PREFIX :: `{"type":"`
	text := string(line)
	if strings.has_prefix(text, PREFIX) {
		rest := text[len(PREFIX):]
		if end := strings.index_byte(rest, '"'); end >= 0 {
			return line_kind_of(rest[:end])
		}
	}
	Header :: struct {
		type: string,
	}
	h: Header
	if json.unmarshal(line, &h, allocator = allocator) != nil {
		return .Unknown
	}
	return line_kind_of(h.type)
}

// read_line reads a line into `v`. If it isn't valid JSON for it, the scan is
// told to stop.
@(private = "file")
read_line :: proc(s: ^Scan, line: []u8, v: ^$T, allocator: Allocator) -> bool {
	if err := json.unmarshal(line, v, allocator = allocator); err != nil {
		s.fatal = fmt.aprintf("not valid: %v", err, allocator = virtual.arena_allocator(&s.arena))
		return false
	}
	return true
}

@(private = "file")
scan_line :: proc(
	s: ^Scan,
	kind: Line_Kind,
	line: []u8,
	at: i64,
	extras: bool,
	a, scratch: Allocator,
) -> bool {
	if extras {
		#partial switch kind {
		case .Emoji:
			w: Emoji_Wrapper
			read_line(s, line, &w, a) or_return
			append(&s.emoji, w.emoji)
		case .Direct_Post_Reactions:
			w: Direct_Post_Reactions_Wrapper
			read_line(s, line, &w, scratch) or_return
			scan_extra_reactions(s, w.direct_post_reactions)
		case:
			note(
				s,
				.Unknown_Line,
				fmt.tprintf("%s: %s", EXTRAS_FILE, line[:min(len(line), 40)]),
				a,
			)
		}
		return true
	}
	#partial switch kind {
	case .Version:
		w: Version_Wrapper
		read_line(s, line, &w, a) or_return
		if w.version != EXPORT_VERSION {
			s.fatal = fmt.aprintf(
				"this export is of format version %d, which this importer doesn't know (it reads version %d)",
				w.version,
				EXPORT_VERSION,
				allocator = a,
			)
			return false
		}
		s.info = w.info
	case .Role, .Scheme:
		s.stats.roles += 1
	case .Team:
		w: Team_Wrapper
		read_line(s, line, &w, a) or_return
		append(&s.teams, w.team)
		s.team_found ||= w.team.name == s.team
	case .Channel:
		w: Channel_Wrapper
		read_line(s, line, &w, a) or_return
		if w.channel.team == s.team {
			s.channel_index[w.channel.name] = len(s.channels)
			append(&s.channels, w.channel)
		}
	case .User:
		w: User_Wrapper
		read_line(s, line, &w, a) or_return
		scan_user(s, w.user)
	case .Bot:
		w: Bot_Wrapper
		read_line(s, line, &w, a) or_return
		b := w.bot
		if b.username in s.bot_index || b.username in s.user_index {
			note(s, .Duplicate_User, b.username, a)
		} else {
			s.bot_index[b.username] = len(s.bots)
			append(&s.bots, b)
		}
	case .Post:
		w: Post_Wrapper
		read_line(s, line, &w, scratch) or_return
		scan_post(s, w.post, at, len(line), a)
	case .Emoji:
		// The export has none by mistake (extras.jsonl); if it ever does, they count.
		w: Emoji_Wrapper
		read_line(s, line, &w, a) or_return
		append(&s.emoji, w.emoji)
	case .Direct_Channel:
		w: Direct_Channel_Wrapper
		read_line(s, line, &w, a) or_return
		scan_direct_channel(s, w.direct_channel, a)
	case .Direct_Post:
		w: Direct_Post_Wrapper
		read_line(s, line, &w, scratch) or_return
		scan_direct_post(s, w.direct_post, at, len(line), a)
	case:
		note(s, .Unknown_Line, string(line[:min(len(line), 40)]), a)
	}
	return true
}

// note counts an issue, and keeps the first few examples of it.
note :: proc(s: ^Scan, kind: Issue_Kind, example: string, a: Allocator) {
	i := &s.issues[kind]
	i.count += 1
	if len(i.examples) < EXAMPLES {
		append(&i.examples, strings.clone(example, a))
	}
}

// note_once is note for a name, which is only counted the first time.
note_once :: proc(s: ^Scan, kind: Issue_Kind, name: string, a: Allocator) -> (first: bool) {
	key := fmt.tprintf("%d:%s", int(kind), name)
	if key in s.reported {
		return false
	}
	s.reported[strings.clone(key, a)] = true
	note(s, kind, name, a)
	return true
}

@(private = "file")
scan_user :: proc(s: ^Scan, u: User) {
	a := virtual.arena_allocator(&s.arena)
	u := u
	if u.username in s.user_index || u.username in s.bot_index {
		note(s, .Duplicate_User, u.username, a)
		return
	}
	// Only the chosen team's memberships are kept.
	for t in u.teams {
		if t.name == s.team {
			kept := make([]Team_Member, 1, a)
			kept[0] = t
			u.teams = kept
			s.members[u.username] = true
			break
		}
	}
	if !s.members[u.username] {
		u.teams = nil
	}
	s.user_index[u.username] = len(s.users)
	append(&s.users, u)
}

// imported says whether an account of this name is made by the import: the
// team's members and all bots.
imported :: proc(s: ^Scan, username: string) -> bool {
	return s.members[username] || username in s.bot_index
}

// check_author notes who wrote something if they aren't an imported account.
@(private = "file")
check_author :: proc(s: ^Scan, username: string, a: Allocator) {
	switch {
	case imported(s, username):
	case username in s.user_index:
		if note_once(s, .Author_Not_Member, username, a) {
			append(&s.authors_only, strings.clone(username, a))
		}
	case:
		if note_once(s, .Author_Unknown, username, a) {
			append(&s.authors_gone, strings.clone(username, a))
		}
	}
}

// count_reaction_name counts a reaction of the emoji called `name`.
@(private = "file")
count_reaction_name :: proc(s: ^Scan, name: string, a: Allocator) {
	if name in s.stats.reaction_names {
		s.stats.reaction_names[name] += 1
	} else {
		s.stats.reaction_names[strings.clone(name, a)] = 1
	}
}

// count_text_tokens counts the `:name:` in a text, which is how many times each
// name that could be an emoji was used in messages. It decides which custom
// emoji are the most used when there are more than a server can have.
@(private = "file")
count_text_tokens :: proc(s: ^Scan, text: string, a: Allocator) {
	counts := &s.stats.text_tokens
	i := 0
	for i < len(text) {
		if text[i] != ':' {
			i += 1
			continue
		}
		j := i + 1
		letter := false
		for j < len(text) {
			c := text[j]
			is_letter := c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z'
			if !is_letter && !(c >= '0' && c <= '9' || c == '_' || c == '-' || c == '+') {
				break
			}
			letter ||= is_letter
			j += 1
		}
		// A name closed by a colon, which then may start the next one.
		if j < len(text) &&
		   text[j] == ':' &&
		   letter &&
		   j - i - 1 >= proto.MIN_EMOJI_NAME &&
		   j - i - 1 <= proto.MAX_EMOJI_NAME {
			name := text[i + 1:j]
			if name in counts^ {
				counts[name] += 1
			} else if len(counts^) < MAX_TOKENS {
				counts[strings.clone(name, a)] = 1
			}
			i = j
		} else {
			i = max(j, i + 1)
		}
	}
}

// How many different `:names:` are counted, at most.
MAX_TOKENS :: 200_000

// count_post adds a post's (or reply's) fields to the statistics.
@(private = "file")
count_post :: proc(
	s: ^Scan,
	type: string,
	message: string,
	create_at, edit_at: i64,
	pinned: bool,
	flagged_by: []string,
	reactions: []Reaction,
	attachments: []Attachment,
	a: Allocator,
) {
	st := &s.stats
	if type != "" {
		st.by_type[strings.clone(type, a) if type not_in st.by_type else type] += 1
		if strings.has_prefix(type, "system_") {
			st.system += 1
		}
	}
	st.pinned += int(pinned)
	st.edited += int(edit_at != 0)
	st.saved += len(flagged_by)
	st.reactions += len(reactions)
	for r in reactions {
		count_reaction_name(s, r.emoji_name, a)
	}
	st.attachments += len(attachments)
	count_text_tokens(s, message, a)
	if st.first_time == 0 || create_at < st.first_time {
		st.first_time = create_at
	}
	st.last_time = max(st.last_time, create_at)
}

@(private = "file")
scan_post :: proc(s: ^Scan, p: Post, at: i64, length: int, a: Allocator) {
	count := 1 + len(p.replies)
	if p.team != s.team {
		s.stats.posts_other_teams += count
		return
	}
	conv, found := s.channel_index[p.channel]
	if !found {
		for _ in 0 ..< count {
			note(s, .Post_Channel_Unknown, p.channel, a)
		}
		return
	}
	s.stats.posts += count
	s.stats.replies += len(p.replies)
	check_author(s, p.user, a)
	count_post(
		s,
		p.type,
		p.message,
		p.create_at,
		p.edit_at,
		p.is_pinned,
		p.flagged_by,
		p.reactions,
		p.attachments,
		a,
	)
	for f in p.attachments {
		check_file(s, f.path, .Attachment_Missing, a)
	}
	note_privacy_change(s, p.type, p.message, conv, p.create_at, a)
	note_hook(s, p.props, a)
	append(&s.posts, Post_Ref{p.create_at, at, i32(length), -1, i32(conv), false})
	for r, i in p.replies {
		check_author(s, r.user, a)
		note_hook(s, r.props, a)
		count_post(
			s,
			r.type,
			r.message,
			r.create_at,
			r.edit_at,
			r.is_pinned,
			r.flagged_by,
			r.reactions,
			r.attachments,
			a,
		)
		for f in r.attachments {
			check_file(s, f.path, .Attachment_Missing, a)
		}
		append(
			&s.posts,
			Post_Ref{max(r.create_at, p.create_at), at, i32(length), i32(i), i32(conv), false},
		)
	}
}

// direct_key names a direct channel by its members: their usernames, sorted,
// each once, so that a DM with oneself is just that one name.
direct_key :: proc(usernames: []string, allocator := context.temp_allocator) -> string {
	names := slice.clone(usernames, context.temp_allocator)
	slice.sort(names)
	unique := make([dynamic]string, 0, len(names), context.temp_allocator)
	for n in names {
		if len(unique) == 0 || unique[len(unique) - 1] != n {
			append(&unique, n)
		}
	}
	return strings.join(unique[:], ",", allocator)
}

@(private = "file")
scan_direct_channel :: proc(s: ^Scan, d: Direct_Channel, a: Allocator) {
	names := make([]string, len(d.participants), context.temp_allocator)
	all_imported := true
	for p, i in d.participants {
		names[i] = p.username
		all_imported &&= imported(s, p.username)
	}
	key := direct_key(names, a)
	if all_imported && strings.count(key, ",") + 1 > proto.MAX_GROUP_MEMBERS {
		s.directs_left += 1
		s.left_out[key] = true
		note(s, .Group_Too_Big, key, a)
		return
	}
	if !all_imported {
		s.directs_left += 1
		s.left_out[key] = true
		note(s, .Direct_Member_Gone, key, a)
		return
	}
	s.direct_index[key] = len(s.directs)
	append(&s.directs, d)
}

@(private = "file")
scan_direct_post :: proc(s: ^Scan, p: Direct_Post, at: i64, length: int, a: Allocator) {
	count := 1 + len(p.replies)
	key := direct_key(p.channel_members)
	conv, found := s.direct_index[key]
	if !found {
		if key in s.left_out {
			s.stats.direct_posts_left_out += count
		} else {
			note(s, .Direct_Channel_Unknown, key, a)
		}
		return
	}
	s.stats.direct_posts += count
	s.stats.replies += len(p.replies)
	check_author(s, p.user, a)
	count_post(
		s,
		p.type,
		p.message,
		p.create_at,
		p.edit_at,
		p.is_pinned,
		p.flagged_by,
		p.reactions,
		p.attachments,
		a,
	)
	for f in p.attachments {
		check_file(s, f.path, .Attachment_Missing, a)
	}
	append(&s.posts, Post_Ref{p.create_at, at, i32(length), -1, i32(conv), true})
	for r, i in p.replies {
		check_author(s, r.user, a)
		count_post(
			s,
			r.type,
			r.message,
			r.create_at,
			r.edit_at,
			r.is_pinned,
			r.flagged_by,
			r.reactions,
			r.attachments,
			a,
		)
		for f in r.attachments {
			check_file(s, f.path, .Attachment_Missing, a)
		}
		append(
			&s.posts,
			Post_Ref{max(r.create_at, p.create_at), at, i32(length), i32(i), i32(conv), true},
		)
	}
}

// scan_extra_reactions counts the reactions that extras.jsonl adds to the first
// post of a direct channel.
@(private = "file")
scan_extra_reactions :: proc(s: ^Scan, r: Direct_Post_Reactions) {
	a := virtual.arena_allocator(&s.arena)
	key := direct_key(r.channel_members)
	if key not_in s.direct_index && key not_in s.left_out {
		note(s, .Reactions_Channel_Unknown, key, a)
		return
	}
	if key in s.direct_index {
		s.stats.extra_reactions_posts += 1
		s.stats.reactions += len(r.reactions)
		for x in r.reactions {
			count_reaction_name(s, x.emoji_name, a)
		}
		// Kept for the post that they belong to (see extra_key).
		kept := make([]Reaction, len(r.reactions), a)
		for x, i in r.reactions {
			kept[i] = {strings.clone(x.user, a), strings.clone(x.emoji_name, a), x.create_at}
		}
		s.extra_reactions[strings.clone(extra_key(key, r.user, r.create_at), a)] = kept
	}
}

// extra_key names a direct channel's first post, which the export gives no
// reactions, as extras.jsonl does: the channel's key (direct_key), who wrote it
// and when.
extra_key :: proc(direct: string, user: string, create_at: i64) -> string {
	return fmt.tprintf("%s|%s|%d", direct, user, create_at)
}

// check_file notes a file that `path` names (relative to data/) if it isn't there.
@(private = "file")
check_file :: proc(s: ^Scan, path: string, kind: Issue_Kind, a: Allocator) {
	full, inside := data_file(s.dir, path)
	if !inside || !os.exists(full) {
		note(s, kind, path, a)
	}
}

// scan_check_files looks for the profile pictures and emoji images, once the
// whole export is read.
@(private = "file")
scan_check_files :: proc(s: ^Scan) {
	a := virtual.arena_allocator(&s.arena)
	for u in s.users {
		if u.profile_image != "" && imported(s, u.username) {
			check_file(s, u.profile_image, .Profile_Image_Missing, a)
		}
	}
	for b in s.bots {
		if b.profile_image != "" {
			check_file(s, b.profile_image, .Profile_Image_Missing, a)
		}
	}
	for e in s.emoji {
		append(&s.emoji_files, check_emoji_file(s, e, a))
	}
}

// Emoji_File is a custom emoji's picture, as it can be put in the server's
// emoji folder.
Emoji_File :: struct {
	ok:      bool, // it can be
	ext:     string, // the folder's file name extension: .png, .webp or .gif
	convert: bool, // it has to be made a PNG first (it is a JPEG or a BMP)
}

// The most that a server reads of an emoji's picture (server/emoji.odin).
MAX_EMOJI_FILE :: 1024 * 1024

@(private = "file")
check_emoji_file :: proc(s: ^Scan, e: Emoji, a: Allocator) -> (f: Emoji_File) {
	if e.image == "" {
		return
	}
	path, inside := data_file(s.dir, e.image)
	if !inside || !os.exists(path) {
		note(s, .Emoji_Image_Missing, e.image, a)
		return
	}
	data, err := os.read_entire_file(path, context.temp_allocator)
	switch {
	case err != nil:
		note(s, .Emoji_Unusable, fmt.tprintf("%s: can't be read", e.name), a)
		return
	case len(data) > MAX_EMOJI_FILE:
		note(s, .Emoji_Unusable, fmt.tprintf("%s: %d bytes, over 1 MB", e.name, len(data)), a)
		return
	}
	switch imagekind.kind_of(data) {
	case .PNG:
		return {true, ".png", false}
	case .WebP:
		return {true, ".webp", false}
	case .GIF:
		return {true, ".gif", false}
	case .JPEG:
		return {true, ".png", true}
	case .Unknown:
	}
	note(s, .Emoji_Unusable, fmt.tprintf("%s: not a picture yap reads", e.name), a)
	return
}

// Privacy_Change is a post that says a channel was made private or public.
Privacy_Change :: struct {
	channel: int, // an index into Scan.channels
	time:    i64,
	known:   bool, // the post's text says which way
	private: bool, // made private (if known)
}

Privacy_Key :: struct {
	channel: int,
	time:    i64,
}

@(private = "file")
note_privacy_change :: proc(
	s: ^Scan,
	type, message: string,
	channel: int,
	time: i64,
	a: Allocator,
) {
	if type != "system_change_chan_privacy" {
		return
	}
	change := Privacy_Change {
		channel = channel,
		time    = time,
	}
	switch {
	case strings.contains(message, "Private Channel"):
		change.known, change.private = true, true
	case strings.contains(message, "Public Channel"):
		change.known = true
	}
	append(&s.privacy, change)
}

// resolve_privacy_changes works out which way each change of privacy went. The
// post says so in the server's language, so it is only read in English; for a
// channel whose posts it can't read, the changes alternate, and the last one
// ended at the channel's type now: a private channel was last made private, the
// one before that public, and so on. A post that can be read keeps its own
// direction.
@(private = "file")
resolve_privacy_changes :: proc(s: ^Scan) {
	by_channel := make(map[int][dynamic]int, context.temp_allocator)
	for c, i in s.privacy {
		list := by_channel[c.channel]
		list.allocator = context.temp_allocator
		append(&list, i)
		by_channel[c.channel] = list
	}
	for channel, list in by_channel {
		changes := list[:]
		// In time order (the posts come in the order of the file, which isn't).
		for i in 1 ..< len(changes) {
			for j := i;
			    j > 0 && s.privacy[changes[j]].time < s.privacy[changes[j - 1]].time;
			    j -= 1 {
				changes[j], changes[j - 1] = changes[j - 1], changes[j]
			}
		}
		direction := s.channels[channel].type == "P" // the last change
		for k := len(changes) - 1; k >= 0; k -= 1 {
			c := s.privacy[changes[k]]
			if c.known {
				direction = c.private
			}
			s.privacy_dir[{channel, c.time}] = direction
			direction = !direction
		}
	}
}

// note_hook notes who made a post in a channel if it is an integration's: the
// webhook, so that it gets a bot, and the picture it poses with.
@(private = "file")
note_hook :: proc(s: ^Scan, props: json.Value, a: Allocator) {
	info := hook_info(props)
	if info.hook != "" {
		s.stats.webhook_posts += 1
		if info.hook not_in s.webhook_index {
			name := strings.clone(info.hook, a)
			s.webhook_index[name] = len(s.webhooks)
			append(&s.webhooks, name)
		}
	}
	if info.bot && info.name != "" {
		s.stats.bot_overrides += 1
	}
	if (info.hook != "" || info.bot) && info.icon != "" {
		if info.icon in s.icons {
			s.icons[info.icon] += 1
		} else {
			s.icons[strings.clone(info.icon, a)] = 1
		}
	}
	if object, ok := props.(json.Object); ok {
		if list, is_list := object["attachments"].(json.Array); is_list && len(list) > 0 {
			s.stats.cards += 1
		}
	}
}
