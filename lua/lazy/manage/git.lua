local Config = require("lazy.core.config")
local Process = require("lazy.manage.process")
local Semver = require("lazy.manage.semver")
local Util = require("lazy.util")

local M = {}

---@alias GitInfo {branch?:string, commit?:string, tag?:string, version?:Semver}

---@class GitTarget
---@field _ancestors? string[] Batch-prefetched ancestor commits (self excluded), lazily filled by :parent()
local Target = {}
Target.__index = Target

-- How many ancestor commits to fetch per `git log` call when walking parents.
-- A single spawn amortizes across this many :parent() calls instead of one
-- spawn per step, which matters for hooks that walk dozens/hundreds of
-- commits (e.g. a minimum-age policy on an actively-developed branch).
local PARENT_BATCH_SIZE = 50

---@param dir string
---@param info GitInfo
---@param commit string?
---@return GitTarget
local function target(dir, info, commit)
  -- A `tag`/`version` only describes the exact commit that tag points to.
  -- Walking to a different commit (a different ancestor) means we're no
  -- longer looking at that release, so drop the now-stale tag/version
  -- metadata rather than mislabeling an unrelated commit as if it were
  -- still that tagged version.
  local same_commit = not commit or commit == info.commit
  return setmetatable({
    commit = commit or info.commit,
    branch = info.branch,
    dir = dir,
    tag = same_commit and info.tag or nil,
    version = same_commit and info.version or nil,
  }, Target)
end

---@return number
function Target:date()
  local lines = Process.exec({
    "git",
    "show",
    "-s",
    "--format=%ct",
    "--date=short",
    self.commit,
  }, { cwd = self.dir })
  return tonumber(lines[1] or "0") or 0
end

---@return number
function Target:age()
  return math.floor((os.time() - self:date()) / 86400)
end

--- Returns the newest ancestor of `self` (inclusive) that is at least
--- `days` old, in a single `git log` spawn -- unlike walking :parent()
--- one commit at a time, this does not cost one spawn per skipped commit.
--- Returns nil if no ancestor is old enough.
---@param days number
---@return GitTarget?
function Target:before(days)
  local cutoff = os.time() - days * 86400
  local lines = Process.exec({
    "git",
    "log",
    "-1",
    "--format=%H",
    "--before=@" .. cutoff,
    self.commit,
  }, { cwd = self.dir })
  local commit = lines[1]
  if commit and commit ~= "" then
    return target(self.dir, self, commit)
  end
  return nil
end

---@return string
function Target:short()
  return self.commit:sub(1, 7)
end

---@return string
function Target:message()
  local lines = Process.exec({
    "git",
    "show",
    "-s",
    "--format=%s",
    self.commit,
  }, { cwd = self.dir })
  return lines[1] or ""
end

---@return string
function Target:author()
  local lines = Process.exec({
    "git",
    "show",
    "-s",
    "--format=%an <%ae>",
    self.commit,
  }, { cwd = self.dir })
  return lines[1] or ""
end

