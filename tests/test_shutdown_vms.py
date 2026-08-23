#!/usr/bin/env python3
"""Unit tests for shutdown_vms.py"""

import importlib.util
import re
import subprocess
import sys
import unittest
from contextlib import contextmanager
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

# The script normally lives in ../python/ relative to this test file, but
# also support a copy/symlink placed alongside the tests.
_HERE = Path(__file__).resolve().parent
_SCRIPT_CANDIDATES = [
    _HERE / "shutdown_vms.py",
    _HERE.parent / "python" / "shutdown_vms.py",
]
SCRIPT_PATH = next((p for p in _SCRIPT_CANDIDATES if p.exists()), _SCRIPT_CANDIDATES[0])
spec = importlib.util.spec_from_file_location("shutdown_vms", SCRIPT_PATH)
shutdown_vms = importlib.util.module_from_spec(spec)
sys.modules["shutdown_vms"] = shutdown_vms  # required for dataclasses to resolve cls.__module__
spec.loader.exec_module(shutdown_vms)


class TestGetRunningVMs(unittest.TestCase):
    """Tests for get_running_vms()."""

    @patch.object(shutdown_vms.subprocess, "run")
    def test_parses_multiple_names(self, mock_run):
        mock_run.return_value.stdout = "web01\ndb01\nbuild-runner\n"
        result = shutdown_vms.get_running_vms()
        self.assertEqual(result, ["web01", "db01", "build-runner"])

    @patch.object(shutdown_vms.subprocess, "run")
    def test_empty_output_returns_empty_list(self, mock_run):
        mock_run.return_value.stdout = ""
        result = shutdown_vms.get_running_vms()
        self.assertEqual(result, [])

    @patch.object(shutdown_vms.subprocess, "run")
    def test_skips_blank_lines(self, mock_run):
        # virsh occasionally pads output with blank lines; don't treat
        # those as VM names.
        mock_run.return_value.stdout = "web01\n\ndb01\n"
        result = shutdown_vms.get_running_vms()
        self.assertEqual(result, ["web01", "db01"])

    @patch.object(shutdown_vms.subprocess, "run")
    def test_propagates_called_process_error(self, mock_run):
        mock_run.side_effect = subprocess.CalledProcessError(1, ["virsh"])
        with self.assertRaises(subprocess.CalledProcessError):
            shutdown_vms.get_running_vms()


class TestVM(unittest.TestCase):
    """Tests for the VM dataclass."""

    def test_elapsed_before_shutdown_sent_is_zero(self):
        vm = shutdown_vms.VM(name="web01")
        self.assertEqual(vm.elapsed(now=100.0), 0.0)

    def test_elapsed_while_still_running(self):
        vm = shutdown_vms.VM(name="web01", shutdown_sent_at=10.0)
        self.assertEqual(vm.elapsed(now=15.5), 5.5)

    def test_elapsed_freezes_once_stopped(self):
        # Elapsed time should stop advancing once the VM is confirmed off,
        # even if `now` keeps moving forward in later poll ticks.
        vm = shutdown_vms.VM(name="web01", shutdown_sent_at=10.0, stopped_at=13.0)
        self.assertEqual(vm.elapsed(now=50.0), 3.0)

    def test_status_line_contains_name_and_state(self):
        # Relies on status_line()'s default name width; callers that know
        # the terminal geometry pass name_width explicitly.
        vm = shutdown_vms.VM(name="web01", state=shutdown_vms.VMState.SHUTDOWN_SENT, shutdown_sent_at=0.0)
        line = vm.status_line(now=2.0)
        self.assertIn("web01", line)
        self.assertIn("shutdown signal sent", line)
        self.assertIn("2.0s elapsed", line)

    @patch.object(shutdown_vms, "tty_enabled", lambda: True)
    def test_status_line_is_colorized(self):
        # Colorization is suppressed on non-TTY stdout, so force TTY mode;
        # otherwise this test would depend on how/where the suite runs.
        vm = shutdown_vms.VM(name="web01", state=shutdown_vms.VMState.OFF, shutdown_sent_at=0.0, stopped_at=1.0)
        line = vm.status_line(now=5.0)
        self.assertIn(shutdown_vms.COLOR_GREEN, line)
        self.assertIn(shutdown_vms.COLOR_RESET, line)

    def test_state_color_distinct_per_state(self):
        colors = {
            state: shutdown_vms.VM(name="x", state=state).state_color()
            for state in shutdown_vms.VMState
        }
        # Every state should map to a distinct color so they're visually
        # distinguishable in the live display. This matters semantically:
        # paused/suspended wants `virsh resume`, timed-out wants
        # `virsh destroy` -- they must not look identical.
        self.assertEqual(len(set(colors.values())), len(colors))


