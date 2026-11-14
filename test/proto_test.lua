local t = require("test.t")
local proto = require("lib.proto")
local codec = require("lib.codec")
local S = require("lib.schema")
local samples = require("test.proto_samples")

local T = {}

local function req(ty, body) return { v = 1, t = ty, id = 7, ts = 1700000000000, b = body } end

local function copy(v)
  if type(v) ~= "table" then return v end
  local o = {}
  for k, x in pairs(v) do o[k] = copy(x) end
  return o
end

function T.constants()
  t.eq(proto.VERSION, 1)
  t.eq(proto.CH, { IN = 4201, OUT = 4202, BUS = 4210, TEL = 4211 })
  t.eq(proto.LIMITS.frameDefault, 2048)
  t.eq(proto.LIMITS.frameMax, 8192)
  t.eq(proto.LIMITS.jobsActive, 3)
  t.eq(proto.LIMITS.jobBlocks, 20000)
  t.eq(proto.LIMITS.uploadBytes, 262144)
  t.eq(proto.LIMITS.schematicQuota, 2097152)
  t.eq(proto.LIMITS.scanRadius, 16)
end

function T.every_request_has_a_valid_sample_that_round_trips()
  for ty in pairs(proto.requests) do
    local body = samples.requests[ty]
    t.ok(body, "no sample for request " .. ty)
    local msg = req(ty, body)
    local ok, err = proto.validate(msg)
    t.ok(ok, ty .. ": " .. tostring(err))
    local frame = codec.encode(msg)
    t.ok(#frame <= proto.LIMITS.frameMax, ty .. " sample too big")
    t.eq(codec.decode(frame), msg)
  end
  for ty in pairs(samples.requests) do t.ok(proto.requests[ty], "sample for unknown request " .. ty) end
end

function T.every_response_has_a_valid_sample()
  for ty in pairs(proto.requests) do t.ok(proto.responses[ty], "no response spec for " .. ty) end
  for ty in pairs(proto.responses) do
    local body = samples.responses[ty]
    t.ok(body, "no sample for response " .. ty)
    local ok, err = proto.validateResponse({ v = 1, t = ty, re = 7, ok = true, b = body })
    t.ok(ok, ty .. ": " .. tostring(err))
  end
end

function T.spec_section_6_request_types_exist()
  for _, ty in ipairs({ "hello", "shape.preview", "job.quote", "job.confirm", "job.cancel", "job.list",
    "job.status", "job.area", "lib.list", "lib.get_thumb", "acct.get", "upload.begin", "upload.chunk",
    "upload.end", "import.link", "import.status", "rekey", "w.claim", "w.survey", "w.inv", "w.ops",
    "w.result", "w.layer", "w.progress", "w.fault", "w.done" }) do
    t.ok(proto.requests[ty], "missing " .. ty)
  end
end

function T.rejects_bad_envelopes()
  local body = samples.requests["job.status"]
  t.eq(proto.validate(req("job.nope", body)), nil)
  local m = req("job.status", body); m.v = 2
  t.eq(proto.validate(m), nil)
  m = req("job.status", body); m.extra = 1
  t.eq(proto.validate(m), nil)
  m = req("job.status", body); m.id = -1
  t.eq(proto.validate(m), nil)
  m = req("job.status", body); m.ts = nil
  t.eq(proto.validate(m), nil)
  t.eq(proto.validate("x"), nil)
  t.eq(proto.validate(nil), nil)
  t.eq(proto.validate({}), nil)
end

function T.rejects_bad_bodies()
  local q = copy(samples.requests["job.quote"])
  q.shape.w = 65
  t.eq(proto.validate(req("job.quote", q)), nil)
  q = copy(samples.requests["job.quote"]); q.shape.block = "Stone"
  t.eq(proto.validate(req("job.quote", q)), nil)
  q = copy(samples.requests["job.quote"]); q.note = "please run this"
  t.eq(proto.validate(req("job.quote", q)), nil)
  q = copy(samples.requests["job.quote"]); q.shape.h = 2.5
  t.eq(proto.validate(req("job.quote", q)), nil)
  t.eq(proto.validate(req("import.link", { url = "http://example.com/a" })), nil)
  t.eq(proto.validate(req("import.link", { url = "https://" .. ("a"):rep(300) })), nil)
  t.eq(proto.validate(req("upload.begin", { name = "a", size = 262145, sha = ("ab"):rep(32), chunks = 1 })), nil)
end

function T.job_quote_needs_the_field_for_its_source()
  t.eq(proto.validate(req("job.quote", { src = "shape" })), nil)
  t.eq(proto.validate(req("job.quote", { src = "lib" })), nil)
  t.ok(proto.validate(req("job.quote", { src = "lib", ref = "L12" })))
  t.ok(proto.validate(req("job.quote", { src = "import", ref = "I5" })))
end

function T.error_responses()
  t.ok(proto.validateResponse({ v = 1, t = "job.status", re = 7, ok = false, err = "not_found" }))
  t.eq(proto.validateResponse({ v = 1, t = "job.status", re = 7, ok = false, err = "something else" }), nil)
  t.eq(proto.validateResponse({ v = 1, t = "job.status", re = 7, ok = false }), nil)
  t.eq(proto.validateResponse({ v = 1, t = "job.status", re = 7, ok = true }), nil)
end

function T.turtle_limits_spec_and_clamp()
  t.ok(S.check(proto.TURTLE_LIMITS, samples.limits))
  local bad = copy(samples.limits); bad.w = 49
  t.eq(S.check(proto.TURTLE_LIMITS, bad), nil)
  bad = copy(samples.limits); bad.keepOut = { { 0, 0, 0, 0, 0, 65 } }
  t.eq(S.check(proto.TURTLE_LIMITS, bad), nil)
  local out = S.clamp(proto.TURTLE_LIMITS, { w = 999, me = true }, { w = 48, me = false })
  t.eq(out.w, 48); t.eq(out.me, false); t.eq(out.take, "marked"); t.eq(out.maxMinutes, 240)
  t.ok(S.check(proto.TURTLE_LIMITS, out))
end

return T
