// A native executable stand-in; no shell or terminal window is needed on Windows.
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

func main() {
	if os.Getenv("FAKE_CRIER_IGNORE_TERM") == "1" {
		signal.Ignore(syscall.SIGTERM)
	}
	if out := os.Getenv("FAKE_CRIER_OUT"); out != "" {
		_ = os.MkdirAll(out, 0700)
		_ = os.WriteFile(filepath.Join(out, "argv"), []byte(strings.Join(os.Args[1:], "\n")+"\n"), 0600)
		_ = os.WriteFile(filepath.Join(out, "env"), []byte(strings.Join(os.Environ(), "\n")+"\n"), 0600)
		cwd, _ := os.Getwd()
		_ = os.WriteFile(filepath.Join(out, "cwd"), []byte(cwd+"\n"), 0600)
		entries, _ := os.ReadDir("/dev/fd")
		var fds []string
		for _, entry := range entries {
			fds = append(fds, entry.Name())
		}
		_ = os.WriteFile(filepath.Join(out, "fds"), []byte(strings.Join(fds, "\n")), 0600)
	}
	if os.Getenv("FAKE_CRIER_READ") == "1" {
		_, _ = io.Copy(os.Stdout, os.Stdin)
	}
	if delay := os.Getenv("FAKE_CRIER_SLEEP"); delay != "" {
		duration, err := time.ParseDuration(delay)
		if err != nil {
			seconds, _ := strconv.ParseFloat(delay, 64)
			duration = time.Duration(seconds * float64(time.Second))
		}
		time.Sleep(duration)
	}
	args := strings.Join(os.Args[1:], " ")
	var report any
	switch {
	case strings.Contains(args, "--version"):
		version := os.Getenv("FAKE_CRIER_VERSION")
		if version == "" {
			version = "1.1.1"
		}
		report = map[string]string{"version": version}
	case strings.Contains(args, "platforms"):
		report = map[string]any{"platforms": []string{"telegram", "discord"}}
	case strings.Contains(args, "ping"):
		report = []map[string]any{{"target": "telegram", "ok": true, "account": "fake", "ms": 1}}
	default:
		row := map[string]any{"platform": "smoke", "ok": true}
		if leak := os.Getenv("FAKE_CRIER_LEAK"); leak != "" {
			row["error"] = leak
		}
		report = map[string]any{"results": []any{row}}
	}
	_ = json.NewEncoder(os.Stdout).Encode(report)
	if leak := os.Getenv("FAKE_CRIER_LEAK"); leak != "" {
		fmt.Fprintln(os.Stderr, leak)
	}
	code, _ := strconv.Atoi(os.Getenv("FAKE_CRIER_EXIT"))
	os.Exit(code)
}
