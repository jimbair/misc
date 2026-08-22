#!/usr/bin/env python3
"""Graceful KVM Virtual Machine Shutdown Script

Helps with patching the hypervisor when the automatic reboot handling acts
a bit funny. Sends ACPI shutdown to all running VMs, then displays a live
per-VM status table (state + elapsed time) until everything is off or the
timeout is reached. Only VMs that were running when the script started are
tracked; unrelated VMs started on the host during the wait do not keep it
waiting.
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

# How long to wait for a single `virsh` invocation before giving up, so a
# wedged libvirt daemon cannot hang this script forever.
VIRSH_TIMEOUT_SECONDS = 10.0

# The widest status line: 2 (indent) + 30 (name) + 1 + 20 (state)
# + 1 + 6 (elapsed) + 9 ("s elapsed") = 69, rounded up to 70.
DISPLAY_WIDTH = 70

# ANSI color codes for the live status display
COLOR_RESET = "\033[0m"
COLOR_YELLOW = "\033[33m"  # in progress / waiting
COLOR_GREEN = "\033[32m"  # success / off
COLOR_RED = "\033[31m"  # timed out / failure
COLOR_GRAY = "\033[90m"  # idle / not yet started


def tty_enabled() -> bool:
    """True when stdout is an interactive terminal (colors/cursor moves OK)."""
    return sys.stdout.isatty()


def colorize(text: str, color: str) -> str:
    """Wrap text in an ANSI color code, resetting after. Returns plain text
    when stdout is not a TTY so piped/log output stays clean."""
    if not tty_enabled():
        return text
    return f"{color}{text}{COLOR_RESET}"


class VMState(Enum):
    """Tracked lifecycle states for a VM during shutdown."""

    RUNNING = "running"
    SHUTDOWN_SENT = "shutdown signal sent"
    OFF = "off"
    TIMED_OUT = "timed out"


class SignalResult(Enum):
    """Outcome of an ACPI shutdown request for a single VM."""

    SENT = "sent"
    ALREADY_OFF = "already off"
    FAILED = "failed"


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
        name = self.name
        if len(name) > 30:
            name = name[:29] + "…"  # keep the status columns aligned
        return f"  {name:<30} {state_text} {elapsed:6.1f}s elapsed"


def get_running_vms() -> list[str]:
    """Return the names of all currently running VMs."""
    result = subprocess.run(
        ["virsh", "list", "--state-running", "--name"],
        capture_output=True,
        text=True,
        check=True,
        timeout=VIRSH_TIMEOUT_SECONDS,
    )
    return [line for line in result.stdout.splitlines() if line.strip()]


def get_running_vms_or_error() -> list[str] | None:
    """Return the running VM names, or None after printing an error.

    Wraps get_running_vms() so a missing `virsh` binary, a timed-out
    libvirt daemon, or a failing query all report cleanly instead of
    raising an unhandled exception.
    """
    try:
        return get_running_vms()
    except FileNotFoundError:
        print("ERROR: 'virsh' was not found on this system.", file=sys.stderr)
    except subprocess.TimeoutExpired:
        print(
            f"ERROR: 'virsh list' timed out after {VIRSH_TIMEOUT_SECONDS:g}s "
            "(is the libvirt daemon hung?)",
            file=sys.stderr,
        )
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or "").strip() or str(exc)
        print(f"ERROR: Failed to query running VMs: {detail}", file=sys.stderr)
    return None


def send_shutdown(vm_name: str) -> SignalResult:
    """Send the ACPI shutdown signal to a single VM and report the outcome.

    Diagnostics are printed directly; the return value tells the caller how
    to track this VM.
    """
    try:
        result = subprocess.run(
            ["virsh", "shutdown", vm_name],
            capture_output=True,
            text=True,
            timeout=VIRSH_TIMEOUT_SECONDS,
        )
    except FileNotFoundError:
        print(
            f"WARNING: 'virsh' was not found; cannot shut down {vm_name}.",
            file=sys.stderr,
        )
        return SignalResult.FAILED
    except subprocess.TimeoutExpired:
        print(
            f"WARNING: 'virsh shutdown {vm_name}' timed out after "
            f"{VIRSH_TIMEOUT_SECONDS:g}s.",
            file=sys.stderr,
        )
        return SignalResult.FAILED

    if result.returncode == 0:
        return SignalResult.SENT

    stderr = (result.stderr or "").strip()
    if "not running" in stderr.lower():
        # The guest powered off between the initial list and now.
        print(f"NOTE: {vm_name} is already off; no shutdown signal needed.")
        return SignalResult.ALREADY_OFF

    print(
        f"WARNING: 'virsh shutdown {vm_name}' failed: "
        f"{stderr or f'exit status {result.returncode}'}",
        file=sys.stderr,
    )
    return SignalResult.FAILED


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
    """Move the terminal cursor up to redraw the status block in place.
    No-op when stdout is not a TTY (piped output)."""
    if num_lines > 0 and tty_enabled():
        sys.stdout.write(f"\033[{num_lines}A")


def paint_status(
    vms: list[VM], now: float, elapsed_total: float, rendered_lines: int
) -> int:
    """Draw the status block (redrawing in place when the display already
    shows one). Returns the number of lines drawn."""
    if rendered_lines:
        move_cursor_up(rendered_lines)
    block = render_status(vms, now, elapsed_total)
    # Pad each line (by visible width, ignoring ANSI codes) so leftover
    # characters from a previous, longer render don't linger on screen.
    sys.stdout.write(
        "\n".join(pad_visible(line, DISPLAY_WIDTH) for line in block.split("\n")) + "\n"
    )
    sys.stdout.flush()
    return block.count("\n") + 1


def update_states(vms: list[VM], running: set[str], now: float) -> None:
    """Mark tracked VMs as OFF once they no longer appear in `running`."""
    for vm in vms:
        if vm.state == VMState.SHUTDOWN_SENT and vm.name not in running:
            vm.state = VMState.OFF
            vm.stopped_at = now


def main() -> int:
    print("Checking for running Virtual Machines...")

    running_names = get_running_vms_or_error()
    if running_names is None:
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
    failed: list[str] = []
    for vm in vms:
        print(f"Sending shutdown signal to: {vm.name}")
        outcome = send_shutdown(vm.name)
        if outcome is SignalResult.SENT:
            vm.state = VMState.SHUTDOWN_SENT
            vm.shutdown_sent_at = shutdown_time
        elif outcome is SignalResult.ALREADY_OFF:
            # It powered off between the initial list and now.
            vm.state = VMState.OFF
            vm.stopped_at = shutdown_time
        else:
            failed.append(vm.name)

    if failed:
        # These VMs were never asked to shut down, so waiting them out would
        # only produce a misleading "timed out" result; the VMs that did get
        # the signal keep shutting down in the background.
        print("----------------------------------------------------")
        print("ERROR: The following VMs could not be shut down gracefully:")
        for name in failed:
            print(f"  {name}")
        print("Check them with 'virsh list' / 'virsh console <vm_name>'.")
        return 1
    print("----------------------------------------------------")

    # Render the initial status block, then redraw it in place on every
    # display tick. `virsh` is only re-polled every CHECK_INTERVAL_SECONDS;
    # the display itself refreshes faster (DISPLAY_REFRESH_SECONDS) so the
    # elapsed-time counters visibly tick up in real time between polls.
    #
    # Only the VMs we are tracking decide when the wait ends: unrelated VMs
    # that start on the host during the wait are not this script's concern.
    rendered_lines = 0
    last_poll = shutdown_time

    try:
        while True:
            now = time.monotonic()
            elapsed_total = now - shutdown_time

            if now - last_poll >= CHECK_INTERVAL_SECONDS:
                running = get_running_vms_or_error()
                if running is None:
                    return 1
                last_poll = now
                update_states(vms, set(running), now)

            rendered_lines = paint_status(vms, now, elapsed_total, rendered_lines)

            if all(vm.state == VMState.OFF for vm in vms):
                break

            if elapsed_total >= TIMEOUT_SECONDS:
                # One final confirmation poll so a VM that stopped in the gap
                # between the last poll and the deadline is not reported as
                # having failed.
                running = get_running_vms_or_error()
                if running is None:
                    return 1
                update_states(vms, set(running), now)
                for vm in vms:
                    if vm.state == VMState.SHUTDOWN_SENT:
                        vm.state = VMState.TIMED_OUT
                # Re-render so the final "timed out" state is actually shown.
                paint_status(vms, now, elapsed_total, rendered_lines)
                break

            time.sleep(DISPLAY_REFRESH_SECONDS)
    except KeyboardInterrupt:
        print()
        print("Interrupted. VMs still shutting down continue in the background;")
        print("check their state with 'virsh list'.")
        return 130

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
