
-- lua/main.lua  (filesystem-only smoke test)
local r  = monotome.runtime
local w  = monotome.window
local d  = monotome.draw
local fs = monotome.filesystem

local BG  = {  8, 10, 16, 255 }
local TXT = { 210,230,255,255 }
local OK  = { 120,255,180,255 }
local BAD = { 255,120,120,255 }

local lines = {}
local function push(msg, good)
  lines[#lines + 1] = { msg = msg, good = good }
end

local function sep_char()
  if package and package.config then
    return package.config:sub(1, 1)
  end
  return "/"
end

local SEP = sep_char()
local function join(a, b)
  if a == "" then return b end
  if a:sub(-1) == SEP then return a .. b end
  return a .. SEP .. b
end

local function okret(label, a, b)
  if a == nil then
    push(label .. " -> nil: " .. tostring(b), false)
    return false
  end
  if a == false then
    push(label .. " -> false: " .. tostring(b), false)
    return false
  end
  push(label .. " -> OK", true)
  return true
end

local function run()
  -- basic getters
  local rd, rd_err = fs.resource_dir()
  if rd == nil then push("resource_dir() failed: " .. tostring(rd_err), false) else push("resource_dir(): " .. rd, true) end

  local wd, wd_err = fs.working_dir()
  if wd == nil then push("working_dir() failed: " .. tostring(wd_err), false) else push("working_dir(): " .. wd, true) end

  local args = fs.args() or {}
  push("args(): count=" .. tostring(#args) .. (args[1] and (" first=" .. tostring(args[1])) or ""), true)

  if wd == nil or wd == "" then
    push("ABORT: no working_dir()", false)
    return
  end

  -- sandbox paths
  local root = join(wd, "_monotome_fs_test")
  local a    = join(root, "a.txt")
  local b    = join(root, "b.txt")

  -- mkdir
  local mk_ok, mk_err = fs.mkdir(root)
  okret("mkdir(" .. root .. ")", mk_ok, mk_err)

  -- write (create)
  local wr_ok, wr_err = fs.write_file(a, "hello monotome\n")
  okret("write_file(a.txt)", wr_ok, wr_err)

  -- read
  local s, s_err = fs.read_file(a)
  if s == nil then
    push("read_file(a.txt) failed: " .. tostring(s_err), false)
  else
    local same = (s == "hello monotome\n")
    push("read_file(a.txt): len=" .. tostring(#s) .. " match=" .. tostring(same), same)
  end

  -- rename
  local rn_ok, rn_err = fs.rename(a, b)
  okret("rename(a->b)", rn_ok, rn_err)

  -- list_dir(root)
  local list, list_err = fs.list_dir(root)
  if list == nil then
    push("list_dir(root) failed: " .. tostring(list_err), false)
  else
    push("list_dir(root): count=" .. tostring(#list), true)
    local found = false
    for i = 1, #list do
      local e = list[i]
      if e and e.name == "b.txt" then
        found = true
        push("list contains b.txt kind=" .. tostring(e.kind), (e.kind == "file"))
        break
      end
    end
    if not found then push("list does not contain b.txt", false) end
  end

  -- info(b.txt)
  local inf, inf_err = fs.info(b)
  if inf == nil then
    push("info(b.txt) failed: " .. tostring(inf_err), false)
  else
    local k = tostring(inf.kind)
    local sz = tonumber(inf.size) or 0
    local mt = tonumber(inf.modified_time) or 0
    push("info(b.txt): kind=" .. k .. " size=" .. tostring(sz) .. " mtime=" .. tostring(mt),
         (k == "file" and sz > 0 and mt > 0))
  end

  -- cleanup
  local rm_ok, rm_err = fs.remove(b)
  okret("remove(b.txt)", rm_ok, rm_err)

  local rd_ok, rd_err2 = fs.remove(root)
  okret("remove(test_root)", rd_ok, rd_err2)
end

function r.init()
  w.init(900, 600, "monotome filesystem smoke test", { "resizable" })
  run()
end

function r.update(dt) end

function r.draw()
  d.clear(BG)
  d.text(2, 1, "FILESYSTEM SMOKE TEST", TXT, 2)

  local y = 3
  for i = 1, #lines do
    local ln = lines[i]
    d.text(2, y, ln.msg, ln.good and OK or BAD, 1)
    y = y + 1
  end
end


