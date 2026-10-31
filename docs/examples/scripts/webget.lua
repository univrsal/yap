-- Web requests from a script: /get and /post, and what to look for when they fail.
--
-- The answers come in the status text at the top of the chat window (yap.status).
-- Needs the "net" permission, which the page asks about when you switch it on. On
-- Linux, requests go through libcurl, which the client looks for when it starts: the
-- Scripts page says whether it was found. In a browser they are made by the page, so
-- only servers that allow it (CORS) can be asked.
--
--   /get https://example.com        shows the status and the start of the answer
--   /post https://httpbin.org/post hello   sends "hello" as text, and shows the answer
--
-- Try them with a wrong address, a server that isn't there, and a very large file:
-- the script is told ("ok" is false and "error" says why) instead of anything hanging.

function get_info()
  return {
    name = "Web get",
    description = "Fetches an address and shows the start of the answer, to try web requests.",
    version = "1.0",
    author = "the yap examples",
    permissions = { "notify", "net" },
    settings = {
      { key = "limit", label = "Characters to show", type = "int", default = 120, min = 20, max = 500 },
      { key = "timeout", label = "Give up after (seconds)", type = "number", default = 5, min = 1, max = 30 },
      { key = "agent", label = "User agent", type = "string", default = "yap-script" },
    },
  }
end

local function show(title, r)
  if not r.ok then
    yap.status(title .. " failed: " .. r.error)
    yap.store.set("last", "failed: " .. r.error)
    return
  end
  local text = (r.body:sub(1, yap.setting("limit")):gsub("%s+", " "))
  yap.status(title .. " -> " .. r.status .. ": " .. text)
  yap.store.set("last", r.status .. " " .. text)
end

local function options()
  return { timeout = yap.setting("timeout"), headers = { ["User-Agent"] = yap.setting("agent") } }
end

yap.register_command("get", "Fetch an address, like /get https://example.com", function(ev)
  if ev.args == "" then
    yap.status("/get: say which address, like /get https://example.com")
    return
  end
  yap.http_get(ev.args, function(r) show("/get", r) end, options())
end)

yap.register_command("post", "Send text to an address, like /post https://httpbin.org/post hello", function(ev)
  local url, text = ev.args:match("^(%S+)%s+(.+)$")
  if not url then
    yap.status("/post: say which address and what to send, like /post https://httpbin.org/post hello")
    return
  end
  local o = options()
  o.content_type = "text/plain"
  yap.http_post(url, text, function(r) show("/post", r) end, o)
end)
