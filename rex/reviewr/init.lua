-- Rex integration for reviewr.nvim: a key that shows a review beside the
-- focused terminal and hides it again, or with `window = true` opens it in a
-- window of its own and jumps between the two. Pressed in an agent's
-- terminal, the review is paired with that agent: it tracks that agent's
-- turns and sends to it.
local M = {}

local TERMINAL = "com.superlogical.terminal"

M.config = {
  key = "cmd+r",
  -- run in the new Neovim; the branch scope diffs the working tree, commits
  -- and uncommitted edits alike, against its merge base with the default
  -- branch (origin/HEAD, else main or master)
  command = "ReviewrScope branch",
  nvim = "nvim",
  -- the share of the row the focused terminal keeps
  ratio = 0.4,
  -- open the review in a window of its own instead of a split; the key then
  -- jumps to the review, and from the review back to the terminal
  window = false,
  -- programs that count as agents, matched by executable name
  agents = { "claude", "codex", "opencode", "aider", "goose", "cline", "pi" },
}

local LABEL = "review"

-- with `window`, the terminal each unpaired review was last reached from
local origins = {}

local function foreground(session_id, block_id)
  local ok, proc = pcall(rex.call, "block.method",
    { session_id = session_id, block_id = block_id, method = "process" })
  return ok and type(proc) == "table" and proc.foreground or {}
end

local function agent_name(fg)
  for _, n in ipairs({ fg.argv0, fg.name, fg.invoked_path }) do
    local base = type(n) == "string" and n:match("([^/]+)$")
    for _, a in ipairs(M.config.agents) do
      if base == a then return a end
    end
  end
  return nil
end

local function repo_of(cwd)
  if cwd == "" then return "" end
  local out, _, code = rex.exec({ "git", "-C", cwd, "rev-parse", "--show-toplevel" })
  local top = code == 0 and out and out:match("[^\n]+")
  return top or cwd
end

local function is_review(b)
  return b.label == LABEL or (b.label or ""):sub(1, #LABEL + 1) == LABEL .. ":"
end

local function blocks_of(session_id)
  local ok, res = pcall(rex.call, "session.list_blocks", { session_id = session_id })
  return ok and res.blocks or {}
end

-- The Neovim runs only for the review, so closing the review quits it and
-- the pane closes with it.
local function open_new(session_id, anchor, cwd, label, pre)
  local command = { M.config.nvim, "-c", "lua vim.g.reviewr_standalone = true" }
  if pre then
    command[#command + 1] = "-c"
    command[#command + 1] = pre
  end
  command[#command + 1] = "-c"
  command[#command + 1] = M.config.command
  local block = {
    flavor = TERMINAL .. ".shell",
    label = label,
    options = { command = command, cwd = cwd },
  }
  if M.config.window then
    local res = rex.call("session.new_window", {
      session_id = session_id,
      window_label = LABEL,
      layout = { block = block },
    })
    if type(res) == "table" and res.block_ids then origins[res.block_ids[1]] = anchor end
    return res
  end
  return rex.call("session.new_split", {
    session_id = session_id,
    anchor_id = anchor,
    direction = "horizontal",
    side = "after",
    ratio = M.config.ratio,
    focus = true,
    layout = { block = block },
  })
end

local function hide(session_id, b)
  return rex.call("session.detach_block", { session_id = session_id, block_id = b.block_id })
end

local function focus(session_id, b)
  return rex.call("session.focus_block", { session_id = session_id, block_id = b.block_id })
end

-- Back to the terminal the review belongs to: its agent, else the terminal it
-- was last reached from, else the previous window.
local function leave(session_id, review)
  local origin = review.label:match("^" .. LABEL .. ":(.+)$") or origins[review.block_id]
  if origin and pcall(rex.call, "session.focus_block", { session_id = session_id, block_id = origin }) then
    return
  end
  return rex.call("session.focus_previous_window", { session_id = session_id })
end

local function show(session_id, b, anchor)
  local res = rex.call("session.move_block", {
    session_id = session_id,
    block_id = b.block_id,
    anchor_block_id = anchor,
    direction = "horizontal",
    side = "after",
    ratio = M.config.ratio,
  })
  rex.call("session.focus_block", { session_id = session_id, block_id = b.block_id })
  return res
end

-- Pressed in a review: hides it. Pressed in an agent's terminal: shows or
-- hides that agent's review, opening one paired with the agent the first
-- time. Pressed in any other terminal: hides the unpaired review in this
-- window, else brings back or opens the unpaired review of its repository.
-- Hidden reviews keep running with their comments.
--
-- With `window`, reviews live in windows of their own and the key jumps
-- instead of hiding: from a review back to its terminal, from a terminal to
-- its review (one per agent, else one per repository).
function M.toggle(ctx)
  local session_id = ctx.session_id or rex.session_id
  local block_id = ctx.block_id or rex.block_id
  local blocks = blocks_of(session_id)
  local focused
  for _, b in ipairs(blocks) do
    if b.block_id == block_id then focused = b end
  end
  if focused and is_review(focused) then
    if M.config.window then return leave(session_id, focused) end
    return hide(session_id, focused)
  end

  local fg = foreground(session_id, block_id)
  local cwd = fg.cwd or ""
  local agent = agent_name(fg)
  if agent then
    local label = LABEL .. ":" .. block_id
    for _, b in ipairs(blocks) do
      if b.label == label then
        if b.placement ~= "placed" then return show(session_id, b, block_id) end
        if M.config.window then return focus(session_id, b) end
        return hide(session_id, b)
      end
    end
    local pairing = string.format("lua vim.g.reviewr_agent = { session = %q, block = %q, name = %q }",
      session_id, block_id, agent)
    return open_new(session_id, block_id, cwd, label, pairing)
  end

  local repo = repo_of(cwd)
  for _, b in ipairs(blocks) do
    if b.label == LABEL and b.placement == "placed" then
      if M.config.window then
        if repo_of(foreground(session_id, b.block_id).cwd or "") == repo then
          origins[b.block_id] = block_id
          return focus(session_id, b)
        end
      elseif focused and b.window_id == focused.window_id then
        return hide(session_id, b)
      end
    end
  end
  for _, b in ipairs(blocks) do
    if b.label == LABEL and b.placement ~= "placed" and repo_of(foreground(session_id, b.block_id).cwd or "") == repo then
      return show(session_id, b, block_id)
    end
  end
  return open_new(session_id, block_id, cwd, LABEL)
end

M.open = M.toggle

function M.setup(opts)
  for k, v in pairs(opts or {}) do M.config[k] = v end
  rex.action({
    name = "reviewr_open",
    title = "Show or hide the review",
    run = function(ctx) return M.toggle(ctx or {}) end,
  })
  if M.config.key then
    rex.bind(M.config.key, function(ctx)
      M.toggle(ctx or {})
      return true
    end)
  end
end

return M
