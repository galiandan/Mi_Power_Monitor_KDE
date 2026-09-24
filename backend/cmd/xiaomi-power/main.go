// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Xiaomi Power Monitor contributors

// Command xiaomi-power reads cuco.plug.v3 live power over the local network.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"math"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/mberatsanli/miio"
)

const (
	model       = "cuco.plug.v3"
	powerSIID   = 11
	powerPIID   = 2
	defaultTick = time.Second
)

type config struct {
	Model   string `json:"model"`
	IP      string `json:"ip"`
	Token   string `json:"token"`
	Timeout int    `json:"timeout"`
}

type reading struct {
	Model     string   `json:"model"`
	Power     *float64 `json:"power"`
	Unit      string   `json:"unit"`
	Available bool     `json:"available"`
	Error     string   `json:"error,omitempty"`
}

func configPath() string {
	if root := os.Getenv("XDG_CONFIG_HOME"); root != "" {
		return filepath.Join(root, "xiaomi-power", "config.json")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return filepath.Join(".config", "xiaomi-power", "config.json")
	}
	return filepath.Join(home, ".config", "xiaomi-power", "config.json")
}

func loadConfig(path string) (config, error) {
	var cfg config
	data, err := os.ReadFile(path)
	if err != nil {
		return cfg, fmt.Errorf("cannot read config at %s: %w", path, err)
	}
	if err := json.Unmarshal(data, &cfg); err != nil {
		return cfg, fmt.Errorf("invalid JSON config: %w", err)
	}
	cfg.IP = strings.TrimSpace(cfg.IP)
	cfg.Token = strings.TrimSpace(cfg.Token)
	if cfg.Model != "" && cfg.Model != model {
		return cfg, fmt.Errorf("config model must be %s", model)
	}
	if strings.TrimSpace(cfg.IP) == "" {
		return cfg, errors.New("config is missing a non-empty 'ip' field")
	}
	if strings.TrimSpace(cfg.Token) == "" || strings.HasPrefix(cfg.Token, "REPLACE_") {
		return cfg, errors.New("config is missing a real device token")
	}
	if cfg.Timeout <= 0 {
		cfg.Timeout = 5
	}
	cfg.Model = model
	return cfg, nil
}

func readPower(ctx context.Context, client *miio.Client) (float64, error) {
	values, err := client.GetProperties(ctx, []miio.Property{{SIID: powerSIID, PIID: powerPIID}})
	if err != nil {
		if errors.Is(err, miio.ErrBadToken) {
			return 0, errors.New("LAN request rejected; check the device token")
		}
		if errors.Is(err, miio.ErrTimeout) {
			return 0, errors.New("LAN request timed out; check device IP, token, and network access")
		}
		return 0, errors.New("MIoT property read failed")
	}
	if len(values) != 1 || !values[0].OK() {
		return 0, errors.New("MIoT property 11.2 is unavailable")
	}
	power, err := values[0].Float()
	if err != nil || math.IsNaN(power) || math.IsInf(power, 0) || power < 0 {
		return 0, errors.New("device returned an invalid electric-power value")
	}
	return power, nil
}

func printReading(asJSON bool, power float64, err error) {
	if asJSON {
		result := reading{Model: model, Unit: "W", Available: err == nil}
		if err == nil {
			result.Power = &power
		} else {
			result.Error = err.Error()
		}
		_ = json.NewEncoder(os.Stdout).Encode(result)
		return
	}
	if err != nil {
		fmt.Printf("Device: %s\nPower: unavailable (%v)\n", model, err)
		return
	}
	fmt.Printf("Device: %s\nPower: %.1f W\n", model, power)
}

func startupFailure(asJSON bool, publicMessage, detail string) int {
	if asJSON {
		printReading(true, 0, errors.New(publicMessage))
	} else {
		fmt.Fprintln(os.Stderr, "xiaomi-power:", detail)
	}
	return 1
}

func run() int {
	jsonMode := flag.Bool("json", false, "print newline-delimited JSON readings")
	watch := flag.Bool("watch", false, "keep one process running and poll continuously")
	interval := flag.Duration("interval", defaultTick, "poll interval when using --watch")
	count := flag.Int("count", 0, "stop after this many watch readings (0 runs until interrupted)")
	flag.Parse()

	if *interval <= 0 {
		fmt.Fprintln(os.Stderr, "interval must be greater than zero")
		return 2
	}
	if *count < 0 {
		fmt.Fprintln(os.Stderr, "count cannot be negative")
		return 2
	}
	if *count > 0 {
		*watch = true
	}

	path := configPath()
	cfg, err := loadConfig(path)
	if err != nil {
		return startupFailure(*jsonMode, "cannot load config", err.Error())
	}
	// Ensure credentials stay private, including configs copied from the Python setup.
	if err := os.Chmod(path, 0o600); err != nil {
		return startupFailure(*jsonMode, "cannot secure config permissions", "cannot secure config file permissions")
	}
	if err := os.Chmod(filepath.Dir(path), 0o700); err != nil {
		return startupFailure(*jsonMode, "cannot secure config permissions", "cannot secure config directory permissions")
	}

	client, err := miio.New(cfg.IP, cfg.Token, miio.WithTimeout(time.Duration(cfg.Timeout)*time.Second), miio.WithRetries(1))
	if err != nil {
		return startupFailure(*jsonMode, "cannot create LAN client", "cannot create LAN client: "+err.Error())
	}
	defer client.Close()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := client.Handshake(ctx); err != nil {
		return startupFailure(*jsonMode, "LAN handshake failed; check IP, token, and LAN access", "LAN handshake failed; check IP, token, and LAN access: "+err.Error())
	}
	var ticker *time.Ticker
	if *watch {
		ticker = time.NewTicker(*interval)
		defer ticker.Stop()
	}

	readCtx, cancel := context.WithTimeout(ctx, time.Duration(cfg.Timeout)*time.Second)
	power, readErr := readPower(readCtx, client)
	cancel()
	printReading(*jsonMode, power, readErr)
	if !*watch {
		if readErr != nil {
			return 1
		}
		return 0
	}

	hadReadError := readErr != nil
	reads := 1
	for *count == 0 || reads < *count {
		select {
		case <-ctx.Done():
			return 0
		case <-ticker.C:
		}
		readCtx, cancel = context.WithTimeout(ctx, time.Duration(cfg.Timeout)*time.Second)
		power, readErr = readPower(readCtx, client)
		cancel()
		if readErr != nil {
			hadReadError = true
			// Refresh the device clock after transient packet loss or a long-running session.
			_ = client.Handshake(ctx)
		}
		printReading(*jsonMode, power, readErr)
		reads++
	}
	if hadReadError {
		return 1
	}
	return 0
}

func main() { os.Exit(run()) }
