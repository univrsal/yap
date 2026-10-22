#+build !wasi
package client

import "core:testing"
import "core:time/datetime"

// The locale decides the order of the date, what is between its parts and the
// clock's hours.
@(test)
test_date_style_of :: proc(t: ^testing.T) {
	testing.expect_value(t, date_style_of(""), Date_Style{.DMY, '/', false})
	testing.expect_value(t, date_style_of("C"), Date_Style{.DMY, '/', false})
	testing.expect_value(t, date_style_of("en_US.UTF-8"), Date_Style{.MDY, '/', true})
	testing.expect_value(t, date_style_of("en-US"), Date_Style{.MDY, '/', true})
	testing.expect_value(t, date_style_of("en_GB.UTF-8"), Date_Style{.DMY, '/', false})
	testing.expect_value(t, date_style_of("en_AU"), Date_Style{.DMY, '/', true})
	testing.expect_value(t, date_style_of("de_DE.UTF-8@euro"), Date_Style{.DMY, '.', false})
	testing.expect_value(t, date_style_of("de"), Date_Style{.DMY, '.', false})
	testing.expect_value(t, date_style_of("ja-JP"), Date_Style{.YMD, '/', false})
	testing.expect_value(t, date_style_of("sv_SE"), Date_Style{.YMD, '-', false})
}

// Today's messages have only the time; older ones have the date in short first.
@(test)
test_date_time_text :: proc(t: ^testing.T) {
	late := datetime.DateTime {
		date = {year = 2026, month = 9, day = 30},
		time = {hour = 23, minute = 5},
	}
	morning := datetime.DateTime {
		date = {year = 2026, month = 1, day = 2},
		time = {hour = 0, minute = 7},
	}
	dmy := Date_Style{.DMY, '/', false}
	us := Date_Style{.MDY, '/', true}
	testing.expect_value(t, date_time_text(dmy, late, true), "23:05")
	testing.expect_value(t, date_time_text(dmy, late, false), "30/9/26 23:05")
	testing.expect_value(t, date_time_text(us, late, true), "11:05 PM")
	testing.expect_value(t, date_time_text(us, late, false), "9/30/26 11:05 PM")
	testing.expect_value(t, date_time_text(us, morning, true), "12:07 AM")
	testing.expect_value(
		t,
		date_time_text(Date_Style{.DMY, '.', false}, morning, false),
		"2.1.26 00:07",
	)
	testing.expect_value(
		t,
		date_time_text(Date_Style{.YMD, '-', false}, morning, false),
		"2026-1-2 00:07",
	)
}
