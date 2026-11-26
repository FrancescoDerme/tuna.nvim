-- lua/tuna/run/modes/interactive.lua
--
-- Interactive problems: the solution talks to something over stdio, turn by turn.
-- Tuna offers three *sources* for the other side of that conversation:
--
--   * live       — YOU are the other side. The conversation is laid out in three
--                  columns, Output, Live and Errors, each writing on rows the other
--                  two leave blank; you type into Live and <CR> sends the line to the
--                  solution's stdin. No auto-verdict.
--   * feed       — a pre-written input plays the other side, one line per turn: each
--                  time the solution emits a line, the next input line is sent. If
--                  the testcase has an expected output, the solution's stdout is
--                  judged against it; otherwise done.
--   * interactor — a written interactor program (interactor.*) is cross-wired to the
--                  solution and decides the verdict (exit 0 = accepted). Secondary:
--                  used automatically only when an interactor.* sibling exists, or
--                  when asked for explicitly.
--
-- `vim.system` only hands back stdout when a process *finishes*, so it can't cross-
-- wire live processes. We drop to `vim.uv.spawn` and forward bytes between pipes by
-- hand. Reuse: `runner.new()` resolves the solution's compile/run commands, dirs and
-- checker; the runner UI is the shared one (this `InteractiveRunner` is a
-- `RunnerCore` subclass, like the normal and stress runners).

local api = vim.api
local uv = vim.uv
local config = require("tuna.config")
local utils = require("tuna.utils")
local runner = require("tuna.run")
local checker = require("tuna.run.checker")
local testcases = require("tuna.problem.testcases")
local tools = require("tuna.run.tools")
local core = require("tuna.run.core")

local M = {}

-- Live interactive runners keyed by buffer, so `VimResized` can rebuild their UIs
-- and a fresh run can tear the previous one down (mirrors `stress.M.active`).
---@type table<integer, table>
M.active = {}

---A pipe for one side of a session.
---@return uv.uv_pipe_t
local function pipe()
    return assert(uv.new_pipe(false))
end

---A budget of `limit` bytes over what a session prints, counted as it is read, in the fast
---context: scheduled first, a program printing in a loop would fill the editor's queue faster
---than it empties. `on_over` runs once, as the budget runs out, and nothing more fits after.
---@param limit integer? none when nil
---@param on_over fun()
---@return fun(data: string): boolean within whether `data` still fits
---@return fun(): boolean over whether the budget ran out
local function budget(limit, on_over)
    local printed, over = 0, false
    local function within(data)
        if over then
            return false
        end
        printed = printed + #data
        if limit and printed > limit then
            over = true
            on_over()
            return false
        end
        return true
    end
    return within, function()
        return over
    end
end

---Kill a process handle that may have exited already.
---@param handle uv.uv_process_t?
local function kill(handle)
    if handle and handle:is_active() then
        pcall(handle.kill, handle, "sigkill")
    end
end

-- A session is a row's own: `tc.session` holds its pipe to the solution (`sol_in`), its
-- processes (`sol`, and `int` for an interactor) and whether they still run (`running`). Its
-- callbacks write to the row only while it is still the row's session, so a row talked to again
-- from the start leaves the session it replaced nothing to write over. Live sessions run side by
-- side, each on its row; the other sources run theirs one after another.

---Whether a row's session can be talked to: its solution's stdin is open.
---@param tc table?
---@return boolean
local function talking(tc)
    local s = tc and tc.session
    return s ~= nil and s.sol_in ~= nil and not s.sol_in:is_closing()
end

-- The keys the Live column binds itself, to start typing and to send: the board's own keys stay
-- off them there, read-only or not.
local TYPING_KEYS = { "i", "I", "a", "A", "o", "O", "<CR>" }

--------------------------------------------------------------------------------
-- The conversation (live and interactor)
--------------------------------------------------------------------------------

-- The panes a conversation's columns are drawn in.
local CONVERSATION_PANES = { "se", "so", "si" }

-- The blank screen rows Output and Live put under a row whose Errors line wraps, so the three
-- columns stay level.
local fill_ns = api.nvim_create_namespace("tuna_conversation")

-- How many rows of a conversation its log keeps, the latest ones, once it is trimmed: every row
-- it keeps is a line in each column, so a program printing in a loop would otherwise grow the
-- columns without end. It is trimmed in batches of `TRIM_ROWS`, each a redraw of the columns,
-- which between trims only gain the rows that are new. What the columns no longer show is only
-- counted (`log.dropped`): `tc.stdout` holds the output.
local SHOWN_ROWS = 5000
local TRIM_ROWS = 1000

-- How long a row of a conversation grows before it ends in `…`: a program printing without a
-- newline would otherwise build one row as long as all it prints, copied on every piece and
-- drawn whole on every render.
local ROW_BYTES = 2000

---`text` as a row holds it: whole, or its first `ROW_BYTES` bytes, a character never split, and
---`…`, with `true` when it was cut.
---@param text string
---@return string, true?
local function clipped(text)
    if #text <= ROW_BYTES then
        return text, nil
    end
    return text:sub(1, ROW_BYTES + vim.str_utf_end(text, ROW_BYTES)) .. "…", true
end