class TestAnsiAwarePadding(unittest.TestCase):
    """Tests for visible_length() and pad_visible(), which must ignore ANSI
    escape codes when measuring/padding so colored lines still align."""

    def test_visible_length_ignores_color_codes(self):
        with patch.object(shutdown_vms, "tty_enabled", lambda: True):
            colored = shutdown_vms.colorize("off", shutdown_vms.COLOR_GREEN)
        self.assertEqual(shutdown_vms.visible_length(colored), 3)

    def test_visible_length_plain_text_unaffected(self):
        self.assertEqual(shutdown_vms.visible_length("hello"), 5)

    @patch.object(shutdown_vms, "tty_enabled", lambda: True)
    def test_pad_visible_pads_colored_text_to_full_width(self):
        colored = shutdown_vms.colorize("off", shutdown_vms.COLOR_GREEN)
        padded = shutdown_vms.pad_visible(colored, 10)
        self.assertEqual(shutdown_vms.visible_length(padded), 10)
        # The color codes themselves must be preserved, not stripped.
        self.assertIn(shutdown_vms.COLOR_GREEN, padded)

    def test_pad_visible_does_not_truncate_when_already_long_enough(self):
        text = "this is already long enough"
        padded = shutdown_vms.pad_visible(text, 5)
        self.assertEqual(padded, text)


class TestRenderLines(unittest.TestCase):
    """Tests for render_lines(), which builds the status block as a list of
    logical lines (formerly render_status(), which returned one string)."""

    def test_includes_all_vms(self):
        vms = [
            shutdown_vms.VM(name="web01"),
            shutdown_vms.VM(name="db01"),
        ]
        lines = shutdown_vms.render_lines(
            vms, now=0.0, elapsed_total=0.0,
            name_width=shutdown_vms.NAME_WIDTH_MAX, notice=None,
        )
        block = "\n".join(lines)
        self.assertIn("web01", block)
        self.assertIn("db01", block)

    def test_includes_timeout_limit(self):
        lines = shutdown_vms.render_lines(
            [], now=0.0, elapsed_total=0.0,
            name_width=shutdown_vms.NAME_WIDTH_MAX, notice=None,
        )
        block = "\n".join(lines)
        # Displayed without a trailing .0 for whole-number timeouts.
        self.assertIn(f"{shutdown_vms.TIMEOUT_SECONDS:g}", block)
        self.assertNotIn("300.0", block)

    def test_notice_is_included(self):
        lines = shutdown_vms.render_lines(
            [], now=0.0, elapsed_total=0.0,
            name_width=shutdown_vms.NAME_WIDTH_MAX, notice="WARNING: libvirt blip",
        )
        self.assertTrue(any("libvirt blip" in line for line in lines))


