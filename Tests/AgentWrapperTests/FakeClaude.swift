import Foundation

/// A stand-in for `claude -p` in stream JSON: it says its session, then
/// answers each turn with "echo: <words>" and ends the turn. Written to a
/// temporary file as a Python script.
enum FakeClaude {
    static let script = #"""
    import json, sys
    print(json.dumps({"type": "system", "subtype": "init", "session_id": "fake-session", "model": "fake-model"}), flush=True)
    turn = 0
    for line in sys.stdin:
        message = json.loads(line)
        words = message["message"]["content"]
        turn += 1
        print(json.dumps({"type": "assistant", "message": {"id": "msg-%d" % turn, "content": [
            {"type": "tool_use", "id": "tool-%d" % turn, "name": "Bash", "input": {"command": "true"}}]}}), flush=True)
        print(json.dumps({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "tool-%d" % turn}]}}), flush=True)
        print(json.dumps({"type": "assistant", "message": {"id": "msg-%d" % turn, "content": [{"type": "text", "text": "echo: " + words}]}}), flush=True)
        print(json.dumps({"type": "result", "subtype": "success", "is_error": False, "result": "echo: " + words}), flush=True)
    """#

    /// The script's path, made once.
    static let path = write(script)

    /// A stand-in that can be interrupted, as Claude Code 2.1 is: each line
    /// it is sent is kept in the file its first argument names, when it has
    /// one. "slow …" begins a turn it doesn't end by itself; "where" is
    /// answered with its working directory, anything else with "echo: …".
    /// A control request to interrupt is answered with a control response
    /// and, in a turn, Claude's "[Request interrupted by user]" and its
    /// error_during_execution result; it carries on for the next message.
    static let interruptibleScript = #"""
    import json, os, sys
    record = open(sys.argv[1], "a") if len(sys.argv) > 1 and not sys.argv[1].startswith("-") else None
    def say(line):
        print(json.dumps(line), flush=True)
    say({"type": "system", "subtype": "init", "session_id": "fake-session", "model": "fake-model"})
    busy = False
    turn = 0
    for line in sys.stdin:
        if record:
            record.write(line)
            record.flush()
        message = json.loads(line)
        if message["type"] == "user":
            words = message["message"]["content"]
            turn += 1
            if words.startswith("slow"):
                busy = True
                say({"type": "assistant", "message": {"id": "msg-%d" % turn, "content": [{"type": "text", "text": "working on: " + words}]}})
                continue
            answer = "here: " + os.getcwd() if words == "where" else "echo: " + words
            say({"type": "assistant", "message": {"id": "msg-%d" % turn, "content": [{"type": "text", "text": answer}]}})
            say({"type": "result", "subtype": "success", "is_error": False, "result": answer})
        elif message["type"] == "control_request" and message["request"]["subtype"] == "interrupt":
            say({"type": "control_response", "response": {"subtype": "success", "request_id": message["request_id"], "response": {"still_queued": []}}})
            if busy:
                busy = False
                say({"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": "[Request interrupted by user]"}]}})
                say({"type": "result", "subtype": "error_during_execution", "is_error": True, "result": None,
                     "terminal_reason": "aborted_streaming"})
    """#

    /// The interruptible stand-in's path, made once.
    static let interruptible = write(interruptibleScript)

    /// A Python script as an executable temporary file: its path.
    static func write(_ script: String) -> String {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("fake-claude-\(UUID().uuidString.prefix(8)).py")
        try? Data(("#!/usr/bin/env python3\n" + script).utf8).write(to: file)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file.path
    }
}
