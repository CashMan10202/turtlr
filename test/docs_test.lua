local t = require("test.t")
local proto = require("lib.proto")

local T = {}

local function read(path)
  local f = io.open(path)
  if not f then return nil end
  local s = f:read("*a"); f:close()
  return s
end

function T.protocol_doc_is_up_to_date_and_covers_every_message()
  local doc = read("docs/protocol.md")
  t.ok(doc, "docs/protocol.md missing")
  for ty in pairs(proto.requests) do
    t.ok(doc:find("### `" .. ty .. "`", 1, true), "protocol.md lacks " .. ty)
  end
  local p = io.popen("lua5.2 tools/gen_protocol_doc.lua")
  local fresh = p:read("*a"); p:close()
  t.ok(fresh == doc, "docs/protocol.md is stale: run lua5.2 tools/gen_protocol_doc.lua > docs/protocol.md")
end

function T.every_role_has_a_readme()
  for _, role in ipairs({ "storage", "compute", "incoming", "outgoing", "register", "ingest", "monitor",
    "worker", "pocket", "gps" }) do
    local doc = read("roles/" .. role .. "/README.md")
    t.ok(doc and #doc > 100, "roles/" .. role .. "/README.md missing or empty")
  end
end

function T.top_level_docs_exist()
  t.ok(read("README.md"))
  local deploy = read("docs/phase1-deploy.md")
  t.ok(deploy and deploy:find("verify", 1, true) and deploy:find("mkrelease", 1, true))
  local p2 = read("docs/phase2-deploy.md")
  t.ok(p2 and p2:find("mkkeys", 1, true) and p2:find("storetest", 1, true))
  t.ok(read("docs/recovery.md"))
  local p3 = read("docs/phase3-deploy.md")
  t.ok(p3 and p3:find("Check number", 1, true) and p3:find("Set owner name", 1, true))
end

return T
