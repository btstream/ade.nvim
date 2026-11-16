"""Attached-UI regression, including the non-current composer winbar.

Run: python3 tests/integration_spinner.py
Requires the optional Python test dependency pynvim and nvim on PATH.
"""

import logging
from pathlib import Path
import threading

import pynvim


logging.disable(logging.CRITICAL)
ROOT = str(Path(__file__).resolve().parent.parent)
FRAMES = set("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")
nvim = pynvim.attach(
    "child", argv=["nvim", "--embed", "-u", "NONE", "-i", "NONE", "--noplugin"]
)


def phase(label, setup, ready=None, timeout_ms=5000):
    seen = set()
    result = []
    expired = threading.Event()

    def notification(method, args):
        if method == "redraw":
            for event in args:
                if event[0] == "grid_line":
                    for line in event[1:]:
                        for cell in line[3]:
                            seen.update(FRAMES.intersection(cell[0]))
        elif method == "ade_spinner_done":
            result.append(args[0])
            nvim.stop_loop()

    def timeout():
        expired.set()
        nvim.async_call(nvim.stop_loop)

    # Poll for the phase's own success condition instead of sleeping a fixed
    # 500 ms: a loaded machine may need longer for the frames to reach the UI,
    # while an idle one should not pay the full delay. The condition is
    # evaluated in the editor, and the existing assertions still run on the
    # collected diagnostics, so a genuine failure names what is missing.
    baseline = nvim.exec_lua("return _G.spinner_test:diagnostics().frame_changes")
    # A frame change does not guarantee the UI redraw carried a *distinct*
    # spinner glyph (redraws can coalesce frames), so wait for enough animation
    # to make the three-distinct-frames assertion reliable. This is still a
    # condition, not a delay: it passes as soon as the spinner has advanced.
    condition = ready or f"_G.spinner_test:diagnostics().frame_changes >= {baseline + 8}"
    nvim.exec_lua(
        setup
        + f"""
        local deadline = vim.uv.hrtime() + {timeout_ms} * 1e6
        local function report()
          local stats = _G.spinner_test:diagnostics()
          stats.focused_win = vim.api.nvim_get_current_win()
          stats.stress_complete = _G.stress_complete
          stats.stress_frames = _G.stress_frames and vim.tbl_count(_G.stress_frames)
          stats.stress_readonly = _G.stress_readonly
          vim.rpcnotify({nvim.channel_id}, 'ade_spinner_done', stats)
        end
        local function poll()
          local ok, ready_now = pcall(function() return {condition} end)
          if (ok and ready_now == true) or vim.uv.hrtime() >= deadline then
            report()
            return
          end
          vim.defer_fn(poll, 10)
        end
        poll()
        """,
    )
    deadline = threading.Timer((timeout_ms / 1000) + 5, timeout)
    deadline.start()
    try:
        nvim.run_loop(None, notification)
    finally:
        deadline.cancel()
    assert not expired.is_set(), f"{label}: UI did not respond"
    assert result, f"{label}: no diagnostic result"
    stats = result[0]
    assert stats["timer_active"], f"{label}: timer is not active"
    assert stats["focused_win"] != stats["input_win"], f"{label}: composer was focused"
    assert len(seen) >= 3, f"{label}: winbar pixels did not animate: {seen}"
    assert stats["redraws"] > 0 and stats["bar_evaluations"] > 0
    print(f"ok {label}: {len(seen)} distinct spinner frames in UI grid updates")
    return stats


try:
    nvim.ui_attach(100, 30, rgb=True, ext_linegrid=True)
    nvim.exec_lua(
        """
        vim.opt.runtimepath:append(...)
        local cfg = vim.deepcopy(require('ade.config').defaults)
        cfg.ui.toolbar.animation_interval = 30
        local state = require('ade.session.state').new('spinner', '/tmp')
        state.status = 'running'
        local input = require('ade.ui.input').new({ config = cfg })
        input.win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(input.win, input.buf)
        _G.spinner_test = require('ade.ui.chrome').new({
          config = function() return cfg end,
          current = function() return state end,
          waiting = function() return false end,
          session_label = function() return 'spinner' end,
          input = function() return input end,
          chat = function() return nil end,
        })
        _G.AdeComposerBar = function() return spinner_test:composer_bar() end
        vim.cmd('vsplit')
        vim.api.nvim_win_set_buf(0, vim.api.nvim_create_buf(false, true))
        spinner_test:apply()
        """,
        ROOT,
    )
    phase("targeted non-current winbar", "spinner_test:sync_animation(true)\n")
    phase(
        "stopped timer recovery",
        "spinner_test.timer:stop(); spinner_test:sync_animation(true)\n",
    )
    busy = phase(
        "busy-loop recovery",
        "local deadline = vim.uv.hrtime() + 250e6; "
        "while vim.uv.hrtime() < deadline do end\n",
    )
    assert busy["max_tick_gap_ms"] >= 200, "main-loop stall was not recorded"
    stress = phase(
        "chunked transcript commit with live spinner",
        r"""
        local cfg = vim.deepcopy(require('ade.config').defaults)
        cfg.ui.render.commit_rows = 20
        local chat = require('ade.ui.chat').new({ config = cfg })
        _G.stress_chat = chat
        chat.win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(chat.win, chat.buf)
        local renderer = require('ade.ui.buffer_renderer')
        local highlight = renderer.highlight_line
        -- Controlled expensive row highlighting ensures actual overlap rather
        -- than merely observing idle animation after a very fast commit.
        renderer.highlight_line = function(...)
          local deadline = vim.uv.hrtime() + 40000
          while vim.uv.hrtime() < deadline do end
          return highlight(...)
        end
        local bar = _G.AdeComposerBar
        _G.stress_frames, _G.stress_readonly = {}, true
        _G.AdeComposerBar = function(...)
          if chat.commit_job then
            stress_frames[spinner_test.frame or 'none'] = true
            stress_readonly = stress_readonly and not vim.bo[chat.buf].modifiable
          end
          return bar(...)
        end
        local state = require('ade.session.state').new('stress', '/tmp')
        state:track_changes()
        state:append({ id = 'large', kind = 'agent', text = string.rep('stress row\n', 6000) })
        chat:set_session(state)
        local function finish()
          if chat.commit_job then
            vim.defer_fn(finish, 5)
            return
          end
          _G.stress_complete = chat.render_version == state.version
            and vim.deep_equal(chat.lines_cache, vim.api.nvim_buf_get_lines(chat.buf, 0, -1, false))
          renderer.highlight_line = highlight
          _G.AdeComposerBar = bar
        end
        finish()
        """,
        # The phase is done only after the commit settled *and* the spinner
        # animated during it; waiting for a fixed delay could report earlier.
        ready="_G.stress_complete == true and vim.tbl_count(_G.stress_frames or {}) >= 3",
    )
    assert stress["stress_complete"], "chunked transcript did not finish correctly"
    assert stress["stress_readonly"], "yielded transcript became editable"
    assert stress["stress_frames"] >= 3, "spinner did not animate during the commit"
    phase("redrawstatus! fallback", "spinner_test.targeted_redraw = false\n")
    nvim.exec_lua("spinner_test:destroy(); stress_chat:destroy()")
    print("all attached-UI spinner checks passed")
finally:
    try:
        nvim.command("qa!")
    except (EOFError, OSError):
        pass
    nvim.close()
