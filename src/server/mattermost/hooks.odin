package mattermost

import "core:encoding/json"
import "core:strings"

// Integrations (docs/design/mattermost-import.md, step 10): the posts of bots
// and webhooks, which name who they pose as (`override_username` and
// `override_icon_url`) and often have the content in cards
// (`props.attachments`) instead of in the text.

// Hook_Info is what a post's props say about who made it.
Hook_Info :: struct {
	hook: string, // the name of the webhook that made it ("CI hook"), or "" if none
	name: string, // the name it poses under (override_username), or ""
	icon: string, // the picture's address it poses with (override_icon_url), or ""
	bot:  bool, // it was made by a bot (from_bot)
}

// hook_info reads who made a post from its props. A webhook's posts say the
// hook's name; one without it (older versions of Mattermost didn't, it isn't
// known) is named after the name it poses under, and one with neither has no
// hook and stays with its author. The strings point into `props`.
hook_info :: proc(props: json.Value) -> (info: Hook_Info) {
	obj, is_object := props.(json.Object)
	if !is_object {
		return
	}
	info.name = strings.trim_space(prop_string(obj, "override_username"))
	info.icon = strings.trim_space(prop_string(obj, "override_icon_url"))
	info.bot = prop_true(obj, "from_bot")
	if prop_true(obj, "from_webhook") {
		info.hook = strings.trim_space(prop_string(obj, "webhook_display_name"))
		if info.hook == "" {
			info.hook = info.name
		}
	}
	return
}

// prop_string returns a prop that is a string, or "".
prop_string :: proc(obj: json.Object, key: string) -> string {
	if v, there := obj[key]; there {
		if s, is_string := v.(json.String); is_string {
			return s
		}
	}
	return ""
}

// prop_true says whether a prop is "true" (Mattermost writes its flags as
// strings) or true.
@(private = "file")
prop_true :: proc(obj: json.Object, key: string) -> bool {
	v, there := obj[key]
	if !there {
		return false
	}
	#partial switch x in v {
	case json.String:
		return x == "true"
	case json.Boolean:
		return bool(x)
	}
	return false
}

// card_text writes the cards of a post (`props.attachments`) as Markdown, which
// yap shows: for each card the lines it has (what it says before, who it is
// from, the title in bold (a link, if it has one, is only the link: yap doesn't
// put bold around one), its text, its fields as a list, a picture's address
// and the footer), the whole of it a quote so that it stands apart from the
// message. A colour and a time are left out. It is "" if the post has no card.
// The result is allocated with `allocator`.
card_text :: proc(props: json.Value, allocator := context.temp_allocator) -> string {
	obj, is_object := props.(json.Object)
	if !is_object {
		return ""
	}
	cards, is_array := obj["attachments"].(json.Array)
	if !is_array {
		return ""
	}
	b: strings.Builder
	strings.builder_init(&b, allocator)
	for card in cards {
		c, is_card := card.(json.Object)
		if !is_card {
			continue
		}
		lines := make([dynamic]string, context.temp_allocator)
		add :: proc(lines: ^[dynamic]string, text: string) {
			if t := strings.trim_space(text); t != "" {
				append(lines, t)
			}
		}
		add(&lines, prop_string(c, "pretext"))
		if author := strings.trim_space(prop_string(c, "author_name")); author != "" {
			link := strings.trim_space(prop_string(c, "author_link"))
			add(
				&lines,
				strings.concatenate({"[", author, "](", link, ")"}, context.temp_allocator) if link != "" else strings.concatenate({"**", author, "**"}, context.temp_allocator),
			)
		}
		if title := strings.trim_space(prop_string(c, "title")); title != "" {
			link := strings.trim_space(prop_string(c, "title_link"))
			add(
				&lines,
				strings.concatenate({"[", title, "](", link, ")"}, context.temp_allocator) if link != "" else strings.concatenate({"**", title, "**"}, context.temp_allocator),
			)
		}
		add(&lines, prop_string(c, "text"))
		if fields, has_fields := c["fields"].(json.Array); has_fields {
			for f in fields {
				field, is_field := f.(json.Object)
				if !is_field {
					continue
				}
				title := strings.trim_space(prop_string(field, "title"))
				value := strings.trim_space(field_value(field))
				switch {
				case title != "" && value != "":
					add(
						&lines,
						strings.concatenate(
							{"- **", title, "**: ", value},
							context.temp_allocator,
						),
					)
				case value != "":
					add(&lines, strings.concatenate({"- ", value}, context.temp_allocator))
				}
			}
		}
		if image := strings.trim_space(prop_string(c, "image_url")); image != "" {
			add(&lines, strings.concatenate({"[image](", image, ")"}, context.temp_allocator))
		}
		if footer := strings.trim_space(prop_string(c, "footer")); footer != "" {
			add(&lines, strings.concatenate({"_", footer, "_"}, context.temp_allocator))
		}
		if len(lines) == 0 {
			add(&lines, prop_string(c, "fallback"))
		}
		if len(lines) == 0 {
			continue
		}
		if strings.builder_len(b) > 0 {
			strings.write_string(&b, "\n\n")
		}
		for line, i in lines {
			if i > 0 {
				strings.write_string(&b, "\n")
			}
			// A quote, line by line (a line of the text may have lines of its own).
			rest := line
			first := true
			for part in strings.split_lines_iterator(&rest) {
				if !first {
					strings.write_string(&b, "\n")
				}
				first = false
				strings.write_string(&b, "> ")
				strings.write_string(&b, part)
			}
		}
	}
	return strings.to_string(b)
}

// field_value returns a field's value, which Mattermost allows to be any JSON
// value but nearly always is a string.
@(private = "file")
field_value :: proc(field: json.Object) -> string {
	v, there := field["value"]
	if !there {
		return ""
	}
	#partial switch x in v {
	case json.String:
		return x
	case json.Integer:
		return strings.clone(json_number(f64(x)), context.temp_allocator)
	case json.Float:
		return strings.clone(json_number(f64(x)), context.temp_allocator)
	}
	return ""
}

@(private = "file")
json_number :: proc(n: f64) -> string {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	whole := i64(n)
	if f64(whole) == n {
		strings.write_i64(&b, whole)
	} else {
		strings.write_f64(&b, n, 'g')
	}
	return strings.to_string(b)
}

// with_cards returns a post's text followed by its cards, a blank line between.
with_cards :: proc(
	message: string,
	props: json.Value,
	allocator := context.temp_allocator,
) -> string {
	cards := card_text(props, allocator)
	switch {
	case cards == "":
		return message
	case strings.trim_space(message) == "":
		return cards
	}
	return strings.concatenate({message, "\n\n", cards}, allocator)
}
