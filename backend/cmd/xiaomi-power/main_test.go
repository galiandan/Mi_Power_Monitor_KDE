package main

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeTestConfig(t *testing.T, value string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(path, []byte(value), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestLoadConfigDefaultsOmittedTimeout(t *testing.T) {
	path := writeTestConfig(t, `{"model":"cuco.plug.v3","ip":"192.168.10.100","token":"0123456789abcdef0123456789abcdef"}`)
	cfg, err := loadConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Timeout != 5 {
		t.Fatalf("timeout = %d, want 5", cfg.Timeout)
	}
}

func TestLoadConfigRejectsInvalidCredentialsAndTimeout(t *testing.T) {
	cases := []string{
		`{"model":"cuco.plug.v3","ip":"plug.local","token":"0123456789abcdef0123456789abcdef"}`,
		`{"model":"cuco.plug.v3","ip":"192.168.10.100","token":"REPLACE_WITH_DEVICE_TOKEN"}`,
		`{"model":"cuco.plug.v3","ip":"192.168.10.100","token":"0123456789abcdef0123456789abcdef","timeout":0}`,
		`{"model":"cuco.plug.v3","ip":"192.168.10.100","token":"0123456789abcdef0123456789abcdef","timeout":61}`,
	}
	for _, value := range cases {
		t.Run(value, func(t *testing.T) {
			if _, err := loadConfig(writeTestConfig(t, value)); err == nil {
				t.Fatal("loadConfig accepted an invalid configuration")
			}
		})
	}
}

func TestLoadConfigRejectsSymbolicLink(t *testing.T) {
	target := writeTestConfig(t, `{"model":"cuco.plug.v3","ip":"192.168.10.100","token":"0123456789abcdef0123456789abcdef"}`)
	link := filepath.Join(t.TempDir(), "config.json")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	if _, err := loadConfig(link); err == nil {
		t.Fatal("loadConfig accepted a symbolic-link configuration")
	}
}

func TestPrintReadingMatchesCollectorContract(t *testing.T) {
	originalStdout := os.Stdout
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	os.Stdout = writer
	printReading(true, 83.4, nil)
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	os.Stdout = originalStdout

	encoded, err := io.ReadAll(reader)
	if err != nil {
		t.Fatal(err)
	}
	if err := reader.Close(); err != nil {
		t.Fatal(err)
	}
	var result map[string]any
	if err := json.Unmarshal(encoded, &result); err != nil {
		t.Fatalf("invalid JSON output: %v", err)
	}
	if result["available"] != true || result["power"] != 83.4 || result["unit"] != "W" {
		t.Fatalf("unexpected collector reading: %s", strings.TrimSpace(string(encoded)))
	}
	if sampledAt, ok := result["sampled_at"].(string); !ok || sampledAt == "" {
		t.Fatalf("sampled_at missing from collector reading: %s", strings.TrimSpace(string(encoded)))
	}
}

func TestPrintUnavailableReadingUsesNullPower(t *testing.T) {
	originalStdout := os.Stdout
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	os.Stdout = writer
	printReading(true, 0, errors.New("LAN request timed out"))
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	os.Stdout = originalStdout
	encoded, err := io.ReadAll(reader)
	if err != nil {
		t.Fatal(err)
	}
	if err := reader.Close(); err != nil {
		t.Fatal(err)
	}
	var result map[string]any
	if err := json.Unmarshal(encoded, &result); err != nil {
		t.Fatalf("invalid JSON output: %v", err)
	}
	if result["available"] != false || result["power"] != nil || result["error"] == nil {
		t.Fatalf("unexpected unavailable reading: %s", strings.TrimSpace(string(encoded)))
	}
	if _, ok := result["sampled_at"]; ok {
		t.Fatalf("unavailable reading should not have sampled_at: %s", strings.TrimSpace(string(encoded)))
	}
}
