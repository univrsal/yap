-- Shows a notice when a message contains one of your keywords.
--
-- Switch it on in Settings > Scripts, then change "Keywords" there (comma separated;
-- upper or lower case does not matter). Messages you wrote yourself are left out.

function get_info()
  return {
    name = "Keywords",
    description = "Shows a notice when a message contains one of your keywords.",
    version = "1.0",
    author = "the yap examples",
    permissions = { "notify" },
    settings = {
      { key = "words", label = "Keywords", type = "string", default = "yap, lua",
        description = "Separated by commas." },
      { key = "where", label = "Where", type = "choice", default = "everywhere",
        choices = { "everywhere", "channels only", "direct messages only" } },
    },
  }
end

local function keywords()
  local list = {}
  for word in yap.setting("words"):gmatch("[^,]+") do
    word = word:match("^%s*(.-)%s*$"):lower()
    if word ~= "" then list[#list + 1] = word end
  end
  return list
end

function on_message(ev)
  if ev.mine or ev.type ~= "text" then return end
  local where = yap.setting("where")
  if where == "channels only" and ev.kind ~= "channel" then return end
  if where == "direct messages only" and ev.kind == "channel" then return end
  local text = ev.text:lower()
  for _, word in ipairs(keywords()) do
    if text:find(word, 1, true) then
      yap.notify(ev.author .. " said \"" .. word .. "\" in " .. ev.channel, ev.text)
      return
    end
  end
end
