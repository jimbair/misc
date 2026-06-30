#!/usr/bin/env python3
"""Unit tests for shutdown_vms.py"""

import importlib.util
import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT_PATH = Path(__file__).parent / "shutdown_vms.py"
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
        vm = shutdown_vms.VM(name="web01", state=shutdown_vms.VMState.SHUTDOWN_SENT, shutdown_sent_at=0.0)
        line = vm.status_line(now=2.0)
        self.assertIn("web01", line)
        self.assertIn("shutdown signal sent", line)
        self.assertIn("2.0s elapsed", line)

    def test_status_line_is_colorized(self):
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
        # distinguishable in the live display.
        self.assertEqual(len(set(colors.values())), len(colors))


class TestAnsiAwarePadding(unittest.TestCase):
    """Tests for visible_length() and pad_visible(), which must ignore ANSI
    escape codes when measuring/padding so colored lines still align."""

    def test_visible_length_ignores_color_codes(self):
        colored = shutdown_vms.colorize("off", shutdown_vms.COLOR_GREEN)
        self.assertEqual(shutdown_vms.visible_length(colored), 3)

    def test_visible_length_plain_text_unaffected(self):
        self.assertEqual(shutdown_vms.visible_length("hello"), 5)

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


class TestRenderStatus(unittest.TestCase):
    """Tests for render_status()."""

    def test_includes_all_vms(self):
        vms = [
            shutdown_vms.VM(name="web01"),
            shutdown_vms.VM(name="db01"),
        ]
        block = shutdown_vms.render_status(vms, now=0.0, elapsed_total=0.0)
        self.assertIn("web01", block)
        self.assertIn("db01", block)

    def test_includes_timeout_limit(self):
        block = shutdown_vms.render_status([], now=0.0, elapsed_total=0.0)
        # Displayed without a trailing .0 for whole-number timeouts.
        self.assertIn(f"{shutdown_vms.TIMEOUT_SECONDS:g}", block)
        self.assertNotIn("300.0", block)


class TestMain(unittest.TestCase):
    """Integration-style tests for main(), mocking subprocess and time.sleep."""

    def _make_fake_run(self, running_by_poll):
        """Build a fake subprocess.run that returns `virsh list` output based
        on the current *poll* count (not display-loop iteration), since
        virsh is now polled less often than the display refreshes."""

        def fake_run(cmd, capture_output=False, text=False, check=False):
            result = unittest.mock.MagicMock()
            result.returncode = 0
            if cmd[:3] == ["virsh", "list", "--state-running"]:
                poll = self._poll_count
                names = running_by_poll[min(poll, len(running_by_poll) - 1)]
                result.stdout = "\n".join(names) + "\n" if names else ""
                self._poll_count += 1
            else:
                result.stdout = ""
            return result

        return fake_run

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

    def _advance_tick(self, _seconds):
        pass

    @patch.object(shutdown_vms.time, "sleep")
    @patch.object(shutdown_vms.subprocess, "run")
    def test_virsh_polled_less_often_than_display_refreshes(self, mock_run, mock_sleep):
        # CHECK_INTERVAL_SECONDS=0.2 (poll) vs DISPLAY_REFRESH_SECONDS=0.2 (refresh)
        # are equal in setUp, so bump the poll interval to be slower here to
        # actually exercise the decoupling.
        shutdown_vms.CHECK_INTERVAL_SECONDS = 1.0
        mock_run.side_effect = self._make_fake_run([["build-runner"]] * 3)
        mock_sleep.side_effect = self._advance_tick

        write_calls = []
        with patch.object(shutdown_vms.sys.stdout, "write", side_effect=lambda s: write_calls.append(s)):
            shutdown_vms.main()

        redraws = sum(1 for call in write_calls if "elapsed" in call)
        # TIMEOUT_SECONDS=1.0, DISPLAY_REFRESH_SECONDS=0.2 -> ~5-6 redraws,
        # but CHECK_INTERVAL_SECONDS=1.0 means virsh should only be polled
        # once (the initial poll) within that same window.
        self.assertGreater(redraws, self._poll_count)

    @patch.object(shutdown_vms.subprocess, "run")
    def test_no_vms_running_exits_zero(self, mock_run):
        mock_run.return_value.stdout = ""
        mock_run.return_value.returncode = 0
        result = shutdown_vms.main()
        self.assertEqual(result, 0)

    @patch.object(shutdown_vms.time, "sleep")
    @patch.object(shutdown_vms.subprocess, "run")
    def test_all_vms_shut_down_exits_zero(self, mock_run, mock_sleep):
        mock_run.side_effect = self._make_fake_run([["web01", "db01"], []])
        mock_sleep.side_effect = self._advance_tick
        result = shutdown_vms.main()
        self.assertEqual(result, 0)

    @patch.object(shutdown_vms.time, "sleep")
    @patch.object(shutdown_vms.subprocess, "run")
    def test_timeout_leaves_vm_running_exits_one(self, mock_run, mock_sleep):
        # build-runner never disappears from `virsh list`, forcing a timeout.
        mock_run.side_effect = self._make_fake_run([["build-runner"]] * 10)
        mock_sleep.side_effect = self._advance_tick
        result = shutdown_vms.main()
        self.assertEqual(result, 1)

    @patch.object(shutdown_vms.time, "sleep")
    @patch.object(shutdown_vms.subprocess, "run")
    def test_partial_shutdown_only_stragglers_reported(self, mock_run, mock_sleep):
        # web01 shuts down after tick 1; build-runner never does.
        mock_run.side_effect = self._make_fake_run(
            [["web01", "build-runner"], ["build-runner"]] + [["build-runner"]] * 10
        )
        mock_sleep.side_effect = self._advance_tick

        captured = []
        with patch("builtins.print", side_effect=lambda *a, **k: captured.append(" ".join(str(x) for x in a))):
            result = shutdown_vms.main()

        self.assertEqual(result, 1)
        warning_section = "\n".join(captured)
        self.assertIn("build-runner", warning_section)


if __name__ == "__main__":
    unittest.main()
