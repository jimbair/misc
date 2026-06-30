#!/usr/bin/env python3
"""Graceful KVM Virtual Machine Shutdown Script

Helps with patching the hypervisor when the automatic reboot handling acts
a bit funny. Sends ACPI shutdown to all running VMs, then displays a live
per-VM status table (state + elapsed time) until everything is off or the
timeout is reached.
"""

from __future__ import annotations

import subprocess
import sys
import time
from dataclasses import dataclass
from enum import Enum

# Maximum time (in seconds) to wait for all VMs to power off
TIMEOUT_SECONDS = 300.0
CHECK_INTERVAL_SECONDS = 1.0

# How often the on-screen display refreshes, independent of how often we
# actually poll `virsh` for state. This is what makes elapsed-time counters
# feel real-time instead of jumping only when a VM's state changes.
DISPLAY_REFRESH_SECONDS = 1.0

# ANSI color codes for the live status display
COLOR_RESET = "\033[0m"
COLOR_YELLOW = "\033[33m"  # in progress / waiting
COLOR_GREEN = "\033[32m"  # success / off
COLOR_RED = "\033[31m"  # timed out / failure
COLOR_GRAY = "\033[90m"  # idle / not yet started


def colorize(text: str, color: str) -> str:
    """Wrap text in an ANSI color code, resetting after."""
    return f"{color}{text}{COLOR_RESET}"


class VMState(Enum):
    """Tracked lifecycle states for a VM during shutdown."""

    RUNNING = "running"
    SHUTDOWN_SENT = "shutdown signal sent"
    OFF = "off"
    TIMED_OUT = "timed out"


@dataclass
class VM:
    """Tracks shutdown progress for a single virtual machine."""

    name: str
    state: VMState = VMState.RUNNING
    shutdown_sent_at: float | None = None
    stopped_at: float | None = None

    def elapsed(self, now: float) -> float:
        """Seconds since the shutdown signal was sent, or 0 if not yet sent."""
        if self.shutdown_sent_at is None:
            return 0.0
        end = self.stopped_at if self.stopped_at is not None else now
        return end - self.shutdown_sent_at

    def state_color(self) -> str:
        """ANSI color appropriate for this VM's current state."""
        return {
            VMState.RUNNING: COLOR_GRAY,
            VMState.SHUTDOWN_SENT: COLOR_YELLOW,
            VMState.OFF: COLOR_GREEN,
            VMState.TIMED_OUT: COLOR_RED,
        }[self.state]

    def status_line(self, now: float) -> str:
        """Single-line status for the live display."""
        elapsed = self.elapsed(now)
        state_text = colorize(f"{self.state.value:<20}", self.state_color())
        return f"  {self.name:<30} {state_text} {elapsed:6.1f}s elapsed"


def get_running_vms() -> list[str]:
    """Return the names of all currently running VMs."""
    result = subprocess.run(
        ["virsh", "list", "--state-running", "--name"],
        capture_output=True,
        text=True,
        check=True,
    )
    return [line for line in result.stdout.splitlines() if line.strip()]


def send_shutdown(vm_name: str) -> None:
    """Send the ACPI shutdown signal to a single VM."""
    subprocess.run(["virsh", "shutdown", vm_name], check=False)


def force_destroy(vm_name: str) -> None:
    """Force a hard power-off for a VM that failed to shut down gracefully."""
    subprocess.run(["virsh", "destroy", vm_name], check=False)


def render_status(vms: list[VM], now: float, elapsed_total: float) -> str:
    """Build the full multi-line status block for the live display."""
    lines = [f"Waiting for VMs to power off (Timeout limit: {TIMEOUT_SECONDS:g}s)..."]
    lines.append(f"Total elapsed: {elapsed_total:6.1f}s")
    lines.append("")
    for vm in vms:
        lines.append(vm.status_line(now))
    return "\n".join(lines)


