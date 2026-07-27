-- lua/tuna/runner_ui/init.lua
--
-- The runner results UI. It owns a set of windows (a testcase selector plus four
-- detail panes: stdout/expected/stdin/stderr), keeps them in sync with the
-- `TCRunner`'s `tcdata`, and wires the interactive keymaps (run again, kill,
-- view in a bigger popup, toggle diff, close).
--
-- The actual window geometry is delegated to an "interface" module — `popup`
-- (floats) or `split` (real splits) — selected by `runner_ui.interface`. This
-- module is interface-agnostic: it only touches `windows[name].bufnr/winid`.
--
-- Design note vs competitest: all displayed content lives in the runner's
-- `tcdata`, so we don't bother hiding-and-restoring windows. Closing tears the UI
-- down; showing rebuilds it and re-renders from `tcdata`. That removes a lot of
-- nui-era state bookkeeping while looking identical to the user.

local api = vim.api
local utils = require("tuna.utils")
local diff = require("tuna.diff")
local SKIP = require("tuna.runner.core").SKIP

local M = {}

local ns = api.nvim_create_namespace("tuna_runner_ui")
-- Its own namespace, so the diff can be painted and cleared without touching the
-- selector's status highlights.
local diff_ns = api.nvim_create_namespace("tuna_runner_diff")
local augroup_counter = 0

-- The four detail panes a viewer can enlarge, and the friendly names used in
-- selector rows / viewer titles.
local detail_windows = { "so", "eo", "si", "se" }

---@class tuna.RunnerUI
---@field runner tuna.TCRunner
---@field config table
---@field interface table popup or split interface
---@field windows table<string, { bufnr: integer, winid: integer, title: string }>
---@field ui_visible boolean
---@field update_windows boolean redraw the selector on next update
---@field update_details boolean redraw the detail panes on next update
---@field update_testcase integer? selected testcase (selector line)
---@field diff_view boolean
---@field viewer_winid integer?
---@field viewer_content string? which detail window the viewer is showing
---@field make_viewer_visible boolean open the viewer on the next update
---@field restore_winid integer?
---@field latest_compile_token integer? start time of the last auto-shown compile failure
local RunnerUI = {}
RunnerUI.__index = RunnerUI

---Create a runner UI for `runner` (does not show it yet).
---@param runner tuna.TCRunner
---@return tuna.RunnerUI?
function M.new(runner)
    local interface
    local kind = runner.config.runner_ui.interface
    if kind == "popup" then
        interface = require("tuna.runner_ui.popup")
    elseif kind == "split" then
        interface = require("tuna.runner_ui.split")
    else
        utils.notify("runner_ui: unknown interface " .. vim.inspect(kind) .. ".")
        return nil
    end

    return setmetatable({
        runner = runner,
        config = runner.config,
        interface = interface,
        windows = {},
        ui_visible = false,
        update_windows = false,
        update_details = false,
        update_testcase = nil,
        diff_view = false,
        viewer_winid = nil,
        viewer_content = nil,
        make_viewer_visible = false,
        restore_winid = nil,
    }, RunnerUI)
end

---@private
---Normalise a mapping spec (string or list) to a list of keys.
local function as_list(maps)
    return type(maps) == "string" and { maps } or maps
end

---@private
---The testcase index under the selector cursor (1:1 with `tcdata`; the Compile
---pseudo-testcase, when present, is row 1).
function RunnerUI:cursor_tc()
    if not (self.windows.tc and api.nvim_win_is_valid(self.windows.tc.winid)) then
        return 1
    end
    return api.nvim_win_get_cursor(self.windows.tc.winid)[1]
end

---@private
---Which selector row the UI should open on. The first testcase, whenever the Compile
---step has nothing to say: an empty compile row leaves four empty panes in front of
---someone who opened the UI to read a verdict — or, before any run, to read the
---testcase itself. Row 1 (Compile) is kept for the two cases where it is the row worth
---reading: a compilation that printed warnings or errors, and a run still in flight,
---where the cursor must not be moved out from under the user as results land.
---@return integer
function RunnerUI:initial_row()
    local first = self.runner.tcdata[1]
    if not first or first.tcnum ~= "Compile" then
        return 1
    end
    if (first.stdout or "") ~= "" or (first.stderr or "") ~= "" then
        return 1
    end
    local tc = self.runner.tcdata[2]
    if not tc then
        return 1
    end
    -- Settled rows only: `running`/`judging` mean a run is under way, so the compile
    -- row is still the one being written to.
    for _, row in ipairs({ first, tc }) do
        if row.running or row.judging then
            return 1
        end
    end
    return 2