--- Returns the direct parent as a new GitTarget, or nil if `self` is the
--- root commit. Calling this repeatedly on the same GitTarget always
--- returns an equivalent result (idempotent) -- internally it batch-fetches
--- and caches a window of ancestor commits so that walking a long chain
--- (e.g. a hook stepping back day by day) costs one `git log` spawn per
--- `PARENT_BATCH_SIZE` steps instead of one spawn per step.
---@return GitTarget?
function Target:parent()
  local idx = (self._offset or 0) + 1
  if not self._ancestors or idx > #self._ancestors then
    local lines = Process.exec({
      "git",
      "log",
      "--pretty=format:%H",
      "-n",
      tostring(PARENT_BATCH_SIZE + 1),
      self.commit,
    }, { cwd = self.dir })
    ---@type string[]
    local ancestors = {}
    for i = 2, #lines do
      ancestors[#ancestors + 1] = lines[i]
    end
    self._ancestors = ancestors
    self._offset = 0
    idx = 1
  end

  local parent_sha = self._ancestors[idx]
  if not parent_sha or parent_sha == "" then
    return nil
  end

  local child = target(self.dir, self, parent_sha)
  -- Share the batch and continue the offset so the child's own :parent()
  -- calls read from the same window instead of refetching immediately.
  child._ancestors = self._ancestors
  child._offset = idx
  return child
end

M.target = target

---@param repo string
---@param details? boolean Fetching details is slow! Don't loop over a plugin to fetch all details!
---@return GitInfo?
function M.info(repo, details)
  local line = M.head(repo)
  if line then
    ---@type string, string
    local ref, branch = line:match("ref: refs/(heads/(.*))")
    local ret = ref and {
      branch = branch,
      commit = M.ref(repo, ref),
    } or { commit = line }

    if details then
      for tag, tag_ref in pairs(M.get_tag_refs(repo)) do
        if tag_ref == ret.commit then
          ret.tag = tag
          ret.version = ret.version or Semver.version(tag)
        end
      end
    end
    return ret
  end
end

---@param a GitInfo
---@param b GitInfo
function M.eq(a, b)
  local ra = a.commit and a.commit:sub(1, 7)
  local rb = b.commit and b.commit:sub(1, 7)
  return ra == rb
end

function M.head(repo)
  return Util.head(repo .. "/.git/HEAD")
end

---@class TaggedSemver: Semver
---@field tag string

---@param spec? string
function M.get_versions(repo, spec)
  local range = Semver.range(spec or "*")
  ---@type TaggedSemver[]
  local versions = {}
  for _, tag in ipairs(M.get_tags(repo)) do
    local v = Semver.version(tag)
    ---@cast v TaggedSemver
    if v and range:matches(v) then
      v.tag = tag
      table.insert(versions, v)
    end
  end
  return versions
end

function M.get_tags(repo)
  ---@type string[]
  local ret = {}
  Util.ls(repo .. "/.git/refs/tags", function(_, name)
    ret[#ret + 1] = name
  end)
  for name in pairs(M.packed_refs(repo)) do
    local tag = name:match("^tags/(.*)")
    if tag then
      ret[#ret + 1] = tag
    end
  end
  return ret
end

---@param plugin LazyPlugin
---@return string?
function M.get_branch(plugin)
  if plugin.branch then
    return plugin.branch
  else
    -- we need to return the default branch
    -- Try origin first
    local main = M.ref(plugin.dir, "remotes/origin/HEAD")
    if main then
      local branch = main:match("ref: refs/remotes/origin/(.*)")
      if branch then
        return branch
      end
    end

    -- fallback to local HEAD
    main = assert(M.head(plugin.dir))
    return main and main:match("ref: refs/heads/(.*)")
  end
end

-- Return the last commit for the given branch
---@param repo string
---@param branch string
---@param origin? boolean
function M.get_commit(repo, branch, origin)
  if origin then
    -- origin ref might not exist if it is the same as local
    return M.ref(repo, "remotes/origin", branch) or M.ref(repo, "heads", branch)
  else
    return M.ref(repo, "heads", branch)
  end
end

---@param plugin LazyPlugin
---@return GitInfo?
function M.get_target(plugin)
  if plugin._.is_local then
    local info = M.info(plugin.dir)
    local branch = assert(info and info.branch or M.get_branch(plugin))
    return { branch = branch, commit = M.get_commit(plugin.dir, branch, true) }
  end

  local branch = assert(M.get_branch(plugin))

  if type(plugin.commit) == "string" then
    return {
      branch = branch,
      commit = plugin.commit,
    }
  end

  ---@type GitInfo
  local target_info

  local version = (plugin.version == nil and plugin.branch == nil) and Config.options.defaults.version or plugin.version
  if plugin.tag then
    target_info = {
      branch = branch,
      tag = plugin.tag,
      commit = M.ref(plugin.dir, "tags/" .. plugin.tag),
    }
  elseif version then
    local last = Semver.last(M.get_versions(plugin.dir, version))
    if last then
      target_info = {
        branch = branch,
        version = last,
        tag = last.tag,
        commit = M.ref(plugin.dir, "tags/" .. last.tag),
      }
    end
  else
    target_info = { branch = branch, commit = M.get_commit(plugin.dir, branch, true) }
  end

  local commit_hook = plugin.commit
  if type(plugin.commit) ~= "function" and type(Config.options.defaults.commit) == "function" then
    commit_hook = Config.options.defaults.commit
  end

  if type(commit_hook) ~= "function" then
    return target_info
  end

  local starting_target = M.target(plugin.dir, target_info)
  local final_target = commit_hook(starting_target, plugin)

  if type(final_target) == "string" then
    target_info.commit = final_target
    return target_info
  else
    return final_target
  end
end

function M.ref(repo, ...)
  local ref = table.concat({ ... }, "/")

  -- if this is a tag ref, then dereference it instead
  if ref:find("tags/", 1, true) == 1 then
    local tags = M.get_tag_refs(repo, ref)
    for _, tag_ref in pairs(tags) do
      return tag_ref
    end
  end

  -- otherwise just get the ref
  return Util.head(repo .. "/.git/refs/" .. ref) or M.packed_refs(repo)[ref]
end

function M.packed_refs(repo)
  local ok, refs = pcall(Util.read_file, repo .. "/.git/packed-refs")
  ---@type table<string,string>
  local ret = {}
  if ok then
    for _, line in ipairs(vim.split(refs, "\n")) do
      local ref, name = line:match("^(.*) refs/(.*)$")
      if ref then
        ret[name] = ref
      end
    end
  end
  return ret
end

-- this is slow, so don't use on a loop over all plugins!
---@param tagref string?
function M.get_tag_refs(repo, tagref)
  tagref = tagref or "--tags"
  ---@type table<string,string>
  local tags = {}
  local ok, lines = pcall(function()
    return Process.exec({ "git", "show-ref", "-d", tagref }, { cwd = repo })
  end)
  if not ok then
    return {}
  end
  for _, line in ipairs(lines) do
    local ref, tag = line:match("^(%w+) refs/tags/([^%^]+)%^?{?}?$")
    if ref then
      tags[tag] = ref
    end
  end
  return tags
end

---@param repo string
function M.get_origin(repo)
  return M.get_config(repo)["remote.origin.url"]
end

---@param repo string
function M.get_config(repo)
  local ok, config = pcall(Util.read_file, repo .. "/.git/config")
  if not ok then
    return {}
  end
  ---@type table<string, string>
  local ret = {}
  ---@type string
  local current_section = nil
  for line in config:gmatch("[^\n]+") do
    -- Check if the line is a section header
    local section = line:match("^%s*%[(.+)%]%s*$")
    if section then
      ---@type string
      current_section = section:gsub('%s+"', "."):gsub('"+%s*$', "")
    else
      -- Ignore comments and blank lines
      if not line:match("^%s*[#;]") and line:match("%S") then
        local key, value = line:match("^%s*(%S+)%s*=%s*(.+)%s*$")
        ret[current_section .. "." .. key] = value
      end
    end
  end
  return ret
end

function M.count(repo, commit1, commit2)
  local lines = Process.exec({ "git", "rev-list", "--count", commit1 .. ".." .. commit2 }, { cwd = repo })
  return tonumber(lines[1] or "0") or 0
end

function M.age(repo, commit)
  local lines = Process.exec({ "git", "show", "-s", "--format=%cr", "--date=short", commit }, { cwd = repo })
  return lines[1] or ""
end

---@param repo string
---@param ancestor string commit SHA that should be the ancestor
---@param descendant string commit SHA that should be the descendant
---@return boolean true if `ancestor` is an ancestor of `descendant`
function M.is_ancestor(repo, ancestor, descendant)
  local ok, code = pcall(function()
    local _, c = Process.exec({ "git", "merge-base", "--is-ancestor", ancestor, descendant }, { cwd = repo })
    return c
  end)
  return ok and code == 0
end

M.hooks = {}

local DAY_SECONDS = 86400
local DAY_UNITS = { s = 1 / DAY_SECONDS, m = 60 / DAY_SECONDS, h = 3600 / DAY_SECONDS, d = 1, w = 7, y = 365 }

--- Parses a duration into a (possibly fractional) number of days.
--- Accepts a positive number (days) or a single-unit string like "30m",
--- "24h", "7d", "2w", "1y". Returns nil for nil/false/invalid input.
---@param value string|number|false|nil
---@return number?
function M.hooks.parse_days(value)
  if value == nil or value == false then
    return nil
  end
  if type(value) == "number" then
    return value > 0 and value or nil
  end
  if type(value) == "string" then
    local n, unit = value:match("^(%d+)%s*([smhdwy])$")
    if n and unit then
      local days = tonumber(n) * DAY_UNITS[unit]
      return days > 0 and days or nil
    end
  end
  return nil
end

--- Finds the newest tag, among those matching the plugin's version range,
--- whose creation date is at least `days` old. Mirrors get_target's own
--- tag/version resolution so a hook can stay on a real tagged release
--- instead of landing on an arbitrary untagged ancestor commit.
---@param plugin LazyPlugin
---@param days number
---@return GitTarget?
function M.hooks._mature_tag(plugin, days)
  local cutoff = os.time() - days * DAY_SECONDS
  local version = (plugin.version == nil and plugin.branch == nil) and Config.options.defaults.version or plugin.version
  local versions = M.get_versions(plugin.dir, version)
  if #versions == 0 then
    return nil
  end
  local ok, lines = pcall(function()
    return Process.exec(
      { "git", "for-each-ref", "--format=%(refname:strip=2) %(creatordate:unix)", "refs/tags" },
      { cwd = plugin.dir }
    )
  end)
  if not ok then
    return nil
  end
  ---@type table<string, integer>
  local tag_times = {}
  for _, line in ipairs(lines) do
    local tag, ts = line:match("^(.+) (%d+)$")
    if tag then
      tag_times[tag] = tonumber(ts)
    end
  end
  local eligible = vim.tbl_filter(function(v)
    local ts = tag_times[v.tag]
    return ts ~= nil and ts <= cutoff
  end, versions)
  local last = Semver.last(eligible)
  if not last then
    return nil
  end
  local commit = M.ref(plugin.dir, "tags/" .. last.tag)
  if not commit then
    return nil
  end
  return target(plugin.dir, { branch = M.get_branch(plugin), tag = last.tag, version = last, commit = commit })
end

--- Builds a CommitHook that only accepts commits/tags at least `value` old,
--- mitigating supply-chain attacks by giving the community time to catch a
--- freshly published malicious update before it is adopted. Usage:
---
---   require("lazy").setup(spec, {
---     defaults = { commit = require("lazy.manage.git").hooks.minimum_release_age("7d") },
---   })
---
--- `value` accepts a positive number of days or a single-unit duration
--- string ("30m", "24h", "7d", "2w", "1y").
---
--- Explicit `tag = "..."` pins and `pin = true` plugins are passed through
--- unchanged -- this only constrains fuzzy resolution (semver ranges and
--- branch HEAD following), matching Renovate's pin-exemption semantics.
---
--- By default, an already-installed plugin whose current commit is newer
--- than the mature ceiling is left as-is rather than rolled back; pass
--- `{ downgrade = true }` to always pin to the newest eligible commit,
--- rolling back if necessary.
---@param value string|number
---@param opts? { downgrade?: boolean }
---@return CommitHook
function M.hooks.minimum_release_age(value, opts)
  opts = opts or {}
  local days = M.hooks.parse_days(value)
  return function(t, plugin)
    if not days or plugin.tag or plugin.pin then
      return t
    end

    local mature = t.tag and M.hooks._mature_tag(plugin, days) or t:before(days)
    if not mature then
      -- Nothing is old enough yet; stay put until a future check finds one.
      return t
    end

    if opts.downgrade then
      return mature
    end

    -- Don't roll back an already-installed plugin that is already past the
    -- mature ceiling.
    local info = M.info(plugin.dir)
    if info and info.commit and mature.commit and M.is_ancestor(plugin.dir, mature.commit, info.commit) then
      return info.commit
    end
    return mature
  end
end

return M
