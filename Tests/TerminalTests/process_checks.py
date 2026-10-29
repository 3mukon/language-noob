#!/usr/bin/env python3
"""Exercise the packaged terminal client with disposable data and a local fake service."""
import json
import os
from pathlib import Path
import select
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time


def main():
    executable = str(Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory(prefix="language-noob-terminal-", dir="/private/tmp") as scratch:
        root = Path(scratch)
        directory = root / "data"
        base = [executable, "--data-directory", str(directory)]

        def run(*args, input=None, code=0):
            result = subprocess.run(base + list(args), input=input, text=True, capture_output=True, timeout=20)
            assert result.returncode == code, (args, result.returncode, result.stdout, result.stderr)
            return result.stdout

        assert "命令行" in run("--help")
        assert json.loads(run("stats", "--lang", "en", "--json"))["vocabulary"] == 12126
        assert json.loads(run("stats", "--lang", "ja", "--json"))["vocabulary"] == 8505
        # A shell passes only the command name when resolving an installed PATH symlink.
        commands = root / "bin"
        commands.mkdir()
        (commands / "language-noob").symlink_to(executable)
        installed = subprocess.run(
            ["language-noob", "--data-directory", str(root / "installed-data"), "stats", "--lang", "en", "--json"],
            cwd=root, env=dict(os.environ, PATH=str(commands) + os.pathsep + os.environ.get("PATH", "")),
            text=True, capture_output=True, timeout=20,
        )
        assert installed.returncode == 0, (installed.stdout, installed.stderr)
        assert json.loads(installed.stdout)["vocabulary"] == 12126
        english = json.loads(run("search", "music", "--lang", "en", "--json"))
        assert english and all(word["language"] == "en" for word in english)
        assert json.loads(run("info", "ecdict-music", "--lang", "en", "--json"))["text"] == "music"
        run("learn", input="q\n", code=2)
        run("nonsense", code=2)
        run("learn", "--new-limit", "101", code=2)
        run("stats", "--limit", "3", code=2)
        run("info", "missing-entry", code=2)
        run("config", "key", "set", "not-accepted-as-an-argument", code=2)

        # Preserve the real installation marker, replacing only this disposable vocabulary.
        with sqlite3.connect(directory / "study.sqlite") as db:
            for table in ["history", "enrichment", "progress", "words"]:
                db.execute("DELETE FROM " + table)
        english_file = root / "english.json"
        english_file.write_text(json.dumps({"version": "1.0", "language": "en", "words": [
            {"id": "fixture", "text": "fixture-word", "chinese_def": "fixture-meaning", "pronunciation": "/reading/", "part_of_speech": "名词"}
        ]}))
        japanese_file = root / "japanese.json"
        japanese_file.write_text(json.dumps({"version": "1.0", "language": "ja", "words": [
            {"id": "fixture", "text": "空", "pronunciation": "そら"}
        ]}))
        run("import", str(english_file)); run("import", str(japanese_file))
        run("config", "set", "new-limit", "1", "provider", "claude", "effort", "high")
        assert json.loads(run("config", "show", "--json"))["assistant"]["enrichmentConcurrency"] == 1
        run("config", "set", "enrichment-concurrency", "3")
        assert json.loads(run("config", "show", "--json"))["assistant"]["enrichmentConcurrency"] == 3
        run("config", "set", "enrichment-concurrency", "9", code=2)
        run("config", "unset", "enrichment-concurrency")
        assert json.loads(run("config", "show", "--json"))["assistant"]["enrichmentConcurrency"] == 1
        run("config", "set", "executable", str(root / "unavailable-service"))
        run("config", "set", "language", "ja")
        config = json.loads(run("config", "show", "--json"))
        assert config["language"] == "ja" and config["assistant"]["effort"] == "high"
        run("config", "unset", "effort")
        config = json.loads(run("config", "show", "--json"))
        assert config["assistant"]["effort"] == "" and config["newLimit"] == 1
        run("config", "set", "language", "en")
        transcript = run("learn", "--batch", input="prev\nask hidden-question\n4\nq\n")
        assert "回想  2 / 2" in transcript and "先查看答案" in transcript and "先输入 reveal" in transcript
        hidden = transcript.split("回想  2 / 2", 1)[1]
        assert "fixture-word" not in hidden and "/reading/" not in hidden
        assert json.loads(run("stats", "--lang", "en", "--json"))["totalReviews"] == 0
        transcript = run("learn", "--batch", input="prev\nnext\nprev\nreveal\n1\nreveal\n4\nq\n")
        assert "再回想" in transcript and "本轮完成了 2" in transcript
        assert json.loads(run("stats", "--lang", "en", "--json"))["totalReviews"] == 2
        assert json.loads(run("stats", "--lang", "ja", "--json"))["totalReviews"] == 0
        transcript = run("learn", "--lang", "ja", "--batch", input="prev\nq\n")
        assert "日语 · 回想" in transcript and "fixture-word" not in transcript
        transcript = run("learn", "--batch", input="search fixture\nopen fixture\npractice\nprev\nreveal\n4\nq\n")
        assert "词库浏览" in transcript and "已记录这次复习" in transcript
        before = json.loads(run("stats", "--json"))["totalReviews"]
        run("study", "--batch", input="")
        assert json.loads(run("stats", "--json"))["totalReviews"] == before
        broken = root / "invalid.json"; broken.write_text('{"words": []}')
        run("import", str(broken), code=1)
        assert json.loads(run("stats", "--json"))["totalReviews"] == before

        # Automatic study enrichment saves once and is then reused by every command.
        automatic_service = root / "automatic-assistant"
        request_log = root / "automatic-requests.txt"
        automatic_service.write_text("#!/usr/bin/env python3\n" + "\n".join([
            "import json, sys, time",
            "if '--help' in sys.argv:",
            "    print('--no-session-persistence --include-partial-messages --tools --strict-mcp-config --setting-sources'); sys.exit(0)",
            "sys.stdin.read()",
            f"with open({str(request_log)!r}, 'a') as calls: calls.write('request\\n')",
            "text = json.dumps({'pronunciation':'そら','chinese_def':'天空（自动补全）','part_of_speech':'名词','examples':[]}, ensure_ascii=False)",
            "print(json.dumps({'type':'stream_event','event':{'delta':{'type':'text_delta','text':text[:20]}}}), flush=True)",
            "time.sleep(.15)",
            "print(json.dumps({'type':'stream_event','event':{'delta':{'type':'text_delta','text':text[20:]}}}), flush=True)",
            "print(json.dumps({'type':'result','subtype':'success','result':text,'is_error':False}), flush=True)",
        ]) + "\n")
        automatic_service.chmod(0o700)
        run("config", "set", "executable", str(automatic_service))
        process = subprocess.Popen(base + ["learn", "--lang", "ja", "--batch"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            output = b""; deadline = time.monotonic() + 10
            while "天空（自动补全）".encode() not in output and time.monotonic() < deadline:
                ready, _, _ = select.select([process.stdout], [], [], .2)
                if ready: output += os.read(process.stdout.fileno(), 65536)
            assert "天空（自动补全）".encode() in output, output.decode(errors="replace")
            assert "正在补全".encode() in output and b'chinese_def' not in output
            process.stdin.write(b"enrich\nenrich\nprev\nnew learn\nq\n"); process.stdin.flush()
            tail, errors = process.communicate(timeout=6)
            assert process.returncode == 0, errors
            assert tail.decode().count("已使用本地保存的结果") == 2
            assert "enrich --force" in tail.decode()
            hidden = tail.decode().split("回想  2 / 2", 1)[1].split("日语 · 初识", 1)[0]
            assert "天空（自动补全）" in hidden and "そら" not in hidden and "名词" not in hidden
            assert request_log.read_text().splitlines() == ["request"], "cached words must not regenerate on navigation or a new round"
        finally:
            if process.poll() is None: process.kill(); process.communicate()
        cached = json.loads(run("info", "fixture", "--lang", "ja", "--json"))
        assert cached["chinese_def"] == "天空（自动补全）"
        assert json.loads(run("search", "天空", "--lang", "ja", "--json"))[0]["id"] == "fixture"
        reopened = run("learn", "--lang", "ja", "--batch", input="enrich\nq\n")
        assert "已使用本地保存的结果" in reopened and "已加入补全队列" not in reopened
        assert request_log.read_text().splitlines() == ["request"], "a fresh process must reuse saved enrichment"

        # Slow real process protocol: prove output precedes completion, then cancel it.
        service = root / "assistant-fixture"
        pidfile = root / "service.pid"
        service.write_text("#!/usr/bin/env python3\n" + "\n".join([
            "import json, os, signal, sys, time",
            "if '--help' in sys.argv:",
            "    print('--no-session-persistence --include-partial-messages --tools --strict-mcp-config --setting-sources'); sys.exit(0)",
            "signal.signal(signal.SIGTERM, signal.SIG_IGN)",
            f"open({str(pidfile)!r}, 'w').write(str(os.getpid()))",
            "sys.stdin.read()",
            "print(json.dumps({'type':'stream_event','event':{'delta':{'type':'text_delta','text':'FIRST-CHUNK'}}}), flush=True)",
            "time.sleep(10)",
            "print(json.dumps({'type':'result','subtype':'success','result':'FIRST-CHUNK','is_error':False}), flush=True)",
        ]) + "\n")
        service.chmod(0o700)
        run("config", "set", "executable", str(service))

        def pending_reply(ending, automatic=False):
            pidfile.unlink(missing_ok=True)
            process = subprocess.Popen(base + ["learn", "--lang", "ja", "--batch"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                if not automatic:
                    process.stdin.write(b"ask example-question\n"); process.stdin.flush()
                output = b""; deadline = time.monotonic() + 10
                def started(): return pidfile.exists() if automatic else b"FIRST-CHUNK" in output
                while not started() and time.monotonic() < deadline:
                    ready, _, _ = select.select([process.stdout], [], [], .2)
                    if ready:
                        chunk = os.read(process.stdout.fileno(), 65536)
                        if not chunk: break
                        output += chunk
                assert started(), output.decode(errors="replace")
                if automatic: assert b"FIRST-CHUNK" not in output, "partial enrichment must not be rendered as a reply"
                assert process.poll() is None, "stream must appear before provider completion"
                if ending == "signal": process.send_signal(signal.SIGINT)
                else: process.stdin.close(); process.stdin = None
                tail, errors = process.communicate(timeout=6)
                assert process.returncode == (130 if ending == "signal" else 0), (output, tail, errors)
                pid = int(pidfile.read_text())
                try: os.kill(pid, 0)
                except ProcessLookupError: pass
                else: raise AssertionError("cancelled assistant process survived terminal exit")
            finally:
                if process.poll() is None: process.kill(); process.communicate()

        pending_reply("signal")
        pending_reply("eof")
        with sqlite3.connect(directory / "study.sqlite") as db:
            db.execute("DELETE FROM enrichment WHERE language='ja'")
        pending_reply("signal", automatic=True)
        pending_reply("eof", automatic=True)
        assert json.loads(run("stats", "--lang", "en", "--json"))["totalReviews"] == before
        print("PASS: packaged CLI counts, commands, language separation, circular transcripts, hidden answers, automatic cached enrichment, streamed replies and SIGINT/EOF cleanup")


if __name__ == "__main__":
    main()