def visible_length(text: str) -> int:
    """Length of `text` excluding ANSI escape sequences."""
    result = 0
    in_escape = False
    for char in text:
        if char == "\033":
            in_escape = True
            continue
        if in_escape:
            if char == "m":
                in_escape = False
            continue
        result += 1
    return result


def pad_visible(text: str, width: int) -> str:
    """Right-pad `text` to `width` visible characters, ignoring ANSI codes
    when measuring length so colored text aligns the same as plain text."""
    padding = max(0, width - visible_length(text))
    return text + (" " * padding)


def move_cursor_up(num_lines: int) -> None:
    """Move the terminal cursor up to redraw the status block in place."""
    if num_lines > 0:
        sys.stdout.write(f"\033[{num_lines}A")


def main() -> int:
    print("Checking for running Virtual Machines...")

    try:
        running_names = get_running_vms()
    except subprocess.CalledProcessError as exc:
        print(f"ERROR: Failed to query running VMs: {exc}", file=sys.stderr)
        return 1

    if not running_names:
        print("No running VMs found.")
        return 0

    vms = [VM(name=name) for name in running_names]

    print("Initiating graceful shutdown for the following VMs:")
    for vm in vms:
        print(f"  {vm.name}")
    print("----------------------------------------------------")

    shutdown_time = time.monotonic()
    for vm in vms:
        print(f"Sending shutdown signal to: {vm.name}")
        send_shutdown(vm.name)
        vm.state = VMState.SHUTDOWN_SENT
        vm.shutdown_sent_at = shutdown_time
    print("----------------------------------------------------")

    # Render the initial status block, then redraw it in place on every
    # display tick. `virsh` is only re-polled every CHECK_INTERVAL_SECONDS;
    # the display itself refreshes faster (DISPLAY_REFRESH_SECONDS) so the
    # elapsed-time counters visibly tick up in real time between polls.
    rendered_lines = 0
    elapsed = 0.0
    elapsed_since_poll = 0.0
    still_running: set[str] = {vm.name for vm in vms}

    while True:
        now = time.monotonic()

        if elapsed_since_poll >= CHECK_INTERVAL_SECONDS:
            try:
                still_running = set(get_running_vms())
            except subprocess.CalledProcessError as exc:
                print(f"\nERROR: Failed to query running VMs: {exc}", file=sys.stderr)
                return 1
            elapsed_since_poll = 0.0

            for vm in vms:
                if vm.name not in still_running and vm.state == VMState.SHUTDOWN_SENT:
                    vm.state = VMState.OFF
                    vm.stopped_at = now

        if rendered_lines:
            move_cursor_up(rendered_lines)

        block = render_status(vms, now, elapsed)
        # Pad each line (by visible width, ignoring ANSI codes) so leftover
        # characters from a previous, longer render don't linger on screen.
        sys.stdout.write("\n".join(pad_visible(line, 70) for line in block.split("\n")) + "\n")
        sys.stdout.flush()
        rendered_lines = block.count("\n") + 1

        if not still_running:
            break
        if elapsed >= TIMEOUT_SECONDS:
            for vm in vms:
                if vm.state == VMState.SHUTDOWN_SENT:
                    vm.state = VMState.TIMED_OUT
            break

        time.sleep(DISPLAY_REFRESH_SECONDS)
        elapsed += DISPLAY_REFRESH_SECONDS
        elapsed_since_poll += DISPLAY_REFRESH_SECONDS

    print()

    remaining = [vm for vm in vms if vm.state == VMState.TIMED_OUT]
    if remaining:
        print("WARNING: Time-out reached. The following VMs failed to shut down gracefully:")
        for vm in remaining:
            print(f"  {vm.name}")
        print()
        print(
            "Action required: Log into the guests to check for hung processes, "
            "or use 'virsh destroy <vm_name>' to force a hard power-off."
        )
        return 1

    print("SUCCESS: All Virtual Machines have safely shut down.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