end

---Show the UI, building it if needed and focusing the selector.
function RunnerUI:show_ui()
    if self.ui_visible then
        api.nvim_set_current_win(self.windows.tc.winid)
        return
    end

    self.restore_winid = self.restore_winid or api.nvim_get_current_win()
    -- The "Run" pane is sized to the runner's (stable) status-line count.
    local status_height = math.max(1, #self:status_lines())
    self.interface.init_ui(self.windows, self.config, self.restore_winid, status_height)
    self.ui_visible = true
    self:update_status_line()

    augroup_counter = augroup_counter + 1
    self.augroup = api.nvim_create_augroup("tuna_runner_ui_" .. augroup_counter, { clear = true })

    local mappings = self.config.runner_ui.mappings

    local function close_or_viewer()
        if self.viewer_winid then
            self:close_viewer()
        else
            self:delete()
        end
    end

    -- Close maps on every window; ":q" handled per-window via WinClosed keyed on
    -- the *window id* (not buffer — the viewer borrows a detail pane's buffer, so
    -- a buffer-keyed autocmd would tear the UI down when the viewer is closed).
    local switch = as_list(self.config.switch_window_keys or {})
    local dirs = { "h", "j", "k", "l" }
    for _, w in pairs(self.windows) do
        for _, key in ipairs(as_list(mappings.close)) do
            vim.keymap.set("n", key, close_or_viewer, { buffer = w.bufnr, nowait = true })
        end
        for i, key in ipairs(switch) do
            local d = dirs[i]
            if d then
                vim.keymap.set("n", key, function()
                    self:focus_dir(d)
                end, { buffer = w.bufnr, nowait = true })
            end
        end
        -- A pane the layout left out has a buffer but no window, so there is nothing
        -- to watch for it (its content is still reachable through the viewer).
        if w.winid then
            api.nvim_create_autocmd("WinClosed", {
                group = self.augroup,
                pattern = tostring(w.winid),
                callback = function()
                    self:delete()
                end,
            })
        end
    end

    -- Selector-only actions.
    local tc_buf = self.windows.tc.bufnr
    local function map_tc(action, fn)
        for _, key in ipairs(as_list(mappings[action])) do
            vim.keymap.set("n", key, fn, { buffer = tc_buf, nowait = true })
        end
    end

    map_tc("kill", function()
        self.runner:kill_process(self:cursor_tc())
    end)
    map_tc("kill_all", function()
        self.runner:kill_all_processes()
    end)
    map_tc("run_again", function()
        local idx = self:cursor_tc()
        self.runner:kill_process(idx)
        vim.schedule(function()
            self.runner:run_single(idx)
        end)
    end)
    map_tc("run_all_again", function()
        self.runner:kill_all_processes()
        vim.schedule(function()
            self.runner:run_testcases()
        end)
    end)
    map_tc("toggle_diff", function()
        self:toggle_diff_view()
    end)
    map_tc("view_stdout", function()
        self:show_viewer("so")
    end)
    map_tc("view_output", function()
        self:show_viewer("eo")
    end)
    map_tc("view_input", function()
        self:show_viewer("si")
    end)
    map_tc("view_stderr", function()
        self:show_viewer("se")
    end)

    -- Moving in the selector switches which testcase the detail panes show.
    api.nvim_create_autocmd("CursorMoved", {
        group = self.augroup,
        buffer = tc_buf,
        callback = function()
            local idx = self:cursor_tc()
            if idx ~= self.update_testcase then
                self.update_testcase = idx
                self.update_details = true
                self:update_ui()
            end
        end,
    })

    api.nvim_set_current_win(self.windows.tc.winid)
    self.update_windows = true
    local initial = self:initial_row()
    self.update_testcase = initial > 1 and initial or self.update_testcase
    self:update_ui()

    if initial > 1 then
        -- The selector is filled on a scheduled tick, so the row only exists by the
        -- time this (queued after it) runs.
        vim.schedule(function()
            if self.ui_visible and self.windows.tc and api.nvim_win_is_valid(self.windows.tc.winid) then
                local line_count = api.nvim_buf_line_count(self.windows.tc.bufnr)
                api.nvim_win_set_cursor(self.windows.tc.winid, { math.min(initial, line_count), 0 })
            end
        end)
    end

    -- A rebuilt UI (after a resize) keeps the diff it had. Only the binding is
    -- re-armed here: the panes are filled on the scheduled render queued just above,
    -- which paints the marks itself rather than painting over empty buffers.
    if self.diff_view then
        self:set_diff_bind(true)
    end

    -- Let the runner augment the freshly-built UI (interactive makes the Input pane
    -- editable and wires its send-line keymap here).
    if self.runner.on_ui_shown then
        self.runner:on_ui_shown(self)
    end
end

---@private
---Bind the two compared panes together, so scrolling or moving in one follows in
---the other. With a positional diff the panes are already line-for-line aligned, so
---this needs none of the filler lines `:diffthis` inserts to fake that alignment.
---@param enable boolean
function RunnerUI:set_diff_bind(enable)
    for _, name in ipairs({ "so", "eo" }) do
        local w = self.windows[name]
        if w and w.winid and api.nvim_win_is_valid(w.winid) then
            vim.wo[w.winid].scrollbind = enable
            vim.wo[w.winid].cursorbind = enable
        end
    end
    if enable and self.windows.so and api.nvim_win_is_valid(self.windows.so.winid) then
        api.nvim_win_call(self.windows.so.winid, function()
            vim.cmd("syncbind")
        end)
    end
end

---@private
---Paint one pane's diff marks. Line highlights run to the edge of the window (as a
---diff does), with the disagreeing spans on top of them.
---@param bufnr integer?
---@param marks table<integer, tuna.DiffMark>
local function paint_diff(bufnr, marks)
    if not (bufnr and api.nvim_buf_is_valid(bufnr)) then
        return
    end
    local last = api.nvim_buf_line_count(bufnr)
    for lnum, mark in pairs(marks) do
        if lnum <= last then
            local line = api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
            api.nvim_buf_set_extmark(bufnr, diff_ns, lnum - 1, 0, {
                end_col = #line,
                hl_group = mark.hl,
                hl_eol = true,
                priority = 190,
            })
            for _, span in ipairs(mark.spans) do
                api.nvim_buf_set_extmark(bufnr, diff_ns, lnum - 1, math.min(span[1], #line), {
                    end_col = math.min(span[2], #line),
                    hl_group = diff.TEXT,
                    priority = 200,
                })
            end
        end
    end
end

---@private
---Re-highlight the Output and Expected Output panes for the selected testcase.
---Cheap enough to redo on every render, which is what keeps the marks correct as
---the selection moves or a re-run replaces the output.
---@return integer? first the first differing line, if any
function RunnerUI:render_diff()
    local so, eo = self.windows.so, self.windows.eo
    for _, w in ipairs({ so, eo }) do
        if w and w.bufnr and api.nvim_buf_is_valid(w.bufnr) then
            api.nvim_buf_clear_namespace(w.bufnr, diff_ns, 0, -1)
        end
    end
    if not (self.diff_view and so and eo) then
        return nil
    end

    local tc = self.runner.tcdata[self.update_testcase or 1]
    if not tc then
        return nil
    end
    -- Through the pane seam, so a mode that rewrites these panes is diffed on what
    -- it actually shows; a pane it owns outright is left alone.
    local output = self.runner:pane_content(tc, "so")
    local expected = self.runner:pane_content(tc, "eo")
    if output == SKIP or expected == SKIP or expected == nil then
        return nil -- nothing to compare against (no expected output, or a mode's own pane)
    end

    local res = diff.compute(output, expected, self.runner:effective_compare())
    paint_diff(so.bufnr, res.out)
    paint_diff(eo.bufnr, res.exp)
    return res.first
end

---Toggle the comparison between the Output and Expected Output panes.
function RunnerUI:toggle_diff_view()
    self.diff_view = not self.diff_view
    local first = self:render_diff()
    self:set_diff_bind(self.diff_view)
    if first then
        -- Land on the first disagreement: with a hundred lines of output, finding it
        -- is the whole reason the diff was asked for.
        for _, w in ipairs({ self.windows.so, self.windows.eo }) do
            if w and w.winid and api.nvim_win_is_valid(w.winid) then
                local line_count = api.nvim_buf_line_count(w.bufnr)
                pcall(api.nvim_win_set_cursor, w.winid, { math.min(first, line_count), 0 })
            end
        end
    end
end

---@private
function RunnerUI:disable_diff_view()
    self:set_diff_bind(false)
    for _, name in ipairs({ "so", "eo" }) do
        local w = self.windows[name]
        if w and w.bufnr and api.nvim_buf_is_valid(w.bufnr) then
            api.nvim_buf_clear_namespace(w.bufnr, diff_ns, 0, -1)
        end
    end
end

---@private
---Close the viewer popup (keeping the detail buffer it borrowed).
function RunnerUI:close_viewer()
    if self.viewer_winid and api.nvim_win_is_valid(self.viewer_winid) then
        api.nvim_win_close(self.viewer_winid, true)
    end
    self.viewer_winid = nil
    if self.windows.tc and api.nvim_win_is_valid(self.windows.tc.winid) then
        api.nvim_set_current_win(self.windows.tc.winid)
    end
end

---@private
---Open (or retarget) the viewer: a large float showing one detail pane's buffer.
---@param content string? detail window name; nil keeps the current one
function RunnerUI:show_viewer(content)
    self.viewer_content = content or self.viewer_content
    if not self.viewer_content then
        return
    end
    local source = self.windows[self.viewer_content]
    if not source then
        return
    end

    if self.viewer_winid and api.nvim_win_is_valid(self.viewer_winid) then
        api.nvim_win_set_buf(self.viewer_winid, source.bufnr)
        api.nvim_win_set_config(self.viewer_winid, { title = source.title, title_pos = "center" })
        api.nvim_set_current_win(self.viewer_winid)
        return
    end

    local vim_width, vim_height = utils.get_ui_size()
    local vcfg = self.config.runner_ui.viewer
    local band_row, band_h = utils.float_band()
    local width = math.floor(vim_width * vcfg.width + 0.5)
    local height = math.max(1, math.min(math.floor(vim_height * vcfg.height + 0.5), band_h - 2))
    self.viewer_winid = api.nvim_open_win(source.bufnr, true, {
        relative = "editor",
        width = width,
        height = height,
        col = math.floor((vim_width - width) / 2),
        row = band_row + math.max(0, math.floor((band_h - height - 2) / 2)),
        border = self.config.floating_border,
        title = source.title,
        title_pos = "center",
        style = "minimal",
        zindex = 60, -- above the popup grid (50)
    })
    require("tuna.utils").set_border_highlight(self.viewer_winid, self.config.floating_border_highlight)
    vim.wo[self.viewer_winid].number = vcfg.show_nu
    vim.wo[self.viewer_winid].relativenumber = vcfg.show_rnu
    vim.wo[self.viewer_winid].wrap = false
    -- The source buffer already maps the close key to close_or_viewer (set in
    -- show_ui), which closes the viewer when it's open — no extra keymap needed.
    -- Handle the viewer being closed with ":q" so our state stays consistent.
    api.nvim_create_autocmd("WinClosed", {
        group = self.augroup,
        pattern = tostring(self.viewer_winid),
        once = true,
        callback = function()
            self.viewer_winid = nil
        end,
    })
end

---Close the UI entirely.
function RunnerUI:hide_ui()
    self:delete()
end

---@private
---Tear down every window/buffer and restore focus.
function RunnerUI:delete()
    if not self.ui_visible then
        return
    end
    self.ui_visible = false
    if self.augroup then
        pcall(api.nvim_del_augroup_by_id, self.augroup)
        self.augroup = nil
    end
    self:disable_diff_view()
    if self.viewer_winid and api.nvim_win_is_valid(self.viewer_winid) then
        api.nvim_win_close(self.viewer_winid, true)
    end
    self.viewer_winid = nil
    for _, w in pairs(self.windows) do
        if w.winid and api.nvim_win_is_valid(w.winid) then
            pcall(api.nvim_win_close, w.winid, true)
        end
        if w.bufnr and api.nvim_buf_is_valid(w.bufnr) then
            pcall(api.nvim_buf_delete, w.bufnr, { force = true })
        end
    end
    self.windows = {}
    if self.restore_winid and api.nvim_win_is_valid(self.restore_winid) then
        api.nvim_set_current_win(self.restore_winid)
    end
end

---Rebuild the UI after a `VimResized`, preserving the selected testcase.
function RunnerUI:resize_ui()
    if not self.ui_visible then
        return
    end
    local cursor = self:cursor_tc()
    local viewer_was = self.viewer_content
    local viewer_visible = self.viewer_winid ~= nil
    local restore = self.restore_winid
    self:delete()
    self.restore_winid = restore
    self:show_ui()
    -- show_ui repopulates the selector on a scheduled tick; restore the cursor
    -- (and the viewer) afterwards so the line is actually present.
    vim.schedule(function()
        if self.windows.tc and api.nvim_win_is_valid(self.windows.tc.winid) then
            local line_count = api.nvim_buf_line_count(self.windows.tc.bufnr)
            api.nvim_win_set_cursor(self.windows.tc.winid, { math.min(cursor, line_count), 0 })
        end
        if viewer_visible then
            self:show_viewer(viewer_was)
        end
    end)
end

---Show an ad-hoc message (e.g. a compilation error) in a large float, closable
---with the same keys as the viewer. Independent of the viewer's state.
---@param title string
---@param text string
function RunnerUI:show_message(title, text)
    local buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text or "", "\n", { plain = true }))
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = "tuna"

    local vim_width, vim_height = utils.get_ui_size()
    local band_row, band_h = utils.float_band()
    local vcfg = self.config.runner_ui.viewer
    local width = math.floor(vim_width * vcfg.width + 0.5)
    local height = math.max(1, math.min(math.floor(vim_height * vcfg.height + 0.5), band_h - 2))
    local win = api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        col = math.floor((vim_width - width) / 2),
        row = band_row + math.max(0, math.floor((band_h - height - 2) / 2)),
        border = self.config.floating_border,
        title = title,
        title_pos = "center",
        style = "minimal",
        zindex = 70,
    })
    utils.set_border_highlight(win, self.config.floating_border_highlight)
    vim.wo[win].wrap = false
    for _, key in ipairs(as_list(self.config.runner_ui.mappings.close)) do
        vim.keymap.set("n", key, function()
            if api.nvim_win_is_valid(win) then
                api.nvim_win_close(win, true)
            end
        end, { buffer = buf, nowait = true })
    end
