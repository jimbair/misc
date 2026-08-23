#!/usr/bin/env python3
"""Graceful KVM Virtual Machine Shutdown Script

Helps with patching the hypervisor when the automatic reboot handling acts
a bit funny. Sends ACPI shutdown to all running VMs, then displays a live
per-VM status table (state + elapsed time) until everything is off or the
timeout is reached. Only VMs that were running when the script started are
tracked; unrelated VMs started on the host during the wait do not keep it
waiting.

Before reporting success, the script re-checks the host's full domain
inventory: if any tracked VM is running again, or cannot be confirmed shut
off (e.g. it is paused or suspended), it reports the VM and exits 1 so the
hypervisor is not patched over a live guest.

Transient `virsh list` failures are tolerated (up to
MAX_CONSECUTIVE_POLL_FAILURES in a row) so one libvirt hiccup does not
abort an otherwise healthy shutdown.

On terminals too narrow or short for the in-place status block, the
display degrades to append-style output (one block per state change)
instead of corrupting the screen.
"""

from __future__ import annotations

import shutil
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

# Consecutive failed `virsh list` polls tolerated inside the wait loop
# before giving up. One blip (e.g. "Failed to connect to the hypervisor")
# should not kill a five-minute operation; a persistent outage should.
MAX_CONSECUTIVE_POLL_FAILURES = 3

# Status-table geometry. The name column shrinks to fit the terminal; if
# even the minimum does not fit (or the block would exceed the terminal
# height), the display falls back to append-style output.
NAME_WIDTH_MAX = 30
MIN_NAME_WIDTH = 12
STATE_WIDTH = 20
ELAPSED_WIDTH = 7  # headroom past 999.9s without wrapping the line
ELAPSED_SUFFIX = "s elapsed"
# Leading indent + separator + state column + separator + elapsed field
# + suffix, i.e. everything on a status line except the name itself.
FIXED_LINE_OVERHEAD = 1 + 1 + STATE_WIDTH + 1 + ELAPSED_WIDTH + len(ELAPSED_SUFFIX)

# ANSI color codes for the live status display
COLOR_RESET = "\033[0m"
COLOR_YELLOW = "\033[33m"   # in progress / waiting
COLOR_GREEN = "\033[32m"    # success / off
COLOR_RED = "\033[31m"      # timed out / failure / needs attention
COLOR_GRAY = "\033[90m"     # idle / not yet started
COLOR_MAGENTA = "\033[35m"  # paused/suspended (distinct from TIMED_OUT's red)


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
    SUSPENDED = "paused/suspended"  # left `running` without powering off
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
            VMState.SUSPENDED: COLOR_MAGENTA,
            VMState.TIMED_OUT: COLOR_RED,
        }[self.state]

    def status_line(self, now: float, name_width: int = NAME_WIDTH_MAX) -> str:
        """Single-line status for the live display. Callers that don't know
        the terminal geometry get the maximum name column."""
        elapsed = self.elapsed(now)
        state_text = colorize(f"{self.state.value:<{STATE_WIDTH}}", self.state_color())
        name = self.name
        if len(name) > name_width:
            name = name[: name_width - 1] + "…"  # keep the status columns aligned
        return (
            f" {name:<{name_width}} {state_text} {elapsed:{ELAPSED_WIDTH}.1f}{ELAPSED_SUFFIX}"
        )


def _virsh_list_names(state_flag: str) -> list[str]:
    """Run `virsh list <state_flag> --name` and return the non-empty lines.

    Raises whatever subprocess.run raises (FileNotFoundError,
    subprocess.TimeoutExpired, subprocess.CalledProcessError, OSError);
    callers decide how to report failures.
    """
    result = subprocess.run(
        ["virsh", "list", state_flag, "--name"],
        capture_output=True,
        text=True,
        check=True,
        timeout=VIRSH_TIMEOUT_SECONDS,
    )
    return [line for line in result.stdout.splitlines() if line.strip()]


def get_running_vms() -> list[str]:
    """Return the names of all currently running VMs."""
    return _virsh_list_names("--state-running")


def poll_domain_states() -> tuple[set[str], set[str]]:
    """Return (running, shutoff) name sets for all domains on the host.

    Polling the full domain inventory (rather than treating "absent from
    the running list" as off) is what lets the script distinguish a guest
    that powered off from one that is merely paused or suspended.
    """
    running = set(_virsh_list_names("--state-running"))
    shutoff = set(_virsh_list_names("--state-shutoff"))
    return running, shutoff


