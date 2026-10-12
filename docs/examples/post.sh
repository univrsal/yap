#!/bin/sh
# Posting from a script (a cron job, CI) with nothing but curl, and a
# file with it.
#
#     YAP_URL=http://localhost:8080 YAP_TOKEN=yap_... ./post.sh 1 "Build 412 passed" [file]
#
# The first argument is the conversation's id (GET /api/v1/convs lists
# them; 1 is usually the home channel). curl 7.87 or later, for
# --url-query.
set -e
api="${YAP_URL:-http://localhost:8080}/api/v1"
auth="Authorization: Bot $YAP_TOKEN"
conv="$1"

# The text as a JSON string: backslashes, quotes, tabs and newlines
# escaped.
text=$(printf '%s' "$2" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' | awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }')

attachments=""
if [ -n "$3" ]; then
	# Uploaded first; the message names the upload by its id.
	upload=$(curl -sf -H "$auth" --data-binary "@$3" --url-query "name=$(basename "$3")" "$api/uploads" |
		sed 's/.*"id":"\([0-9]*\)".*/\1/')
	attachments=", \"attachments\": [\"$upload\"]"
fi

curl -sf -H "$auth" -H "Content-Type: application/json" \
	-d "{\"content\": \"$text\"$attachments}" "$api/convs/$conv/messages" |
	sed 's/^{"id":"\([0-9]*\)".*/posted message \1/'