class TestUpdateStates(unittest.TestCase):
    """Tests for the state machine that interprets each domain inventory.

    OFF requires confirmation in the shutoff set; a tracked guest that is
    neither running nor shut off (paused, pmsuspended, crashed) surfaces as
    SUSPENDED instead of being treated as safely down."""

    def _updated(self, state, running, shutoff):
        vm = shutdown_vms.VM(name="web01", state=state, shutdown_sent_at=0.0)
        shutdown_vms.update_states([vm], set(running), set(shutoff), now=5.0)
        return vm

    def test_shutoff_confirms_off(self):
        vm = self._updated(shutdown_vms.VMState.SHUTDOWN_SENT, [], ["web01"])
        self.assertIs(vm.state, shutdown_vms.VMState.OFF)
        self.assertEqual(vm.stopped_at, 5.0)

    def test_absence_without_shutoff_surfaces_suspended(self):
        vm = self._updated(shutdown_vms.VMState.SHUTDOWN_SENT, [], [])
        self.assertIs(vm.state, shutdown_vms.VMState.SUSPENDED)

    def test_resume_returns_to_shutdown_sent(self):
        vm = self._updated(shutdown_vms.VMState.SUSPENDED, ["web01"], [])
        self.assertIs(vm.state, shutdown_vms.VMState.SHUTDOWN_SENT)

    def test_off_is_never_revisited(self):
        # Once confirmed off, later inventories (including a restart seen
        # mid-wait) must not flip the state back; the final verification
        # is what catches restarts.
        vm = self._updated(shutdown_vms.VMState.OFF, ["web01"], [])
        self.assertIs(vm.state, shutdown_vms.VMState.OFF)


class TestDisplayGeometry(unittest.TestCase):
    """Tests for fitting_name_width(), the narrow-terminal shrink logic."""

    def test_clamps_to_maximum(self):
        self.assertEqual(
            shutdown_vms.fitting_name_width(200), shutdown_vms.NAME_WIDTH_MAX
        )

    def test_exact_fit_at_floor(self):
        cols = shutdown_vms.FIXED_LINE_OVERHEAD + shutdown_vms.MIN_NAME_WIDTH
        self.assertEqual(shutdown_vms.fitting_name_width(cols), shutdown_vms.MIN_NAME_WIDTH)

    def test_none_below_floor(self):
        cols = shutdown_vms.FIXED_LINE_OVERHEAD + shutdown_vms.MIN_NAME_WIDTH - 1
        self.assertIsNone(shutdown_vms.fitting_name_width(cols))


class FakeClock:
    """Deterministic stand-in for time.monotonic()/time.sleep(): virtual
    time advances only when the script sleeps, so poll/repaint/timeout
    counts are exact and machine-independent."""

    def __init__(self):
        self.now = 0.0

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