def describe_virsh_failure(exc: BaseException) -> tuple[str, bool]:
    """Map a virsh failure to (message, is_fatal).

    Fatal means retrying cannot help (the binary is gone/unrunnable in a
    new way); everything else is worth tolerating briefly.
    """
    if isinstance(exc, FileNotFoundError):
        return ("ERROR: 'virsh' was not found on this system.", True)
    if isinstance(exc, PermissionError):
        return (f"ERROR: 'virsh' is not executable: {exc}", True)
    if isinstance(exc, subprocess.TimeoutExpired):
        return (
            f"WARNING: 'virsh list' timed out after {VIRSH_TIMEOUT_SECONDS:g}s "
            "(is the libvirt daemon hung?)",
            False,
        )
    if isinstance(exc, subprocess.CalledProcessError):
        detail = (exc.stderr or "").strip() or str(exc)
        return (f"WARNING: Failed to query running VMs: {detail}", False)
    if isinstance(exc, OSError):
        return (f"WARNING: Failed to run 'virsh': {exc}", False)
    return (f"WARNING: 'virsh list' failed: {exc}", False)


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
    except OSError as exc:  # missing or unrunnable virsh binary
        print(
            f"WARNING: Could not run 'virsh' ({exc}); cannot shut down {vm_name}.",
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

    # The guest may have powered off between the initial list and now.
    # Match on actual state rather than libvirt's (possibly localized)
    # error text: re-query and trust the answer, not the phrasing.
    try:
        if vm_name in _virsh_list_names("--state-shutoff"):
            print(f"NOTE: {vm_name} is already off; no shutdown signal needed.")
            return SignalResult.ALREADY_OFF
    except (OSError, subprocess.SubprocessError):
        pass  # fall through and report the original failure

    print(
        f"WARNING: 'virsh shutdown {vm_name}' failed: "
        f"{stderr or f'exit status {result.returncode}'}",
        file=sys.stderr,
    )
    return SignalResult.FAILED


def render_lines(
    vms: list[VM],
    now: float,
    elapsed_total: float,
    name_width: int,
    notice: str | None,
) -> list[str]:
    """Build the status block as a list of logical lines."""
    total_width = name_width + FIXED_LINE_OVERHEAD
    lines = [
        f"Waiting for VMs to power off (timeout: {TIMEOUT_SECONDS:g})...",
        f"Total elapsed: {elapsed_total:{ELAPSED_WIDTH}.1f}s",
        "",
    ]
    if notice:
        lines.append(notice[:total_width])
    lines.extend(vm.status_line(now, name_width) for vm in vms)
    return lines


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


def paint_in_place(
    lines: list[str], previous_lines: int, width: int
) -> int:
    """Redraw the status block over the previously drawn one and return the
    number of terminal rows it now occupies (including blank rows kept
    cleared so a shrinking block does not leave stale lines behind)."""
    move_cursor_up(previous_lines)
    out = [pad_visible(line, width) for line in lines]
    clear_extra = max(0, previous_lines - len(out))
    # Re-pad any rows the old block occupied but the new one does not, so
    # nothing stale survives a smaller render.
    out.extend(" " * width for _ in range(clear_extra))
    sys.stdout.write("\n".join(out) + "\n")
    sys.stdout.flush()
    return len(out)


def fitting_name_width(columns: int) -> int | None:
    """Largest status-table name column that fits in `columns`, or None if
    even the minimum does not (caller should degrade to append output)."""
    available = columns - FIXED_LINE_OVERHEAD
    if available < MIN_NAME_WIDTH:
        return None
    return min(NAME_WIDTH_MAX, available)


def update_states(
    vms: list[VM], running: set[str], shutoff: set[str], now: float
) -> None:
    """Advance tracked VMs' states from one full domain inventory.

    Only guests confirmed in the shutoff set count as OFF. A tracked guest
    that is neither running nor shut off (paused, pmsuspended, crashed...)
    is surfaced as SUSPENDED instead of being silently celebrated as off.
    """
    for vm in vms:
        if vm.state is VMState.OFF:
            continue
        if vm.name in shutoff:
            vm.state = VMState.OFF
            vm.stopped_at = now
        elif vm.name in running:
            # e.g. resumed after being suspended; back to ordinary waiting.
            if vm.state is VMState.SUSPENDED:
                vm.state = VMState.SHUTDOWN_SENT
        elif vm.state is VMState.SHUTDOWN_SENT:
            vm.state = VMState.SUSPENDED


def main() -> int:
    # When piped, stdout would otherwise be block-buffered and interleave
    # out of order with the (unbuffered) stderr warnings in redirected logs.
    if not sys.stdout.isatty() and hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(line_buffering=True)

    print("Checking for running Virtual Machines...")

    signals_sent = 0

    try:
        try:
            running_names = get_running_vms()
        except Exception as exc:  # noqa: BLE001 - mapped below
            message, _fatal = describe_virsh_failure(exc)
            print(message, file=sys.stderr)
            return 1

        if not running_names:
            print("No running VMs found.")
            return 0

        vms = [VM(name=name) for name in running_names]

        print("Initiating graceful shutdown for the following VMs:")
        for vm in vms:
            print(f"    {vm.name}")
        print("----------------------------------------------------")

        shutdown_time = time.monotonic()

        failed: list[str] = []
        for vm in vms:
            print(f"Sending shutdown signal to: {vm.name}")
            outcome = send_shutdown(vm.name)
            if outcome is SignalResult.SENT:
                vm.state = VMState.SHUTDOWN_SENT
                vm.shutdown_sent_at = time.monotonic()
                signals_sent += 1
            elif outcome is SignalResult.ALREADY_OFF:
                # It powered off between the initial list and now.
                vm.state = VMState.OFF
                vm.stopped_at = time.monotonic()
            else:
                failed.append(vm.name)

        if failed:
            # These VMs were never asked to shut down, so waiting them out would
            # only produce a misleading "timed out" result; the VMs that did get
            # the signal keep shutting down in the background.
            print("----------------------------------------------------")
            print("ERROR: The following VMs could not be shut down gracefully:")
            for name in failed:
                print(f"    {name}")
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
        #
        # If the terminal is too narrow or short for the in-place block (or
        # stdout is not a TTY), fall back to append-style output: a fresh block
        # is printed only when something actually changes, keeping logs clean
        # and narrow screens uncorrupted.
        rendered_lines = 0
        repaint_ok = tty_enabled()
        in_place_used = False
        previous_signature: tuple | None = None
        notice: str | None = None
        consecutive_poll_failures = 0
        suspended_before: list[str] = []
        last_poll = shutdown_time

        while True:
            now = time.monotonic()
            elapsed_total = now - shutdown_time

            if now - last_poll >= CHECK_INTERVAL_SECONDS:
                try:
                    running, shutoff = poll_domain_states()
                except Exception as exc:  # noqa: BLE001 - mapped below
                    message, fatal = describe_virsh_failure(exc)
                    if fatal:
                        print(message, file=sys.stderr)
                        return 1
                    consecutive_poll_failures += 1
                    notice = (
                        f"WARNING (poll {consecutive_poll_failures}/"
                        f"{MAX_CONSECUTIVE_POLL_FAILURES}): "
                        f"{message.removeprefix('WARNING: ')}"
                    )
                    if not (repaint_ok and in_place_used):
                        print(message, file=sys.stderr)
                    if consecutive_poll_failures >= MAX_CONSECUTIVE_POLL_FAILURES:
                        print(
                            f"ERROR: 'virsh list' failed "
                            f"{consecutive_poll_failures} times in a row; giving up.",
                            file=sys.stderr,
                        )
                        return 1
                else:
                    consecutive_poll_failures = 0
                    notice = None
                    last_poll = now
                    update_states(vms, running, shutoff, now)

            term = shutil.get_terminal_size()
            name_width = fitting_name_width(term.columns)
            lines = render_lines(
                vms,
                now,
                elapsed_total,
                name_width if name_width is not None else MIN_NAME_WIDTH,
                notice,
            )
            signature = tuple(vm.state for vm in vms)

            # +1: leave room so the trailing newline cannot scroll the screen.
            can_paint_in_place = (
                repaint_ok
                and name_width is not None
                and len(lines) + 1 <= term.lines
            )

            if can_paint_in_place:
                in_place_used = True
                rendered_lines = paint_in_place(
                    lines,
                    rendered_lines,
                    name_width + FIXED_LINE_OVERHEAD,
                )
            else:
                # Degraded mode. Stick with it for the rest of the run: once the
                # block has been appended (or the window resized mid-run), trying
                # to repaint in place would corrupt the scrollback.
                repaint_ok = repaint_ok and not in_place_used
                if signature != previous_signature:
                    for line in lines:
                        print(line.rstrip())
                    previous_signature = signature
                rendered_lines = 0

            if all(vm.state is VMState.OFF for vm in vms):
                break

            if elapsed_total >= TIMEOUT_SECONDS:
                # One final confirmation poll so a VM that stopped in the gap
                # between the last poll and the deadline is not reported as
                # having failed.
                try:
                    running, shutoff = poll_domain_states()
                    update_states(vms, running, shutoff, now)
                except Exception as exc:  # noqa: BLE001 - mapped below
                    message, _fatal = describe_virsh_failure(exc)
                    print(
                        "WARNING: final confirmation poll failed "
                        f"({message.removeprefix('WARNING: ')})",
                        file=sys.stderr,
                    )

                suspended_before = [
                    vm.name for vm in vms if vm.state is VMState.SUSPENDED
                ]
                for vm in vms:
                    if vm.state in (VMState.SHUTDOWN_SENT, VMState.SUSPENDED):
                        vm.state = VMState.TIMED_OUT
                # Re-render so the final "timed out" state is actually shown.
                if can_paint_in_place:
                    paint_in_place(
                        render_lines(vms, now, elapsed_total, name_width, None),
                        rendered_lines,
                        name_width + FIXED_LINE_OVERHEAD,
                    )
                break

            time.sleep(DISPLAY_REFRESH_SECONDS)

        print()

        remaining = [vm for vm in vms if vm.state is VMState.TIMED_OUT]
        if remaining:
            print(
                "WARNING: Time-out reached. The following VMs failed to shut down "
                "gracefully:"
            )
            for vm in remaining:
                print(f"    {vm.name}")
            print()
            print(
                "Action required: Log into the guests to check for hung processes, "
                "or use 'virsh destroy <vm_name>' to force a hard power-off."
            )
            if any(vm.name in suspended_before for vm in remaining):
                print(
                    "Note: some of these were paused/suspended rather than off; "
                    "'virsh resume <vm_name>' lets them process the shutdown signal."
                )
            return 1

        # Success is not declared until re-confirmed against the host: a
        # tracked VM that powered off and then restarted must not green-light
        # a hypervisor patch -- and neither may one that is alive but not
        # running (paused, pmsuspended, crashed), which a running-only check
        # would silently wave through.
        try:
            running_now, shutoff_now = poll_domain_states()
        except Exception as exc:  # noqa: BLE001 - mapped below
            message, _fatal = describe_virsh_failure(exc)
            print(
                f"ERROR: Could not verify final VM states: "
                f"{message.removeprefix('WARNING: ')}"
            )
            print("Refusing to report success without verification.")
            return 1

        restarted = sorted(vm.name for vm in vms if vm.name in running_now)
        unconfirmed = sorted(
            vm.name for vm in vms
            if vm.name not in running_now and vm.name not in shutoff_now
        )
        if restarted or unconfirmed:
            if restarted:
                print("ERROR: The following VMs shut down but have started again:")
                for name in restarted:
                    print(f"    {name}")
            if unconfirmed:
                print(
                    "ERROR: The following VMs could not be confirmed shut off "
                    "(they may be paused, suspended, or in an unknown state):"
                )
                for name in unconfirmed:
                    print(f"    {name}")
                print("Check each with 'virsh domstate <vm_name>'.")
            print()
            print(
                "Action required: Resolve them (shut down, or resume and shut"
                " down) before patching the hypervisor."
            )
            return 1

        print("SUCCESS: All Virtual Machines have safely shut down.")
        return 0

    except KeyboardInterrupt:
        print()
        print("Interrupted.", end="")
        if signals_sent:
            print(
                f" Shutdown signals were already sent to {signals_sent} VM(s);"
                " they continue shutting down in the background."
            )
        else:
            print()
        print("Check their state with 'virsh list'.")
        return 130


if __name__ == "__main__":
    sys.exit(main())
