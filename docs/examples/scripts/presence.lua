-- Shows a desktop notification when somebody comes online.
--
-- Leave "People" empty for everybody, or list usernames (comma separated) to hear
-- about only those. A person is "coming online" when they were offline and are now
-- online, not when they come back from away or busy.

function get_info()
  return {
    name = "Who is here",
    description = "Shows a desktop notification when somebody comes online.",
    version = "1.0",
    author = "the yap examples",
    permissions = { "notify" },
    settings = {
      { key = "people", label = "People", type = "string", default = "",
        description = "Usernames, separated by commas. Empty: everybody." },
      { key = "goes", label = "Also when they go offline", type = "bool", default = false },
    },
  }
end

local function wanted(username)
  local people = yap.setting("people")
  if people:match("^%s*$") then return true end
  for name in people:gmatch("[^,]+") do
    if name:match("^%s*(.-)%s*$"):lower() == username:lower() then return true end
  end
  return false
end

function on_presence(ev)
  if not wanted(ev.username) then return end
  if ev.state == "online" and ev.was == "offline" then
    yap.notify(ev.user .. " is online", "on " .. ev.server.address)
  elseif ev.state == "offline" and yap.setting("goes") then
    yap.notify(ev.user .. " went offline", "on " .. ev.server.address)
  end
end