class TestMain(unittest.TestCase):
    """Integration-style tests for main(), mocking subprocess and time."""

    def _make_fake_run(self, states_by_poll):
        """Fake subprocess.run driven by per-poll domain inventories.

        states_by_poll is a list of (running, shutoff) name pairs, one per
        inventory poll; the last pair repeats once exhausted (trailing
        steady-state entries are therefore optional). A `--state-running`
        query STARTS a poll: it selects the entry and advances the counter,
        and the `--state-shutoff` query issued right after it serves the
        SAME entry -- matching poll_domain_states(), which expects both
        listings to reflect one host snapshot. Other argv shapes (e.g.
        `virsh shutdown NAME`) succeed silently. Accepts **kwargs so the
        timeout/check/capture options the script passes don't break the
        stub."""

        def fake_run(cmd, **kwargs):
            result = MagicMock()
            result.returncode = 0
            if cmd[:2] == ["virsh", "list"]:
                if cmd[2] == "--state-running":
                    self._current_entry = states_by_poll[
                        min(self._poll_count, len(states_by_poll) - 1)
                    ]
                    self._poll_count += 1
                running, shutoff = getattr(
                    self, "_current_entry", states_by_poll[0]
                )
                names = {"--state-running": running, "--state-shutoff": shutoff}.get(
                    cmd[2], []
                )
                result.stdout = "\n".join(names) + "\n" if names else ""
            return result

        return fake_run

    def _make_flaky_run(self, responses):
        """Like _make_fake_run, but entries may be Exception instances,
        raised once on the next `--state-running` query to simulate
        transient libvirt blips between healthy polls."""
        state = {"index": 0}

        def flaky_run(cmd, **kwargs):
            result = MagicMock()
            result.returncode = 0
            if cmd[:2] == ["virsh", "list"]:
                i = min(state["index"], len(responses) - 1)
                entry = responses[i]
                if cmd[2] == "--state-running":
                    if isinstance(entry, Exception):
                        state["index"] = i + 1
                        raise entry
                    running, _ = entry
                    result.stdout = "\n".join(running) + "\n" if running else ""
                    state["index"] = min(i + 1, len(responses) - 1)
                else:
                    if not isinstance(entry, Exception):
                        _, shutoff = entry
                        result.stdout = "\n".join(shutoff) + "\n" if shutoff else ""
            return result

        return flaky_run

    @contextmanager
    def _runtime(self, tty=True, columns=200, lines=100):
        """Pin the script's clock, TTY detection, and terminal size so the
        display mode and loop timing are chosen by the test, not by the
        environment it happens to run in."""
        clock = FakeClock()
        term = SimpleNamespace(columns=columns, lines=lines)
        with patch.object(shutdown_vms.time, "monotonic", clock.monotonic), \
             patch.object(shutdown_vms.time, "sleep", clock.sleep), \
             patch.object(shutdown_vms, "tty_enabled", lambda: tty), \
             patch.object(shutdown_vms.shutil, "get_terminal_size", lambda: term):
            yield clock

    def setUp(self):
        self._poll_count = 0
        self._orig_timeout = shutdown_vms.TIMEOUT_SECONDS
        self._orig_interval = shutdown_vms.CHECK_INTERVAL_SECONDS
        self._orig_refresh = shutdown_vms.DISPLAY_REFRESH_SECONDS
        shutdown_vms.TIMEOUT_SECONDS = 1.0
        shutdown_vms.CHECK_INTERVAL_SECONDS = 0.2
        shutdown_vms.DISPLAY_REFRESH_SECONDS = 0.2

    def tearDown(self):
        shutdown_vms.TIMEOUT_SECONDS = self._orig_timeout
        shutdown_vms.CHECK_INTERVAL_SECONDS = self._orig_interval
        shutdown_vms.DISPLAY_REFRESH_SECONDS = self._orig_refresh

    @patch.object(shutdown_vms.subprocess, "run")
    def test_display_refreshes_more_often_than_polling(self, mock_run):
        # CHECK_INTERVAL bumped to 1.0 (== TIMEOUT) so the decoupling is
        # provable: with a virtual clock, TIMEOUT=1.0 and REFRESH=0.2 give
        # exactly six refresh ticks plus the final "timed out" repaint,
        # while virsh is queried only for discovery, the one scheduled
        # poll at t=1.0, and the mandatory final confirmation.
        shutdown_vms.CHECK_INTERVAL_SECONDS = 1.0
        mock_run.side_effect = self._make_fake_run([(["build-runner"], [])])
        writes = []
        with self._runtime(), patch.object(
            shutdown_vms.sys.stdout, "write", side_effect=lambda s: writes.append(s)
        ):
            shutdown_vms.main()
        repaints = sum(1 for w in writes if "elapsed" in w)
        self.assertEqual(repaints, 7)
        self.assertEqual(self._poll_count, 3)
        self.assertGreater(repaints, self._poll_count)

    @patch.object(shutdown_vms.subprocess, "run")
    def test_no_vms_running_exits_zero(self, mock_run):
        mock_run.return_value.stdout = ""
        mock_run.return_value.returncode = 0
        result = shutdown_vms.main()
        self.assertEqual(result, 0)

    @patch.object(shutdown_vms.subprocess, "run")
    def test_all_vms_shut_down_exits_zero(self, mock_run):
        mock_run.side_effect = self._make_fake_run(
            [(["web01", "db01"], []), ([], ["web01", "db01"])]
        )
        with self._runtime():
            result = shutdown_vms.main()
        self.assertEqual(result, 0)
        # discovery + one confirming poll + final verification
        self.assertEqual(self._poll_count, 3)

    @patch.object(shutdown_vms.subprocess, "run")
    def test_timeout_leaves_vm_running_exits_one(self, mock_run):
        # build-runner never disappears from `virsh list`, forcing a timeout.
        mock_run.side_effect = self._make_fake_run([(["build-runner"], [])])
        with self._runtime():
            result = shutdown_vms.main()
        self.assertEqual(result, 1)

    @patch.object(shutdown_vms.subprocess, "run")
    def test_partial_shutdown_only_stragglers_reported(self, mock_run):
        # web01 shuts down after tick 1; build-runner never does.
        mock_run.side_effect = self._make_fake_run(
            [(["web01", "build-runner"], []),
             (["build-runner"], ["web01"]),
             (["build-runner"], [])]
        )
        captured = []
        with self._runtime(), patch(
            "builtins.print",
            side_effect=lambda *a, **k: captured.append(" ".join(str(x) for x in a)),
        ):
            result = shutdown_vms.main()
        self.assertEqual(result, 1)
        warning_section = "\n".join(captured)
        self.assertIn("build-runner", warning_section)

    @patch.object(shutdown_vms.subprocess, "run")
    def test_transient_poll_failures_are_tolerated(self, mock_run):
        # Two consecutive `virsh list` blips warn but do not abort; the
        # third poll recovers, web01 is confirmed off, and the run succeeds.
        mock_run.side_effect = self._make_flaky_run([
            (["web01"], []),
            subprocess.CalledProcessError(1, ["virsh"]),
            subprocess.CalledProcessError(1, ["virsh"]),
            ([], ["web01"]),
        ])
        writes = []
        with self._runtime(), patch.object(
            shutdown_vms.sys.stdout, "write", side_effect=lambda s: writes.append(s)
        ):
            result = shutdown_vms.main()
        self.assertEqual(result, 0)
        output = "".join(writes)
        self.assertIn("1/3", output)
        self.assertIn("2/3", output)
        self.assertNotIn("giving up", output)

    @patch.object(shutdown_vms.subprocess, "run")
    def test_persistent_poll_failures_give_up(self, mock_run):
        # Three consecutive failures after a healthy start abort the run.
        mock_run.side_effect = self._make_flaky_run([
            (["web01"], []),
            subprocess.CalledProcessError(1, ["virsh"]),
            subprocess.CalledProcessError(1, ["virsh"]),
            subprocess.CalledProcessError(1, ["virsh"]),
        ])
        captured = []
        with self._runtime(), patch(
            "builtins.print",
            side_effect=lambda *a, **k: captured.append(" ".join(str(x) for x in a)),
        ):
            result = shutdown_vms.main()
        self.assertEqual(result, 1)
        self.assertIn("giving up", "\n".join(captured))

    @patch.object(shutdown_vms.subprocess, "run")
    def test_restarted_vm_fails_final_verification(self, mock_run):
        # web01 powers off, then comes back before the final verification:
        # success must not be declared for a pre-patch gate.
        mock_run.side_effect = self._make_fake_run(
            [(["web01"], []), ([], ["web01"]), (["web01"], [])]
        )
        captured = []
        with self._runtime(), patch(
            "builtins.print",
            side_effect=lambda *a, **k: captured.append(" ".join(str(x) for x in a)),
        ):
            result = shutdown_vms.main()
        self.assertEqual(result, 1)
        output = "\n".join(captured)
        # Must be the restart gate, not the timeout branch, that produced
        # the exit code -- both return 1.
        self.assertNotIn("Time-out reached", output)
        self.assertIn("started again", output)
        self.assertIn("web01", output)

    @patch.object(shutdown_vms.subprocess, "run")
    def test_narrow_terminal_degrades_to_append_output(self, mock_run):
        # At 40 columns the status table cannot fit; the script must fall
        # back to append-style output (printed only on state change, never
        # cursor-addressed) instead of corrupting the screen.
        mock_run.side_effect = self._make_fake_run(
            [(["web01"], []), ([], ["web01"])]
        )
        writes = []
        with self._runtime(columns=40), patch.object(
            shutdown_vms.sys.stdout, "write", side_effect=lambda s: writes.append(s)
        ):
            result = shutdown_vms.main()
        self.assertEqual(result, 0)
        output = "".join(writes)
        # Two append blocks (initial + one state change), two "elapsed"
        # lines per block (header + VM row). No per-tick spam.
        self.assertEqual(sum(1 for w in writes if "elapsed" in w), 4)
        # No cursor addressing ever reaches a narrow terminal.
        self.assertNotRegex(output, r"\x1b\[\d+A")


if __name__ == "__main__":
    unittest.main()
