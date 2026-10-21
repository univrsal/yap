#+build !wasi
package client

import "core:testing"

@(test)
test_pager_window :: proc(t: ^testing.T) {
	p: Pager
	// An empty list and a short one are one page.
	lo, hi := pager_window(&p, 0)
	testing.expect(t, lo == 0 && hi == 0)
	lo, hi = pager_window(&p, 5)
	testing.expect(t, lo == 0 && hi == 5)
	// The last page has what is left.
	p.page = 2
	lo, hi = pager_window(&p, 2 * PAGE_ROWS + 3)
	testing.expect(t, lo == 2 * PAGE_ROWS && hi == 2 * PAGE_ROWS + 3)
	// A page past the end (the list got shorter) becomes the last one.
	p.page = 9
	lo, hi = pager_window(&p, PAGE_ROWS + 1)
	testing.expect_value(t, p.page, 1)
	testing.expect(t, lo == PAGE_ROWS && hi == PAGE_ROWS + 1)
	p.page = -1
	pager_window(&p, 10)
	testing.expect_value(t, p.page, 0)

	pager_page_of(&p, PAGE_ROWS)
	testing.expect_value(t, p.page, 1)
	pager_page_of(&p, PAGE_ROWS - 1)
	testing.expect_value(t, p.page, 0)
}

@(test)
test_pager_matches :: proc(t: ^testing.T) {
	testing.expect(t, pager_matches("", "anything"))
	testing.expect(t, pager_matches(""))
	testing.expect(t, pager_matches("gam", "Lobby", "GAMING"))
	testing.expect(t, pager_matches("Music", "Lounge", "all about music"))
	testing.expect(t, !pager_matches("music", "Lounge", ""))
	testing.expect(t, !pager_matches("x"))
}