---Append what one side said to a session's conversation. Each entry of `tc.log` is one
---row, owned by the column that wrote it; the other columns are blank on that row, which
---is what puts a reply on a line of its own instead of beside the message it answers, and
---why nothing is ever copied from one column into another. A side that keeps writing
---without a newline (a prompt, or output arriving in pieces) carries on along its own row,
---but only while nobody else has spoken: once another column has taken a row, whatever
---comes next starts a fresh one.
---@param tc table the session's row
---@param col "so"|"se"|"si"
---@param data string?
local function log_append(tc, col, data)
    tc.log = tc.log or {}
    if data == nil or data == "" then
        return
    end
    local pieces = vim.split(data, "\n", { plain = true })
    local ends_line = pieces[#pieces] == ""
    if ends_line then
        table.remove(pieces)
    end
    for i, piece in ipairs(pieces) do
        local last = tc.log[#tc.log]
        local entry
        if i == 1 and last and last.col == col and last.open then
            if not last.cut then
                last.text, last.cut = clipped(last.text .. piece)
            end
            entry = last
        else
            entry = { col = col }
            entry.text, entry.cut = clipped(piece)
            tc.log[#tc.log + 1] = entry
        end
        entry.open = i == #pieces and not ends_line
    end
    -- Trimmed in batches, so each row costs the same however long the session runs.
    if #tc.log > SHOWN_ROWS + TRIM_ROWS then
        local kept = { dropped = (tc.log.dropped or 0) + #tc.log - SHOWN_ROWS }
        table.move(tc.log, #tc.log - SHOWN_ROWS + 1, #tc.log, 1, kept)
        tc.log = kept
    end
end

---Put a line of tuna's own (a session ending, a timeout) into the Errors column, on a row
---of its own: whatever row was left open is closed first, so the note can't run into it.
---@param tc table
---@param text string
local function log_note(tc, text)
    tc.log = tc.log or {}
    local last = tc.log[#tc.log]
    if last then
        last.open = false
    end
    log_append(tc, "se", text .. "\n")
end

---Lay a conversation out as the lines of its three columns: one row per entry, blank in every
---column but the one that wrote it, so the three come back the same length and the columns stay
---line for line. Whole, the rows the log no longer keeps are counted on a line above them;
---given `first`, only the entries from there on.
---@param log table[]?
---@param first integer?
---@return table<string, string[]>
local function conversation(log, first)
    log = log or {}
    local out = { so = {}, se = {}, si = {} }
    if not first and (log.dropped or 0) > 0 then
        out.so[1], out.si[1] = "", ""
        out.se[1] = ("[%d earlier lines not shown]"):format(log.dropped)
    end
    for i = first or 1, #log do
        local entry = log[i]
        for _, col in ipairs(CONVERSATION_PANES) do
            out[col][#out[col] + 1] = col == entry.col and entry.text or ""
        end
    end
    return out
end

---Replace lines `start` to `stop` (0-based, end-exclusive, as `nvim_buf_set_lines` reads them)
---of a column without touching the undo history or leaving the buffer `modified`.
---@param bufnr integer
---@param start integer
---@param stop integer
---@param lines string[]
---@param modifiable boolean
local function write_lines(bufnr, start, stop, lines, modifiable)
    vim.bo[bufnr].modifiable = true
    local undolevels = vim.bo[bufnr].undolevels
    vim.bo[bufnr].undolevels = -1
    api.nvim_buf_set_lines(bufnr, start, stop, false, lines)
    vim.bo[bufnr].undolevels = undolevels
    vim.bo[bufnr].modifiable = modifiable
    vim.bo[bufnr].modified = false
end

---Write a column's lines, from the first that differs from what it holds, so a redraw leaves
---the lines it did not change alone (a column being read, Neovim's own redraw). With
---`keep_last`, the buffer's own last line is left in place: that line is being typed into.
---@param bufnr integer
---@param lines string[]
---@param keep_last boolean
---@param modifiable boolean
---@return integer? changed the first line written (0-based), nil when nothing was
local function set_column(bufnr, lines, keep_last, modifiable)
    if not keep_last and #lines == 0 then
        lines = { "" }
    end
    local stop = keep_last and api.nvim_buf_line_count(bufnr) - 1 or -1
    local old = api.nvim_buf_get_lines(bufnr, 0, stop, false)
    local i = 1
    while i <= #lines and i <= #old and lines[i] == old[i] do
        i = i + 1
    end
    if i > #lines and i > #old then
        vim.bo[bufnr].modifiable = modifiable
        vim.bo[bufnr].modified = false
        return nil
    end
    write_lines(bufnr, i - 1, keep_last and #old or -1, { unpack(lines, i) }, modifiable)
    return i - 1
end

---The width the Errors column's text wraps at, or nil when it has no window.
---@param win integer?
---@return integer?
local function text_width(win)
    if not (win and api.nvim_win_is_valid(win)) then
        return nil
    end
    local info = vim.fn.getwininfo(win)[1]
    return info.width - info.textoff
end

---Keep Output and Live level with the Errors column from line `first` (0-based) down: under each
---row whose Errors line wraps onto more screen rows, the other two get as many blank virtual
---lines, so the three columns keep facing each other row for row while Errors wraps as it does
---on every testcase row. The text itself is left whole, to be searched, yanked and zoomed.
---@param w table<string, table> the conversation's panes
---@param first integer
local function fill_rows(w, first)
    for _, name in ipairs({ "so", "si" }) do
        api.nvim_buf_clear_namespace(w[name].bufnr, fill_ns, first, -1)
    end
    local win = w.se.winid
    local width = text_width(win)
    if not width or not vim.wo[win].wrap then
        return
    end
    local lines = api.nvim_buf_get_lines(w.se.bufnr, first, -1, false)
    for i, line in ipairs(lines) do
        -- A line no longer in bytes than the column is wide cannot wrap.
        if #line > width and vim.fn.strdisplaywidth(line) > width then
            local row = first + i - 1
            local rows = api.nvim_win_text_height(win, { start_row = row, end_row = row }).all
            if rows > 1 then
                local blank = {}
                for k = 1, rows - 1 do
                    blank[k] = { { "", "" } }
                end
                for _, name in ipairs({ "so", "si" }) do
                    if row < api.nvim_buf_line_count(w[name].bufnr) then
                        api.nvim_buf_set_extmark(w[name].bufnr, fill_ns, row, 0, { virt_lines = blank })
                    end
                end
            end
        end
    end
end

---The top line that puts line `last` on the window's bottom row, every row between them shown
---whole: the columns' rows can take several screen rows (Errors wrapping, the blank rows facing
---it), so this is counted in screen rows rather than lines.
---@param win integer
---@param last integer
---@return integer
local function bottom_topline(win, last)
    local height = api.nvim_win_get_height(win)
    local top = math.max(1, last - height + 1)
    while top < last and api.nvim_win_text_height(win, { start_row = top - 1, end_row = last - 1 }).all > height do
        top = top + 1
    end
    return top
end

---What the interactor source asks for when there is no interactor at all: to write its
---starter.
---@param bufnr integer
---@param opts { win: integer?, before: fun()? }?
local function offer_interactor(bufnr, opts)
    require("tuna.workspace.scaffold").create_missing({ "interactor" }, bufnr, "the interactor source needs an interactor", opts)
end

---A live session's row. It stands for no testcase, so its `tcnum` is its name, as the build
---step's is: no row number is free to take, nothing compares it with disk, and nothing edits it.
---@param n integer the session's number
---@return table
local function live_row(n)
    return { tcnum = "live " .. n, live = n, stdin = "", status = "", hlgroup = "TunaRunning" }
end

--------------------------------------------------------------------------------
-- InteractiveRunner (a RunnerCore subclass the runner UI drives)
--------------------------------------------------------------------------------

local InteractiveRunner = core.extend()

-- Testcases are not edited from this UI by default: in `live` and `interactor` the `si`
-- pane is the other side of a conversation, not a stored input. `feed` is the exception
-- and turns it on per runner (see `M.run`), since what it replays *is* a stored testcase.
InteractiveRunner.editable_testcases = false

---Whether this runner's source is a conversation, laid out in aligned columns. `feed` is
---not one: it replays a stored testcase, whose input and output are read as texts.
---@return boolean
function InteractiveRunner:conversational()
    return self.source ~= "feed"
end

---Whether the rows get a verdict. In live you are the judge, so the Run pane leaves out what
---judges and the diff, and no checker is built.
---@return boolean
function InteractiveRunner:judges()
    return self.source ~= "live"
end

---The grid this source draws, from `interactive.layouts` (`false` there means the configured
---one), and the name to report it by when it does not validate. `feed` keeps the configured
---grid, with the canonical Input and Expected Output panes, editable as in a normal run: what
---it replays is a stored testcase. `live` and `interactor` are a conversation and are laid out
---as one, the selector, then a column each for Output, Live and Errors, every one full height,
---so a row of one faces the same row of the others, and the three as wide as each other.
---Expected output has no place in it, a sample exchange being one example of a conversation
---rather than the only correct one.
---@return table? layout, string? name
function InteractiveRunner:layout()
    local own = ((self.config.interactive or {}).layouts or {})[self.source]
    if not own then
        return nil
    end
    return own, "interactive.layouts." .. self.source
end

---`si` is named for what it is in a conversation: the other side of it, not a stored
---testcase's input.
---@return table<string, string>?
function InteractiveRunner:pane_titles()
    if not self:conversational() then
        return nil
    end
    return { si = " live " }
end

---In live mode the Live pane is typed into, so the UI must leave its letters alone
---(no `q`-to-close on it) even though testcases aren't editable in this mode.
---@param name string
---@return boolean
function InteractiveRunner:owns_pane(name)
    return name == "si" and self.source == "live"
end

-- What each source adds to the `?` legend: who plays the other side and how, and what decides
-- the verdict. The other sources are named last, since switching is a command, not a key.
local LEGEND = {
    live = {
        { "you", "play the other side, in the live column" },
        { "start typing", "i, a, o or <CR> in the live column" },
        { "send a line", "<CR>" },
        { "the verdict", "none, you are the judge" },
    },
    feed = {
        { "the input", "is sent to the solution a line at a time" },
        { "the verdict", "its output against the expected output" },
    },
    interactor = {
        { "the interactor", "plays the other side, in the live column" },
        { "the verdict", "the interactor's exit code, 0 is correct" },
    },
}

---What the `?` legend adds for an interactive run: the source playing the other side.
---@return { title: string, rows: string[][] }
function InteractiveRunner:legend_rows()
    local rows = vim.deepcopy(LEGEND[self.source] or {})
    local others = {}
    for _, source in ipairs({ "live", "feed", "interactor" }) do
        if source ~= self.source then
            others[#others + 1] = source
        end
    end
    rows[#rows + 1] = { "other sources", ":Tuna run interactive " .. table.concat(others, " or ") }
    return { title = "interactive, " .. self.source, rows = rows }
end

---One extra "Run" pane row, under the checker or comparison: which side is playing the
---interactor. A setting like those two, so it sits with them rather than below the run's own
---rows.
---@return string[][]
function InteractiveRunner:status_settings()
    return { { "source", self.source } }
end

---In a conversation the three columns are drawn by `on_details_rendered`, since their rows
---have to be laid out together and the Live column is typed into, where the base render
---would replace each pane on its own and overwrite the line being typed. There is no
---expected output to show or diff against. In `feed` every pane is the base class's: `si`
---shows the input being fed, and Errors carries a checker's message. The build step is
---nobody's conversation: its panes are the sources being compiled, drawn by the UI as they
---are in every other mode.
function InteractiveRunner:pane_content(tc, name)
    if
        not tc.compile
        and self:conversational()
        and (name == "so" or name == "se" or name == "si" or name == "eo")
    then
        return core.SKIP
    end
    return core.RunnerCore.pane_content(self, tc, name)
end

---Nothing will run, so nothing is in flight either: left `false`, the runner would refuse
---every edit with "wait for the run to finish".
function InteractiveRunner:settle_all()
    self.claims, self.sequence, self.completed = 0, nil, true
end

function InteractiveRunner:on_build_failed()
    self:settle_all()
    self:update_ui(true)
end

---A session started on its own (a row's run key, `n`) holds the runner until it ends, as the
---normal runner's `run_single` does: `idle()` reads `completed`, and left true it let the
---structural edits `feed` allows (`n`, `x`, a split) through mid-session. Live sessions run
---side by side, so the runner is idle once none holds it and no run of every session is going.
function InteractiveRunner:claim()
    self.claims = (self.claims or 0) + 1
    self.completed = false
end

function InteractiveRunner:release()
    self.claims = math.max(0, (self.claims or 0) - 1)
    if self.claims == 0 and not self.sequence then
        self.completed = true
    end
end

---Let a row's session go: its processes are killed, and it is no longer the row's, so nothing
---it says from here on lands there. Its end still settles what it held.
---@param tc table
function InteractiveRunner:drop_session(tc)
    local s = tc.session
    tc.session = nil
    if s and s.running then
        kill(s.sol)
        kill(s.int)
    end
end

---End one row's session: the row on the cursor, else, when the sessions run one after another,
---the one running now. Its row reads `killed`, as a testcase stopped in any mode does, and the
---run goes on to the next one. A live session is stopped on its own row only, the others
---being conversations of their own.
---@param idx integer? the row
function InteractiveRunner:kill_process(idx)
    local tc = idx and self.tcdata[idx]
    if not (tc and tc.session and tc.session.running) and self.source ~= "live" then
        tc = self.active_index and self.tcdata[self.active_index]
    end
    local s = tc and tc.session
    if s and s.running then
        tc.killed = true
        kill(s.sol)
        kill(s.int)
    end
end

---Stop the run: every session running ends, and none starts after them.
function InteractiveRunner:kill_all_processes()
    self.stopped = true
    for i, tc in ipairs(self.tcdata) do
        if tc.session and tc.session.running then
            self:kill_process(i)
        end
    end
end

---Run one row's session, talked to again from the start if it is already talking. In live it is
---typed into once it talks (`type_into`): every way here (its run key, `n`, a typing key on a
---row with none) asks to talk.
---@param idx integer
function InteractiveRunner:run_single(idx)
    local tc = self.tcdata[idx]
    if not tc or tc.compile then
        return
    end
    if self.source == "live" then
        self.type_into = tc
    end
    self:drop_session(tc)
    self:claim()
    self.stopped = false
    local function go()
        self:with_helpers(function()
            self:run_one_session(idx, function()
                core.save_buffer_verdict(self.bufnr, self.tcdata)
                self:release()
                self:update_ui(true)
            end)
        end)
    end
    if not self:built_first(go) then
        go()
    end
end

---Run every session from the top: the first run, and the UI's "run all again". Like a run
---of the whole set in every mode, it builds the solution first. In live a run asked for is a
---session to talk to, the first, which the board follows: asked now, as the run is, so putting
---the board away while it builds lets the request go (`on_ui_hidden`).
function InteractiveRunner:run_testcases()
    if self.source == "live" then
        for _, tc in ipairs(self.tcdata) do
            if not tc.compile then
                self.type_into = tc
                break
            end
        end
    end
    self:claim_listed()
    self.completed = false
    self:with_helpers(function()
        self:run_sessions()
    end, true)
end

---Look this run's helpers up again before a run, as every run does: the checker, and for the
---interactor source the interactor, prepared again so an edited one rebuilds. A rerun keeps
---its source, so an interactor that is gone is reported and nothing runs: `:Tuna run` picks
---the source again.
---@param cont fun()
---@param whole boolean? a run of the whole set, which builds the solution too
function InteractiveRunner:with_helpers(cont, whole)
    local solution = api.nvim_buf_get_name(self.bufnr)
    local build = whole and self.build_all or self.build_helpers
    self:refresh_judge(solution)
    if self.source ~= "interactor" then
        -- In live nothing is judged, so no checker is built.
        if self:judges() then
            self:plan_builds({ self.checker })
            self:build_judge()
        else
            self:plan_builds({})
        end
        return build(self, {}, cont)
    end
    local spec, missing = tools.helper("interactor", solution, self.config)
    if not spec then
        self:settle_all()
        self:update_ui(true)
        if not missing then
            -- Simply not there: its starter can stand in. Written, it opens in the editor the
            -- board was over, the board having nothing to run until it is filled in.
            return offer_interactor(self.bufnr, {
                win = self.ui and self.ui.restore_winid,
                before = function()
                    self:delete_ui()
                end,
            })
        end
        local text = missing .. ", :Tuna run picks the source again."
        if self.ui then
            self.ui:show_message(" interactive: no interactor ", text)
        else
            utils.notify("interactive: " .. text, "WARN")
        end
        return
    end
    self.interactor = spec
    self:plan_builds({ spec, self.checker })
    self:build_judge()
    build(self, { spec }, cont)
end

---In a conversation the three columns are scroll-bound, so reading back through one keeps the
---rows of all three level. Output and Live are unwrapped, as Output is on every row; Errors
---wraps as the UI wraps it there, and `fill_rows` gives the other two the blank rows that keep
---them level. Scrolling by screen row (`smoothscroll`) would part them, so they scroll by line.
---The build step is no conversation: its panes hold each source's compiler output, read on its
---own and wrapped by the UI. When `live`, the Live column is also typed into, and <CR> sends the
---line being typed.
---@param ui table the RunnerUI
function InteractiveRunner:on_ui_shown(ui)
    if not self:conversational() then
        return
    end
    local conversing = not (ui.drawn_row and ui.drawn_row.compile)
    for _, name in ipairs(CONVERSATION_PANES) do
        local w = ui.windows[name]
        if w and w.winid and api.nvim_win_is_valid(w.winid) then
            local opt = { scope = "local", win = w.winid }
            api.nvim_set_option_value("scrollbind", conversing, opt)
            api.nvim_set_option_value("smoothscroll", not conversing and vim.go.smoothscroll, opt)
            if conversing and name ~= "se" then
                api.nvim_set_option_value("wrap", false, opt)
            end
        end
    end
    -- The panes were laid out again, maybe at another width: Errors wraps anew.
    if self.drawn then
        self.drawn.width = nil
    end
    if self.source ~= "live" then
        return
    end
    local w = ui.windows.si
    if not (w and w.winid and api.nvim_buf_is_valid(w.bufnr)) then
        return
    end
    local buf = w.bufnr
    -- What is typed here is sent, not written: a completion menu would only stand between
    -- a reply and <CR>.
    if not vim.b[buf].tuna_no_completion then
        vim.b[buf].tuna_no_completion = true
        require("tuna.ui.surface").no_completion(buf)
    end

    ---Send the line being typed, the Live column's last line, since everything above it is
    ---conversation already. It stays where it was typed and a new line opens under it at once,
    ---as <CR> does anywhere: the redraw then finds the line already in place, rather than the
    ---line vanishing for a frame before coming back as a row, and a key pressed in between
    ---lands on the new line.
    ---The row on screen has no session: there is no program to talk to, so a key that means
    ---"type here" means "talk to it", a session of the row's own, with the build there is (and
    ---the first build, on a board only listed so far), typed into once it talks, so the
    ---keystroke is not swallowed.
    local function start_talking()
        local tc = self.drawn and self.drawn.tc
        -- Talking already, its column not typable yet (the redraw that makes it so has not
        -- come): typing is what is asked for, not another session.
        if talking(tc) then
            self.type_into = tc
            self:update_ui(true)
            return
        end
        local idx = tc and self.ui and self.ui:row_index(tc)
        if idx then
            self:run_single(idx)
        else
            self:run_testcases()
        end
    end

    local function send()
        local tc = self.drawn and self.drawn.tc
        if not talking(tc) then
            start_talking()
            return
        end
        local n = api.nvim_buf_line_count(buf)
        local line = api.nvim_buf_get_lines(buf, n - 1, n, false)[1] or ""
        write_lines(buf, n, n, { "" }, true)
        if w.winid and api.nvim_win_is_valid(w.winid) then
            pcall(api.nvim_win_set_cursor, w.winid, { n + 1, 0 })
        end
        self:live_send(line, tc)
    end
    vim.keymap.set("i", "<CR>", send, { buffer = buf })
    vim.keymap.set("n", "<CR>", send, { buffer = buf, nowait = true })

    -- The keys that mean "I am typing here". While the column is typable they are Vim's own;
    -- before that they would only raise `E21` at someone who is being invited to talk, so
    -- they start the session instead.
    for _, key in ipairs(TYPING_KEYS) do
        if key == "<CR>" then
            break
        end
        vim.keymap.set("n", key, function()
            if vim.bo[buf].modifiable then
                api.nvim_feedkeys(key, "n", false)
            else
                start_talking()
            end
        end, { buffer = buf, nowait = true })
    end
end

---Keep a request to type (`type_into`, the session a run asked to talk to) only while it can be
---honoured by the board where you are: the board is not where you are, or the session talks
---while the board shows another row (a build that had something to say holds it), and it is
---dropped, or moving there by hand later would throw you into insert mode unasked. Showing a
---board asks for nothing: what you came back to do there is yours to say.
---@param shown table the row on screen
function InteractiveRunner:hand_over(shown)
    local want = self.type_into
    if not want then
        return
    end
    local here = require("tuna.runner_ui").owner_of(api.nvim_get_current_buf()) == self
    if not here or (want ~= shown and talking(want)) then
        self.type_into = nil
    end
end

---The board was put away: a request to type was for the board you ran from, and showing it again
---asks for nothing.
function InteractiveRunner:on_ui_hidden()
    self.type_into = nil
end

---Draw the conversation for the row the UI is showing, then follow the latest line. Called
---after every detail render, which the UI coalesces to one per tick, so a burst of output
---is laid out once rather than once per chunk.
---
---A conversation only grows between redraws: its log gains rows, and its last row may grow
---while it is left open. So a redraw of the row drawn last writes only the rows from the last
---one drawn down (`self.drawn`), unless a column was changed by something else (the Live column
---is typed into, the build step borrows the buffers) or the log was trimmed, which draw it
---whole again, writing from the first line that differs. A redraw costs what is new rather than
---what the session has said so far, and Neovim repaints only the rows that changed.
---
---During a live session the Live column ends in the line being typed, which is not part of
---the conversation yet: the other columns get a blank line to face it, and it is carried
---across the redraw rather than rewritten, or a keystroke landing between two chunks of
---output would be lost. A column follows the latest line unless the cursor is in it and
---off the bottom, which is someone reading back; with the columns scroll-bound, the
---others then stay level with them.
---@param ui table the RunnerUI
---@param tc table the row being shown
function InteractiveRunner:on_details_rendered(ui, tc)
    -- The build step is drawn by the UI, one pane per source compiled.
    if not self:conversational() or tc.compile then
        self.drawn = nil
        self:hand_over(tc)
        return
    end
    local w = {}
    for _, name in ipairs(CONVERSATION_PANES) do
        w[name] = ui.windows[name]
        if not (w[name] and w[name].bufnr and api.nvim_buf_is_valid(w[name].bufnr)) then
            self.drawn = nil
            return
        end
    end

    local cur = api.nvim_get_current_win()
    local follow, col_of = {}, {}
    for _, name in ipairs(CONVERSATION_PANES) do
        local win = w[name].winid
        if win and api.nvim_win_is_valid(win) then
            local pos = api.nvim_win_get_cursor(win)
            follow[name] = win ~= cur or pos[1] >= api.nvim_buf_line_count(w[name].bufnr)
            col_of[name] = pos[2]
        end
    end

    local log = tc.log or {}
    local composing = self.source == "live" and talking(tc)
    local d = self.drawn
    local same = d and d.tc == tc and d.log == log and d.composing == composing and d.dropped == log.dropped
    -- The first line (0-based) any column wrote, from where Errors' wrapping is measured again.
    local changed
    local function wrote(line)
        if line and (not changed or line < changed) then
            changed = line
        end
    end
    local cols
    for _, name in ipairs(CONVERSATION_PANES) do
        local buf = w[name].bufnr
        local typable = composing and name == "si"
        -- An empty column holds a blank line standing for nothing, so its first rows are a
        -- redraw rather than an addition.
        if same and d.rows > 0 and api.nvim_buf_get_changedtick(buf) == d.ticks[name] then
            -- Only what is new: the last row drawn again if it was left open, as it may have
            -- grown, and every row after it. Whatever follows them (the line being typed, and
            -- the blank lines facing it) is left where it is.
            local base = (log.dropped or 0) > 0 and 1 or 0
            local from = d.open and d.rows or d.rows + 1
            if from <= #log then
                write_lines(buf, base + from - 1, base + d.rows, conversation(log, from)[name], typable)
                wrote(base + from - 1)
            end
        else
            cols = cols or conversation(log)
            local lines = cols[name]
            if typable then
                if same or (d and d.tc == tc and d.composing) then
                    wrote(set_column(buf, lines, true, true))
                else
                    wrote(set_column(buf, vim.list_extend(vim.list_slice(lines), { "" }), false, true))
                end
            else
                if composing then
                    lines = vim.list_extend(vim.list_slice(lines), { "" })
                end
                wrote(set_column(buf, lines, false, false))
            end
        end
    end
    if not composing then
        if cur == w.si.winid and api.nvim_get_mode().mode:sub(1, 1) == "i" then
            vim.cmd("stopinsert") -- the session is over: there is nothing left to type to
        end
    end

    -- Errors wraps: the rows from the first one written down are measured again, and all of
    -- them when its width changed.
    local width = text_width(w.se.winid)
    if not (d and d.width == width) or not same then
        changed = 0
    end
    if changed then
        fill_rows(w, changed)
    end
    local ticks = {}
    for _, name in ipairs(CONVERSATION_PANES) do
        ticks[name] = api.nvim_buf_get_changedtick(w[name].bufnr)
    end
    self.drawn = {
        tc = tc,
        log = log,
        rows = #log,
        open = log[#log] ~= nil and log[#log].open,
        dropped = log.dropped,
        composing = composing,
        ticks = ticks,
        width = width,
    }

    self:hand_over(tc)
    if composing and self.type_into == tc then
        -- A session started to be talked to is talking, on screen: the cursor goes to the end
        -- of its column and insert starts, which is what starting it was for.
        self.type_into = nil
        local win, sbuf = w.si.winid, w.si.bufnr
        vim.schedule(function()
            if not (win and api.nvim_win_is_valid(win) and vim.bo[sbuf].modifiable) then
                return
            end
            api.nvim_set_current_win(win)
            local n = api.nvim_buf_line_count(sbuf)
            pcall(api.nvim_win_set_cursor, win, { n, #(api.nvim_buf_get_lines(sbuf, n - 1, n, false)[1] or "") })
            vim.cmd("startinsert!")
        end)
    end

    -- Someone reading back through one column holds all three where they are: the others
    -- are scroll-bound to it, and following the latest line would pull them out of level.
    for _, name in ipairs(CONVERSATION_PANES) do
        if col_of[name] ~= nil and not follow[name] then
            return
        end
    end
    -- Every row is as tall in each column, so one top line puts the latest line on the bottom
    -- row of all three.
    local top
    for _, name in ipairs(CONVERSATION_PANES) do
        local win = w[name].winid
        if follow[name] then
            local last = api.nvim_buf_line_count(w[name].bufnr)
            top = top or bottom_topline(win, last)
            pcall(api.nvim_win_set_cursor, win, { last, win == cur and col_of[name] or 0 })
            api.nvim_win_call(win, function()
                vim.fn.winrestview({ topline = top })
            end)
            -- Scrolling from code leaves the position 'scrollbind' measures from behind,
            -- so the next scroll by hand would move the other columns by the wrong amount.
            local opt = { scope = "local", win = win }
            api.nvim_set_option_value("scrollbind", false, opt)
            api.nvim_set_option_value("scrollbind", true, opt)
        end
    end
end

---Send one line to a live session's solution, the session of the row on screen unless told.
---It goes into the conversation as a row of the Live column's own; nothing is copied into
---Output, which holds only what the solution printed.
---@param line string
---@param tc table? the row
function InteractiveRunner:live_send(line, tc)
    tc = tc or (self.drawn and self.drawn.tc)
    if not talking(tc) then
        return
    end
    tc.session.sol_in:write(line .. "\n")
    log_append(tc, "si", line .. "\n")
    self:update_ui(false)
end

--------------------------------------------------------------------------------
-- Sessions
--------------------------------------------------------------------------------

-- How long a session waits, past its solution's exit, for the end of its output: a child the
-- solution left behind (a shell's) can hold a pipe open for ever.
local LINGER = 200

---Spawn the solution of session `s` with three pipes and forward its output through `cbs`.
---`cbs`: on_stdout(data), on_stderr(data), on_exit(code, signal, over), on_error(msg),
---optional on_timeout() when `cbs.timed` and `self.timeout` are set. A solution printing past
---`maximum_output` is stopped there, and `over` is that limit. The session ends once the
---process is gone and all it printed is read: its exit can come before the last of its output,
---which is still its output, so `LINGER` past the exit it ends whatever is left open.
---@param s table the session
---@param cbs table
function InteractiveRunner:spawn_solution(s, cbs)
    local sol_in, sol_out, sol_err = pipe(), pipe(), pipe()
    s.sol_in = sol_in
    local timer, linger
    -- `done` is the session over, read in the fast context; `settled` is its end handled, on the
    -- main loop after whatever was read before it, which is still to be shown.
    local done, settled = false, false
    local exit_code, exit_signal, lingered = nil, nil, false
    local open = { out = true, err = true }
    local handle
    local limit = tools.output_limit(self.config)
    local within, over = budget(limit, function()
        kill(handle)
    end)

    local function cleanup()
        for _, p in ipairs({ sol_in, sol_out, sol_err }) do
            if p and not p:is_closing() then
                p:close()
            end
        end
        for _, t in ipairs({ timer, linger }) do
            if t and not t:is_closing() then
                t:stop()
                t:close()
            end
        end
    end

    local function finish()
        if done or exit_code == nil or ((open.out or open.err) and not lingered) then
            return
        end
        done = true
        s.sol, s.running = nil, false
        cleanup()
        vim.schedule(function()
            settled = true
            cbs.on_exit(exit_code, exit_signal, over() and limit or nil)
        end)
    end

    handle = uv.spawn(self.r.rc.exec, {
        args = self.r.rc.args,
        cwd = self.rundir,
        env = tools.spawn_env(),
        stdio = { sol_in, sol_out, sol_err },
    }, function(code, signal)
        exit_code, exit_signal = code, signal
        linger = uv.new_timer()
        if linger then
            linger:start(LINGER, 0, function()
                lingered = true
                finish()
            end)
        else
            lingered = true
        end
        finish()
    end)

    if not handle then
        cleanup()
        vim.schedule(function()
            cbs.on_error("could not start solution '" .. tostring(self.r.rc.exec) .. "'")
        end)
        return
    end
    s.sol, s.running = handle, true

    ---Read one of the solution's streams into `forward`, on the main loop, until its end.
    ---@param p uv.uv_pipe_t
    ---@param which "out"|"err"
    ---@param forward fun(data: string)
    local function read(p, which, forward)
        p:read_start(function(err, data)
            if done then
                return
            end
            if err or not data then
                open[which] = false
                return finish()
            end
            if not within(data) then
                return
            end
            vim.schedule(function()
                if not settled then
                    forward(data)
                end
            end)
        end)
    end
    read(sol_out, "out", cbs.on_stdout)
    read(sol_err, "err", cbs.on_stderr)

    if self.timeout and cbs.timed then
        timer = assert(uv.new_timer())
        timer:start(self.timeout, 0, function()
            if not done and exit_code == nil then
                vim.schedule(cbs.on_timeout)
                kill(handle)
            end
        end)
    end
end

---live: you are the interactor. No timeout (human-paced); kill via the UI.
---@param idx integer
---@param on_done fun()
function InteractiveRunner:run_live(idx, on_done)
    local tc = self.tcdata[idx]
    local s = {}
    tc.session = s
    tc.status, tc.hlgroup = "live", "TunaRunning"
    tc.stdout, tc.stderr, tc.log = "", "", {}
    self:update_ui(true)
    -- Joined once the session ends: the columns show the log, so nothing reads them before, and
    -- joined as they arrive they would be copied whole on every piece.
    local out, errs = {}, {}
    local function mine()
        return tc.session == s
    end

    self:spawn_solution(s, {
        on_stdout = function(data)
            if mine() then
                out[#out + 1] = data
                log_append(tc, "so", data)
                self:update_ui(false)
            end
        end,
        on_stderr = function(data)
            if mine() then
                errs[#errs + 1] = data
                log_append(tc, "se", data)
                self:update_ui(false)
            end
        end,
        on_error = function(msg)
            s.sol_in = nil
            if mine() then
                tc.status, tc.hlgroup, tc.stderr = "failed", "TunaWarning", msg
                tc.stdout = table.concat(out)
                log_note(tc, msg)
                self:update_ui(true)
            end
            on_done()
        end,
        on_exit = function(code, signal, over)
            s.sol_in = nil
            if mine() then
                -- You are the judge, so a session that ended on its own is `done`; one stopped
                -- or crashed ends the way a testcase would.
                local ended, hl, words = core.ending({ code = code, signal = signal, killed = tc.killed, over = over })
                tc.stdout, tc.stderr = table.concat(out), table.concat(errs)
                if over then
                    log_note(tc, "[" .. words .. "]")
                end
                tc.status, tc.hlgroup = ended or "done", hl or "TunaDone"
                self:update_ui(true)
            end
            on_done()
        end,
    })
end

---feed: the testcase input plays the interactor, one line per turn.
---@param idx integer
---@param on_done fun()
function InteractiveRunner:run_feed(idx, on_done)
    local tc = self.tcdata[idx]
    local s = {}
    tc.session = s
    local function mine()
        return tc.session == s
    end
    self.active_index = idx
    tc.status, tc.hlgroup = "running", "TunaRunning"
    tc.stdout, tc.stderr = "", ""
    self:update_ui(true)

    local lines = vim.split(tc.stdin or "", "\n", { plain = true })
    if #lines > 0 and lines[#lines] == "" then
        table.remove(lines) -- drop the empty part after a trailing newline
    end
    local li = 0
    local timed_out = false
    local function send_next()
        li = li + 1
        if li > #lines then
            if s.sol_in and not s.sol_in:is_closing() then
                s.sol_in:shutdown()
            end
            return
        end
        if s.sol_in and not s.sol_in:is_closing() then
            s.sol_in:write(lines[li] .. "\n")
        end
    end

    -- What arrives is joined once a tick rather than once a piece: the Output and Errors panes
    -- show it as it streams, and joined piece by piece it would be copied whole every time.
    local pending, flushing = { stdout = {}, stderr = {} }, false
    local function flush()
        for _, field in ipairs({ "stdout", "stderr" }) do
            if #pending[field] > 0 then
                tc[field] = tc[field] .. table.concat(pending[field])
                pending[field] = {}
            end
        end
    end
    local function queue(field, data)
        local parts = pending[field]
        parts[#parts + 1] = data
        if not flushing then
            flushing = true
            vim.schedule(function()
                flushing = false
                if mine() then
                    flush()
                    self:update_ui(false)
                end
            end)
        end
    end

    self:spawn_solution(s, {
        timed = true,
        on_stdout = function(data)
            queue("stdout", data)
            -- One input line per *line* of output: a chunk carrying several newlines
            -- is several completed turns, and answering it with a single line
            -- deadlocked any protocol that prints more than one line per query.
            for _ in data:gmatch("\n") do
                send_next()
            end
        end,
        on_stderr = function(data)
            queue("stderr", data)
        end,
        on_timeout = function()
            timed_out = true
        end,
        on_error = function(msg)
            s.sol_in = nil
            if mine() then
                tc.status, tc.hlgroup, tc.stderr = "failed", "TunaWarning", msg
                self:update_ui(true)
            end
            on_done()
        end,
        on_exit = function(code, signal, over)
            s.sol_in = nil
            if not mine() then
                return on_done()
            end
            flush()
            local ended, hl, words = core.ending({ code = code, signal = signal, timed_out = timed_out, killed = tc.killed, over = over })
            if over then
                tc.stderr = tc.stderr .. (tc.stderr ~= "" and "\n" or "") .. "[" .. words .. "]"
            end
            if ended then
                tc.status, tc.hlgroup = ended, hl
                self:update_ui(true)
                return on_done()
            end
            -- Judged as a testcase is in every mode: with no answer a comparison has nothing
            -- to say (`done`), and a checker of its own still reads the output.
            tc.judging = true
            checker.judge(tc, self.checker, self:effective_compare(), function(correct, message)
                if not mine() then
                    return on_done()
                end
                tc.judging = false
                tc.checker_message = message
                tc.status, tc.hlgroup = core.verdict(correct)
                self:update_ui(true)
                on_done()
            end)
        end,
    })
    -- Prime: many interactive solutions read a line before printing anything.
    send_next()
end

---interactor: cross-wire the solution and the interactor; the interactor rules. The
---conversation is laid out like live's: the solution's output in Output, the interactor's
---in Live, and the interactor's stderr with tuna's own notes in Errors.
---@param idx integer
---@param on_done fun()
function InteractiveRunner:run_interactor(idx, on_done)
    local tc = self.tcdata[idx]
    local s = {}
    tc.session = s
    local function mine()
        return tc.session == s
    end
    self.active_index = idx
    tc.status, tc.hlgroup = "running", "TunaRunning"
    tc.stdout, tc.stderr, tc.log = "", "", {}
    self:update_ui(true)

    local input_file = utils.temp_file(tc.stdin)
    local answer_file = utils.temp_file(tc.expected)
    local int_args = tools.expand_args(
        self.interactor.args,
        { INPUT = input_file, OUTPUT = "/dev/null", ANSWER = answer_file }
    )

    local sol_in, sol_out = pipe(), pipe()
    local int_in, int_out, int_err = pipe(), pipe(), pipe()
    local sol_handle, int_handle, timer
    local done, verdict, int_exited, failed = false, nil, false, false
    local limit = tools.output_limit(self.config)
    local over = false
    -- Joined once the session ends, as in live: the columns show the log. tuna's own notes go
    -- into `errs` too, in the order they come.
    local out, errs = {}, {}
    -- The session's end handled, on the main loop: what was read before it is still shown.
    local settled = false

    local function safe_close(h)
        if h and not h:is_closing() then
            h:close()
        end
    end
    ---End the session. `status` is how it ended when that was not the interactor's verdict:
    ---the solution crashing, or the time running out.
    ---@param status string?
    ---@param hl string?
    local function finish(status, hl)
        if done then
            return
        end
        done = true
        if timer then
            timer:stop()
            safe_close(timer)
        end
        kill(sol_handle)
        kill(int_handle)
        for _, p in ipairs({ sol_in, sol_out, int_in, int_out, int_err }) do
            safe_close(p)
        end
        utils.delete_file(input_file)
        utils.delete_file(answer_file)
        s.sol, s.int, s.running = nil, nil, false
        vim.schedule(function()
            settled = true
            if not mine() then
                return on_done()
            end
            tc.stdout, tc.stderr = table.concat(out), table.concat(errs)
            if failed then
                -- The session never happened (the interactor would not start): that is
                -- not a `done`, which reads as a session that ran and was not judged.
                tc.status, tc.hlgroup = "failed", "TunaWarning"
            elseif tc.killed then
                tc.status, tc.hlgroup = "killed", "TunaWarning"
            elseif status then
                tc.status, tc.hlgroup = status, hl
            else
                tc.status, tc.hlgroup = core.verdict(verdict)
            end
            self:update_ui(true)
            on_done()
        end)
    end

    sol_handle = uv.spawn(self.r.rc.exec, {
        args = self.r.rc.args,
        cwd = self.rundir,
        env = tools.spawn_env(),
        stdio = { sol_in, sol_out, nil },
    }, function(code, signal)
        safe_close(sol_handle)
        sol_handle = nil
        local ended, hl, words = core.ending({ code = code, signal = signal })
        if ended and not int_exited and not done and not over then
            local note = "[solution " .. words .. "]"
            errs[#errs + 1] = "\n" .. note
            if mine() then
                log_note(tc, note)
            end
            finish(ended, hl)
        end
    end)
    if not sol_handle then
        for _, p in ipairs({ sol_in, sol_out, int_in, int_out, int_err }) do
            safe_close(p)
        end
        tc.status, tc.hlgroup, tc.stderr = "failed", "TunaWarning", "could not start solution"
        log_note(tc, tc.stderr)
        self:update_ui(true)
        return on_done()
    end
    s.sol, s.running = sol_handle, true

    int_handle = uv.spawn(self.interactor.exec, {
        args = int_args,
        cwd = self.rundir,
        env = tools.spawn_env(),
        stdio = { int_in, int_out, int_err },
    }, function(code, signal)
        safe_close(int_handle)
        int_handle = nil
        int_exited = true
        verdict = (code == 0 and (not signal or signal == 0))
        -- Stopped at the limit, the session's end is already on its way.
        if not over then
            finish()
        end
    end)
    if not int_handle then
        local said = "could not start interactor '" .. tostring(self.interactor.exec) .. "'"
        errs[#errs + 1] = said
        if mine() then
            log_note(tc, said)
        end
        failed = true
        finish()
        return
    end
    s.int = int_handle

    -- What the two print together has one budget. Past it they are stopped, and the session
    -- ended once what they printed before is shown, on the main loop.
    local within = budget(limit, function()
        over = true
        kill(sol_handle)
        kill(int_handle)
        vim.schedule(function()
            local ended, hl, words = core.ending({ over = limit })
            errs[#errs + 1] = "\n[" .. words .. "]"
            if mine() then
                log_note(tc, "[" .. words .. "]")
            end
            finish(ended, hl)
        end)
    end)

    -- Cross-wire, teeing each side of the exchange into the transcript.
    sol_out:read_start(function(err, data)
        if err or done then
            return
        end
        if data and not within(data) then
            return
        end
        if data then
            if not int_in:is_closing() then
                int_in:write(data)
            end
            vim.schedule(function()
                if not settled and mine() then
                    out[#out + 1] = data
                    log_append(tc, "so", data)
                    self:update_ui(false)
                end
            end)
        elseif not int_in:is_closing() then
            int_in:shutdown()
        end
    end)
    int_out:read_start(function(err, data)
        if err or done then
            return
        end
        if data and not within(data) then
            return
        end
        if data then
            if not sol_in:is_closing() then
                sol_in:write(data)
            end
            vim.schedule(function()
                if not settled and mine() then
                    log_append(tc, "si", data)
                    self:update_ui(false)
                end
            end)
        elseif not sol_in:is_closing() then
            sol_in:shutdown()
        end
    end)
    int_err:read_start(function(err, data)
        if not err and data and not done and within(data) then
            vim.schedule(function()
                if not settled and mine() then
                    errs[#errs + 1] = data
                    log_append(tc, "se", data)
                    self:update_ui(false)
                end
            end)
        end
    end)

    if self.timeout then
        timer = assert(uv.new_timer())
        timer:start(self.timeout, 0, function()
            if not done and not over then
                local ended, hl, words = core.ending({ timed_out = true }, self.timeout)
                errs[#errs + 1] = "\n[" .. words .. "]"
                if mine() then
                    log_note(tc, "[" .. words .. "]")
                end
                finish(ended, hl)
            end
        end)
    end
end

---Run one session for row `idx`, dispatching on the source.
---@param idx integer
---@param on_done fun()
---@param quiet boolean? leave the board where it is (live's sessions after the first)
function InteractiveRunner:run_one_session(idx, on_done, quiet)
    -- A session still on the row (one its run key started while the others ran in turn) goes
    -- first: replaced without being killed, nothing could stop it any more.
    self:drop_session(self.tcdata[idx])
    self:reset_row(self.tcdata[idx])
    if self.source == "interactor" then
        self:run_interactor(idx, on_done)
    elseif self.source == "feed" then
        self:run_feed(idx, on_done)
    else
        self:run_live(idx, on_done)
    end
    -- The row being talked to is the row to look at: its columns are where the conversation
    -- appears, and in live it is the only row whose Live column can be typed into. Every
    -- other mode's rows can be read at leisure while they run, and the UI opens on whichever
    -- it opened on; here one row *is* the session, so the session takes the cursor with it,
    -- as the board follows a run in every mode (`follow_row`).
    if self.ui and not quiet then
        self.ui:follow_row(idx)
    end
end


---Run every row's session: live's all at once, each waiting on you on its own row, the board
---following the first; the other sources' one after another.
function InteractiveRunner:run_sessions()
    local order = {}
    for i, tc in ipairs(self.tcdata) do
        if not tc.compile then
            self:drop_session(tc)
            self:reset_row(tc)
            order[#order + 1] = i
        end
    end
    self.completed = #order == 0
    self.stopped = false
    if self.source == "live" then
        for k, i in ipairs(order) do
            self:claim()
            self:run_one_session(i, function()
                core.save_buffer_verdict(self.bufnr, self.tcdata)
                self:release()
                self:update_ui(true)
            end, k > 1)
        end
        return
    end
    -- This run's own: a run started after it replaces it, and the session it let go, ending
    -- later, must not carry it on beside the new one.
    local run = {}
    self.sequence = run
    local k = 0
    local function step()
        if self.sequence ~= run then
            return
        end
        k = k + 1
        if k > #order or self.stopped then
            for j = k, #order do -- stopped: the sessions after this one never started
                self.tcdata[order[j]].status, self.tcdata[order[j]].hlgroup = "not run", "TunaDone"
            end
            self.sequence = nil
            if (self.claims or 0) == 0 then
                self.completed = true
            end
            core.save_buffer_verdict(self.bufnr, self.tcdata)
            self:update_ui(true)
            return
        end
        self:run_one_session(order[k], step)
    end
    step()
end

---Add a live session's row and hold a session there: `n`, for another conversation with the
---same build, beside any still running, as a testcase row with nothing on disk behind it. The
---other sources' rows are testcases, which `n` does not add here.
---@return boolean handled whether `n` means this here
function InteractiveRunner:add_row()
    if self.source ~= "live" then
        return false
    end
    -- A session started now would run a program its compiler is still writing.
    local build = self.tcdata[1]
    if build and build.compile and not self.preloaded and (build.exit_code == nil or self:build_pending(build)) then
        utils.notify("interactive: wait for the build to finish before starting a session.", "WARN")
        return true
    end
    local n = 1
    for _, tc in ipairs(self.tcdata) do
        if tc.live then
            n = math.max(n, tc.live + 1)
        end
    end
    table.insert(self.tcdata, live_row(n))
    local idx = #self.tcdata
    if self.ui then
        self.ui:goto_row(idx)
    end
    self:run_single(idx)
    return true
end

---The keys the Live column binds itself in live, which the board leaves to it.
---@param name string the pane
---@return string[]?
function InteractiveRunner:pane_keys(name)
    if name == "si" and self.source == "live" then
        return TYPING_KEYS
    end
    return nil
end

---What `n` adds, in the legend.
---@return string?
function InteractiveRunner:new_row_words()
    return self.source == "live" and "new session" or nil
end

---Build the testcase rows (plus the solution compile row).
function InteractiveRunner:load_rows()
    self.tcdata = {}
    if self.compile_entry then
        table.insert(self.tcdata, self.compile_entry)
    end
    -- In live you play the other side, so no testcase has anything to give a session: a row
    -- per testcase would only be the same conversation to hold once each. One session, and
    -- another when asked for (`add_row`).
    if self.source == "live" then
        table.insert(self.tcdata, live_row(1))
        return
    end
    local tctbl = testcases.buf_get_testcases(self.bufnr)
    local nums = {}
    if self.list then
        for _, s in ipairs(self.list) do
            local n = tonumber(s)
            if n and tctbl[n] then
                nums[#nums + 1] = n
            else
                utils.notify("interactive: testcase " .. tostring(s) .. " doesn't exist.")
            end
        end
    else
        nums = vim.tbl_keys(tctbl)
        table.sort(nums)
    end
    if #nums == 0 then
        -- Nothing to feed/replay: a single blank session (you just interact). In `feed`,
        -- where testcases are editable, it is flagged `bare` like the normal runner's row
        -- of the same kind: nothing is on disk behind it *yet*, which is not the same as a
        -- testcase that went missing, and typing into it is how the first one is written.
        table.insert(self.tcdata, {
            tcnum = 0,
            bare = self.source == "feed" or nil,
            stdin = "",
            expected = nil,
            status = "",
            hlgroup = "TunaRunning",
        })
    else
        for _, n in ipairs(nums) do
            table.insert(self.tcdata, {
                tcnum = n,
                stdin = tctbl[n].input or "",
                expected = tctbl[n].output,
                status = "",
                hlgroup = "TunaRunning",
            })
        end
    end
end

--------------------------------------------------------------------------------
-- Helpers + entry point
--------------------------------------------------------------------------------

---Run interactive judging for a buffer's solution.
---@param bufnr integer? defaults to the current buffer
---@param args string[]? a leading source keyword (live|feed|interactor) then testcase numbers
---@param opts { show_only: boolean? }? open the UI with the rows listed and nothing run
function M.run(bufnr, args, opts)
    opts = opts or {}
    bufnr = bufnr or api.nvim_get_current_buf()
    config.load_buffer_config(bufnr)

    local r = runner.new(bufnr)
    if not r then
        return
    end
    local cfg = r.config
    local path = api.nvim_buf_get_name(bufnr)
    if not opts.show_only then
        tools.save_sources(bufnr, cfg) -- save the solution (interactor saved in tools.prepare)
    end

    -- Pull a leading source keyword out of the args (the rest are testcase numbers). A
    -- source typed now is forced and runs as typed, `auto` makes it automatic again.
    local list = args and vim.deepcopy(args) or nil
    local typed
    if list and list[1] and (vim.tbl_contains(tools.SOURCES, list[1]) or list[1] == "auto") then
        typed = table.remove(list, 1)
        tools.set_source(path, typed ~= "auto" and typed or nil)
    end
    if list and #list == 0 then
        list = nil
    end
    local source, note
    if typed and typed ~= "auto" then
        source = typed
    else
        source, note = tools.resolve_source(path, cfg)
    end
    if source == "live" and list then
        utils.notify("interactive: live plays no testcase, so the numbers are left out.", "INFO")
        list = nil
    end

    local interactor
    if source == "interactor" then
        local missing
        interactor, missing = tools.helper("interactor", path, cfg)
        if not interactor then
            if missing then
                utils.notify("interactive: " .. missing .. ", or run ':Tuna run interactive live' or 'feed'.", "WARN")
            else
                offer_interactor(bufnr)
            end
            return
        end
    end
    if note then
        utils.notify("interactive: " .. note .. ".", "INFO")
    end

    local timeout = core.time_limit(cfg)
    local rundir = r.running_directory
    utils.ensure_directory(rundir)

    if M.active[bufnr] then
        M.active[bufnr]:kill_all_processes() -- a session left running waits on its input forever
        M.active[bufnr]:delete_ui()
    end

    local ir = setmetatable({
        config = cfg,
        bufnr = bufnr,
        r = r,
        checker = r.checker,
        compare_method = r.compare_method, -- carry the per-buffer `:Tuna compare` override
        source = source,
        -- `feed` replays a stored testcase, so it is edited like one; see `layout`.
        editable_testcases = source == "feed",
        interactor = interactor,
        list = list,
        subset = list ~= nil,
        rundir = rundir,
        timeout = timeout,
        mode = "interactive",
        compile_entry = r.compile and core.compile_row() or nil,
        tcdata = {},
        completed = false,
    }, InteractiveRunner)
    core.register(M.active, bufnr, ir)

    -- What this run compiles, declared before the board opens so the build step is laid out
    -- once: the solution is the compile row itself, the interactor is one when it plays the
    -- other side, and the checker is one whenever it is a program of its own.
    ir:plan_builds({ source == "interactor" and ir.interactor or false, ir:judges() and ir.checker or false })

    -- Rows first, and marked before the board opens: the UI lays its grid out for the row it
    -- opens on, which an empty list leaves as line 1, and which is the build step while a run
    -- is building but a testcase when the rows are only being listed.
    ir:load_rows()
    if opts.show_only then
        -- Listed, not run: a row's run key builds the solution and, when it plays the other
        -- side, the interactor, then runs (`built_first`); a run of the whole set builds anyway.
        ir:mark_not_run()
        ir.completed = true
        ir:defer_build(function(cont)
            ir:build_all(source == "interactor" and { ir.interactor } or {}, cont)
        end)
        return ir:open_on()
    end
    ir:open_on(function()
        ir:run_testcases()
    end)
end

---Open the interactive UI for a buffer with its rows listed and nothing run.
---@param bufnr integer
function M.show(bufnr)
    M.run(bufnr, nil, { show_only = true })
end

-- The pure half of the conversation, for the test suite.
M._test = {
    log_append = log_append,
    conversation = conversation,
    talking = talking,
    SHOWN_ROWS = SHOWN_ROWS,
    TRIM_ROWS = TRIM_ROWS,
}

return M
