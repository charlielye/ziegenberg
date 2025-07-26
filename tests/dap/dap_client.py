#!/usr/bin/env python3
"""
Shared DAP client for testing the debug adapter.
"""

import subprocess
import json
import time
import threading
import queue
import os
from typing import Dict, List, Optional, Any

class DapClient:
    """Simple DAP client for testing the debug adapter."""

    def __init__(self, cmd: List[str]):
        # Change to the repo root directory for execution
        repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), '../..'))
        self.process = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=repo_root
        )
        self.seq = 1
        self.messages = queue.Queue()
        self.running = True

        # Start threads for reading stdout and stderr
        self.stdout_thread = threading.Thread(target=self._read_stdout)
        self.stderr_thread = threading.Thread(target=self._read_stderr)
        self.stdout_thread.daemon = True
        self.stderr_thread.daemon = True
        self.stdout_thread.start()
        self.stderr_thread.start()

    def _create_message(self, obj: Dict[str, Any]) -> bytes:
        """Create a DAP protocol message with Content-Length header."""
        json_str = json.dumps(obj)
        content_length = len(json_str.encode('utf-8'))
        return f"Content-Length: {content_length}\r\n\r\n{json_str}".encode('utf-8')

    def _read_stdout(self):
        """Read DAP messages from stdout."""
        while self.running:
            try:
                # Read Content-Length header
                header = self.process.stdout.readline().decode('utf-8')
                if not header or not header.startswith('Content-Length:'):
                    continue

                content_length = int(header.split(':')[1].strip())

                # Read empty line
                self.process.stdout.readline()

                # Read JSON body
                json_body = self.process.stdout.read(content_length).decode('utf-8')
                msg = json.loads(json_body)
                self.messages.put(msg)
            except Exception as e:
                if self.running:
                    print(f"Error reading stdout: {e}")
                break

    def _read_stderr(self):
        """Read debug output from stderr."""
        for line in self.process.stderr:
            if self.running:
                print(f"[DEBUG] {line.decode('utf-8').rstrip()}")

    def send_request(self, command: str, arguments: Optional[Dict[str, Any]] = None) -> int:
        """Send a DAP request and return the sequence number."""
        request = {
            "seq": self.seq,
            "type": "request",
            "command": command
        }
        if arguments:
            request["arguments"] = arguments

        msg = self._create_message(request)
        self.process.stdin.write(msg)
        self.process.stdin.flush()

        seq = self.seq
        self.seq += 1
        return seq

    def wait_for_response(self, seq: int, timeout: float = 2.0) -> Optional[Dict[str, Any]]:
        """Wait for a response to a specific request."""
        start_time = time.time()
        while time.time() - start_time < timeout:
            try:
                msg = self.messages.get(timeout=0.1)
                if msg.get('type') == 'response' and msg.get('request_seq') == seq:
                    return msg
                # Put it back if it's not what we're looking for
                self.messages.put(msg)
            except queue.Empty:
                pass
        return None

    def wait_for_event(self, event_name: str, timeout: float = 2.0) -> Optional[Dict[str, Any]]:
        """Wait for a specific event."""
        start_time = time.time()
        while time.time() - start_time < timeout:
            try:
                msg = self.messages.get(timeout=0.1)
                if msg.get('type') == 'event' and msg.get('event') == event_name:
                    return msg
                # Put it back if it's not what we're looking for
                self.messages.put(msg)
            except queue.Empty:
                pass
        return None

    def get_all_messages(self, timeout: float = 0.5) -> List[Dict[str, Any]]:
        """Get all pending messages."""
        messages = []
        start_time = time.time()
        while time.time() - start_time < timeout:
            try:
                msg = self.messages.get(timeout=0.1)
                messages.append(msg)
            except queue.Empty:
                break
        return messages

    def shutdown(self):
        """Shutdown the client and terminate the process."""
        self.running = False
        self.process.terminate()
        self.process.wait()