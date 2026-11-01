-- Sends the messages that mention you to a web address (a webhook), as JSON:
--   {"server":"...","channel":"...","author":"...","text":"..."}
--
-- Put the address in "Webhook" (it is hidden on the page, but kept in plain text in
-- the settings file). Needs the "net" permission. A message is sent once, when it
-- arrives; if the request fails, the script writes why to the log and goes on.

function get_info()
  return {
    name = "Mention webhook",
    description = "Sends messages that mention you to a web address.",
    version = "1.0",
    author = "the yap examples",
    permissions = { "net" },
    settings = {
      { key = "url", label = "Webhook", type = "string", secret = true, default = "", max_length = 500,
        description = "An http or https address. Empty: nothing is sent." },
    },
  }
end

local function quote(text)
  return '"' .. text:gsub('[%c"\\]', function(c)
    local special = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
    return special[c] or string.format("\\u%04x", c:byte())
  end) .. '"'
end

function on_message(ev)
  local url = yap.setting("url")
  if ev.mine or not ev.mentions_me or url == "" then return end
  local body = string.format('{"server":%s,"channel":%s,"author":%s,"text":%s}',
    quote(ev.server.address), quote(ev.channel), quote(ev.author), quote(ev.text))
  yap.http_post(url, body, function(answer)
    if not answer.ok then
      yap.log("webhook failed: " .. answer.error)
    elseif answer.status >= 300 then
      yap.log("webhook answered " .. answer.status)
    end
  end, { content_type = "application/json", timeout = 10 })
end
