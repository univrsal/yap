-- Answers the first time somebody mentions you while you are away.
--
-- Switch "I am away" on and off here. Each person gets the reply once in the number
-- of minutes you choose, so a busy channel is not answered over and over. The
-- script keeps who it has answered (yap.store), which survives restarts.

function get_info()
  return {
    name = "Away reply",
    description = "Answers the first mention while you are away.",
    version = "1.0",
    author = "the yap examples",
    permissions = { "send" },
    settings = {
      { key = "away", label = "I am away", type = "bool", default = false },
      { key = "reply", label = "Reply", type = "string", default = "I am away right now and will answer later.",
        max_length = 200 },
      { key = "minutes", label = "Answer each person once in (minutes)", type = "int", default = 30, min = 1, max = 1440 },
    },
  }
end

function on_message(ev)
  if ev.mine or not ev.mentions_me or ev.kind ~= "channel" or not yap.setting("away") then return end
  local key = "answered:" .. ev.server.key .. ":" .. ev.author_id
  local now = ev.time // 1000
  local last = yap.store.get(key)
  if last and now - last < yap.setting("minutes") * 60 then return end
  yap.store.set(key, now)
  yap.send(ev.channel, "@" .. ev.username .. " " .. yap.setting("reply"))
end
