package mattermost

import "core:encoding/json"
import "core:mem/virtual"
import "core:testing"

@(private = "file")
props_of :: proc(a: ^virtual.Arena, text: string) -> json.Value {
	_ = virtual.arena_init_growing(a)
	v, _ := json.parse(transmute([]u8)text, allocator = virtual.arena_allocator(a))
	return v
}

@(test)
test_hook_info :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	cases := []struct {
		props: string,
		want:  Hook_Info,
	} {


		// The sample's: a webhook posing as Jenkins, and a bot posing as Nightly.
		{
			`{"from_webhook":"true","override_icon_url":"https://example.invalid/jenkins.png","override_username":"Jenkins","webhook_display_name":"CI hook"}`,
			{hook = "CI hook", name = "Jenkins", icon = "https://example.invalid/jenkins.png"},
		},
		{`{"from_bot":"true","override_username":"Nightly"}`, {name = "Nightly", bot = true}},
		// A webhook without its name (older versions) is named after what it poses as, and one with neither has no hook.
		{
			`{"from_webhook":"true","override_username":"Grafana"}`,
			{hook = "Grafana", name = "Grafana"},
		},
		{`{"from_webhook":"true"}`, {}},
		{`{"from_webhook":true,"webhook_display_name":" Alerts "}`, {hook = "Alerts"}},
		// Not a webhook: a person's post, a bot's without an override, and props that aren't an object.
		{`{"override_username":"bob"}`, {name = "bob"}},
		{`{"from_bot":"true"}`, {bot = true}},
		{`{"from_webhook":"false","webhook_display_name":"x"}`, {}},
		{`[]`, {}},
		{`null`, {}},
		{`{"from_webhook":5,"override_username":7}`, {}},
	}
	for c in cases {
		got := hook_info(props_of(&arena, c.props))
		testing.expectf(t, got == c.want, "%s: %v, not %v", c.props, got, c.want)
	}
	testing.expect_value(t, hook_info(nil), Hook_Info{})
}

@(test)
test_card_text :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	cases := []struct {
		props, want: string,
	} {


		// The sample's card.
		{
			`{"attachments":[{"color":"#36a64f","fallback":"Deploy of web 1.2.3 finished","fields":[{"short":true,"title":"Env","value":"staging"}],"pretext":"Deploy report","text":"Everything went *fine*","title":"web 1.2.3","title_link":"https://example.invalid/deploys/123","ts":null}]}`,
			"> Deploy report\n> [web 1.2.3](https://example.invalid/deploys/123)\n> Everything went *fine*\n> - **Env**: staging",
		},
		// A title without a link, an author, several fields (one without a title, one a number), a picture and a footer.
		{
			`{"attachments":[{"author_name":"Ann","author_link":"https://a.example","title":"T","fields":[{"title":"A","value":"1"},{"value":"only value"},{"title":"N","value":42},{"title":"empty","value":""}],"image_url":"https://x.example/i.png","footer":"nightly"}]}`,
			"> [Ann](https://a.example)\n> **T**\n> - **A**: 1\n> - only value\n> - **N**: 42\n> [image](https://x.example/i.png)\n> _nightly_",
		},
		// Lines of a text are each quoted, and the cards are apart.
		{
			`{"attachments":[{"text":"one\ntwo"},{"title":"second"}]}`,
			"> one\n> two\n\n> **second**",
		},
		// The fallback only when there is nothing else, and nothing from an empty card.
		{`{"attachments":[{"fallback":"plain version"}]}`, "> plain version"},
		{`{"attachments":[{"fallback":"x","text":"shown"}]}`, "> shown"},
		{`{"attachments":[{}, 5, {"color":"#fff"}]}`, ""},
		// No cards.
		{`{"attachments":[]}`, ""},
		{`{"attachments":"nope"}`, ""},
		{`{"from_bot":"true"}`, ""},
		{`null`, ""},
	}
	for c in cases {
		got := card_text(props_of(&arena, c.props))
		testing.expectf(t, got == c.want, "%s:\n%q\nnot %q", c.props, got, c.want)
	}
	// The text and the cards together.
	cards := props_of(&arena, `{"attachments":[{"title":"T"}]}`)
	testing.expect_value(t, with_cards("Deploy finished", cards), "Deploy finished\n\n> **T**")
	testing.expect_value(t, with_cards("", cards), "> **T**")
	testing.expect_value(t, with_cards("  \n", cards), "> **T**")
	testing.expect_value(t, with_cards("just text", nil), "just text")
}