end

---@private
---Pad/truncate `str` to display width `len`.
local function fit(len, str)
    local w = vim.fn.strwidth(str)
    if w <= len then
        return str .. string.rep(" ", len - w)
    end
    return vim.fn.strcharpart(str, 0, len - 1) .. "…"
end

---@private
---The lines shown in the "Run" status pane: the run mode and verdict source, then
---any runner-specific tail (e.g. the stress iteration/save counters). The compile
---step is *not* here — it's a testcase row, so its warnings are viewable. The
---count is stable for a given runner, so it can size the pane at build time.
---@return string[]
function RunnerUI:status_lines()
    -- Each entry is a { label, value } pair; the colons are aligned by padding
    -- every label to the widest one.
    local entries = {
        { "mode", self.runner.mode or "normal" },
        { "judge", self.runner.judge_label and self.runner:judge_label() or "builtin" },
    }
    if self.runner.status_tail then
        vim.list_extend(entries, self.runner:status_tail())
    end

    local width = 0
    for _, e in ipairs(entries) do
        width = math.max(width, #e[1])
    end
    local lines = {}
    for _, e in ipairs(entries) do
        lines[#lines + 1] = string.format("%-" .. width .. "s: %s", e[1], e[2])
    end
    return lines
end

---@private
---Fill the "Run" status pane. Its own rectangle above the Testcases pane, in both
---the popup and split interfaces.
function RunnerUI:update_status_line()
    local w = self.windows.st
    if not (w and w.bufnr and api.nvim_buf_is_valid(w.bufnr)) then
        return
    end
    vim.bo[w.bufnr].modifiable = true
    api.nvim_buf_set_lines(w.bufnr, 0, -1, false, self:status_lines())
    vim.bo[w.bufnr].modifiable = false
end

---@private
---Move focus to the nearest pane in direction `dir` ("h"/"j"/"k"/"l"), chosen by
---window geometry. Works for the floating (popup) interface too, where the
---built-in `<C-w>hjkl` motions don't cross floating windows.
---@param dir string
function RunnerUI:focus_dir(dir)
    local cur = api.nvim_get_current_win()
    local from, targets = nil, {}
    for _, name in ipairs({ "tc", "so", "eo", "si", "se", "st" }) do
        local w = self.windows[name]
        if w and w.winid and api.nvim_win_is_valid(w.winid) then
            local pos = api.nvim_win_get_position(w.winid)
            local t = {
                winid = w.winid,
                r = pos[1] + api.nvim_win_get_height(w.winid) / 2,
                c = pos[2] + api.nvim_win_get_width(w.winid) / 2,
            }
            targets[#targets + 1] = t
            if w.winid == cur then
                from = t
            end
        end
    end
    if not from then
        return
    end
    local best, bestscore
    for _, t in ipairs(targets) do
        if t.winid ~= cur then
            local dr, dc = t.r - from.r, t.c - from.c
            local score
            if dir == "h" and dc < -0.5 then
                score = -dc + 3 * math.abs(dr)
            elseif dir == "l" and dc > 0.5 then
                score = dc + 3 * math.abs(dr)
            elseif dir == "k" and dr < -0.5 then
                score = -dr + 3 * math.abs(dc)
            elseif dir == "j" and dr > 0.5 then
                score = dr + 3 * math.abs(dc)
            end
            if score and (not bestscore or score < bestscore) then
                bestscore, best = score, t.winid
            end
        end
    end
    if best then
        api.nvim_set_current_win(best)
    end
end

---@private
---Replace a buffer's content (toggling modifiable around the write).
local function set_buf(bufnr, content)
    if not (bufnr and api.nvim_buf_is_valid(bufnr)) then
        return
    end
    vim.bo[bufnr].modifiable = true
    api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(content or "", "\n", { plain = true }))
    vim.bo[bufnr].modifiable = false
end

---Re-render the UI from the runner's `tcdata`. Honours the `update_windows` /
---`update_details` one-shot flags set by `TCRunner:update_ui`.
function RunnerUI:update_ui()
    vim.schedule(function()
        if not self.ui_visible then
            return
        end
        -- Always refresh the status line (stress progress updates even before any
        -- testcase/counterexample exists).
        self:update_status_line()
        if next(self.runner.tcdata) == nil then
            return
        end

        if self.update_windows then
            self.update_windows = false
            self.update_details = true

            local lines, regions = {}, {}
            for i, tc in ipairs(self.runner.tcdata) do
                -- The left column: a mode may relabel rows (run-all groups solution
                -- header rows above indented per-testcase rows).
                local header
                if self.runner.row_label then
                    header = self.runner:row_label(tc)
                else
                    header = tc.tcnum == "Compile" and "Compile" or ("TC " .. tc.tcnum)
                end
                -- No runtime for a just-saved counterexample: show its label
                -- (e.g. "saved") in the time column instead.
                local timestr = (tc.time and tc.time >= 0) and string.format("%.3f s", tc.time / 1000)
                    or (tc.time_label or "")
                table.insert(lines, fit(10, header) .. fit(10, tc.status) .. timestr)
                table.insert(regions, { line = i - 1, hlgroup = tc.hlgroup, len = #tc.status })

                -- Auto-pop the viewer onto a fresh compilation failure's stderr.
                if
                    tc.tcnum == "Compile"
                    and self.config.runner_ui.viewer.open_when_compilation_fails
                    and not tc.killed
                    and tc.exit_code
                    and tc.exit_code ~= 0
                    and tc.start_time ~= self.latest_compile_token
                then
                    self.latest_compile_token = tc.start_time
                    self.update_testcase = i
                    self.viewer_content = "se"
                    self.make_viewer_visible = true
                end
            end

            local buf = self.windows.tc.bufnr
            vim.bo[buf].modifiable = true
            api.nvim_buf_set_lines(buf, 0, -1, false, lines)
            vim.bo[buf].modifiable = false
            api.nvim_buf_clear_namespace(buf, ns, 0, -1)
            for _, r in ipairs(regions) do
                if r.len > 0 then
                    api.nvim_buf_set_extmark(buf, ns, r.line, 10, {
                        end_col = 10 + r.len,
                        hl_group = r.hlgroup,
                    })
                end
            end
        end

        if self.update_details then
            self.update_details = false
            local tc = self.runner.tcdata[self.update_testcase or 1]
            if tc then
                -- Ask the runner what each detail pane should show. A mode can own a
                -- pane (return SKIP) so we don't clobber it — e.g. interactive's
                -- editable Input pane while you're typing into it.
                for _, name in ipairs(detail_windows) do
                    local content = self.runner:pane_content(tc, name)
                    if content ~= SKIP then
                        set_buf(self.windows[name].bufnr, content)
                    end
                end
                -- The panes were just rewritten, so the marks on them are stale:
                -- re-diff whatever they now hold.
                if self.diff_view then
                    self:render_diff()
                end
            end
        end

        if self.make_viewer_visible then
            self.make_viewer_visible = false
            self:show_viewer()
        end
    end)
end

return M
