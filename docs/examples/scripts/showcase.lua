-- A script that uses everything the Scripts page can show, for trying it out.
-- Put it in <config folder>/yap/scripts/ (or paste it into "Add a script"), press
-- Reload, open "Showcase" on the Scripts page and switch it on.
--
-- What to look for:
--   * the page lists its name, description, version and author, and asks for two
--     permissions before it runs;
--   * the settings below are drawn from get_info: a checkbox, a slider (int), a
--     slider (number), a plain number box (no range), two text boxes (one masked),
--     and a dropdown;
--   * /hello, /roll and /remind show up when you type "/" in the message box, and
--     in the command palette (Ctrl+K);
--   * /hello, /roll and /remind answer in the status text at the top of the chat
--     window (yap.status); a mention of you, and a reminder, come as a desktop
--     notification (yap.notify), the way the client's own mentions do;
--   * a message containing "darn" is shown with stars, and one containing "!spam"
--     is shown as "[hidden by a script]" (what other people send you: ask someone
--     to try it, or use a second client);
--   * a message you send that starts with "!shout " is sent in capitals, and one
--     containing "secret" is stopped, with a note in the status text;
--   * after editing this file, the page says it has changed and asks again.

function get_info()
  return {
    name = "Showcase",
    description = "Tries out everything the Scripts page can show: settings of every kind, commands, filters, notifications and a timer.",
    version = "1.0",
    author = "the yap examples",
    permissions = { "send", "notify" },
    settings = {
      { key = "announce", label = "Tell me when I am mentioned", type = "bool", default = true,
        description = "Shows a desktop notification for every message that mentions you." },
      { key = "censor", label = "Star out \"darn\"", type = "bool", default = true },
      { key = "dice", label = "Largest die for /roll", type = "int", default = 20, min = 2, max = 100,
        description = "An int with a range is a slider that takes whole numbers." },
      { key = "ratio", label = "Chance that /roll shows off", type = "number", default = 0.25, min = 0, max = 1,
        description = "A number with a range is a slider too." },
      { key = "threshold", label = "Longest message to read out (characters)", type = "number", default = 200,
        description = "Without a range it is a text box: type a number and press Enter." },
      { key = "greeting", label = "Greeting for /hello", type = "string", default = "Hello", max_length = 40 },
      { key = "token", label = "A secret", type = "string", secret = true, default = "",
        description = "Shown as dots; the script never uses it." },
      { key = "mood", label = "Mood", type = "choice", default = "calm", choices = { "calm", "cheerful", "grumpy" } },
    },
  }
end

local function setting(key) return yap.setting(key) end

function on_load(ev)
  yap.log("Showcase loaded; greeting is", setting("greeting"), "and mood is", setting("mood"))
end

function on_setting(ev)
  yap.log("Showcase: " .. ev.key .. " is now " .. tostring(ev.value))
end

-- A desktop notification for a mention.
function on_message(ev)
  if ev.mine or not ev.mentions_me or not setting("announce") then return end
  local text = ev.text
  if #text > setting("threshold") then text = text:sub(1, setting("threshold")) .. "..." end
  yap.notify("Mentioned by " .. ev.author .. " in " .. ev.channel, text)
end

-- What other people send is changed on its way to the screen.
function on_incoming(ev)
  if ev.text:find("!spam", 1, true) then return false end
  if setting("censor") and ev.text:lower():find("darn", 1, true) then
    return (ev.text:gsub("[Dd][Aa][Rr][Nn]", "****"))
  end
end

-- And what you send, before it goes.
function on_send(ev)
  if ev.text:find("secret", 1, true) then return false end
  local shout = ev.text:match("^!shout%s+(.+)$")
  if shout then return shout:upper() end
end

-- Commands, typed with a slash.
yap.register_command("hello", "Show a greeting in the status text", function(ev)
  local mood = setting("mood")
  local mark = ({ calm = ".", cheerful = "!", grumpy = "..." })[mood] or "."
  local who = ev.args ~= "" and ev.args or "there"
  yap.status(setting("greeting") .. ", " .. who .. mark .. " (" .. mood .. ", " .. ev.server.address .. ")")
end)

yap.register_command("roll", "Roll dice in this channel, like /roll 2d6", function(ev)
  local n, sides = ev.args:match("^(%d+)d(%d+)$")
  n, sides = tonumber(n), tonumber(sides)
  if not n or n < 1 or n > 20 or sides < 2 or sides > setting("dice") then
    yap.status("/roll: say how many dice and sides, like 2d6 (up to 20 dice, " .. setting("dice") .. " sides).")
    return
  end
  if ev.channel == "" then
    yap.status("/roll: open a channel first: rolls are posted there.")
    return
  end
  local total, rolls = 0, {}
  for i = 1, n do
    local r = math.random(sides)
    total = total + r
    rolls[i] = r
  end
  local line = ev.args .. ": " .. table.concat(rolls, " + ") .. " = " .. total
  if math.random() < setting("ratio") then line = line .. " (of course)" end
  yap.send(ev.channel, line)
end)

yap.register_command("remind", "Remind me after some seconds, like /remind 10 tea", function(ev)
  local seconds, what = ev.args:match("^(%d+)%s*(.*)$")
  seconds = tonumber(seconds)
  if not seconds or seconds < 1 or seconds > 3600 then
    yap.status("/remind: say how many seconds (1 to 3600) and what for, like /remind 10 tea")
    return
  end
  yap.store.set("reminder", what ~= "" and what or "(nothing in particular)")
  yap.timer("reminder", seconds)
  yap.status("Reminding you in " .. seconds .. " seconds.")
end)

function on_timer(ev)
  if ev.name == "reminder" then
    yap.notify("Reminder", yap.store.get("reminder") or "")
  end
end
