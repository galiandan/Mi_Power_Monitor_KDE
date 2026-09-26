// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Xiaomi Power Monitor contributors

// Command xiaomi-power reads cuco.plug.v3 live power over the local network.
package main

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"math"
	"net"
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
	Model     string     `json:"model"`
	Power     *float64   `json:"power"`
	Unit      string     `json:"unit"`
	Available bool       `json:"available"`
	SampledAt *time.Time `json:"sampled_at,omitempty"`
	Error     string     `json:"error,omitempty"`
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
	info, err := os.Lstat(path)
	if err == nil && info.Mode()&os.ModeSymlink != 0 {
		return cfg, errors.New("config file must not be a symbolic link")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return cfg, fmt.Errorf("cannot read config at %s: %w", path, err)
	}
	if err := json.Unmarshal(data, &cfg); err != nil {
		return cfg, fmt.Errorf("invalid JSON config: %w", err)
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil || fields == nil {
		return cfg, errors.New("config must be a JSON object")
	}
	cfg.IP = strings.TrimSpace(cfg.IP)
	cfg.Token = strings.TrimSpace(cfg.Token)
	if cfg.Model != "" && cfg.Model != model {
		return cfg, fmt.Errorf("config model must be %s", model)
	}
	if net.ParseIP(cfg.IP) == nil {
		return cfg, errors.New("config 'ip' must be a valid IPv4 or IPv6 address")
	}
	if decoded, err := hex.DecodeString(cfg.Token); err != nil || len(decoded) != 16 {
		return cfg, errors.New("config token must be a 32-character hexadecimal device token")
	}
	if _, present := fields["timeout"]; !present {
		cfg.Timeout = 5
	} else if cfg.Timeout < 1 || cfg.Timeout > 60 {
		return cfg, errors.New("config timeout must be between 1 and 60 seconds")
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
			sampledAt := time.Now().UTC()
			result.SampledAt = &sampledAt
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
	setup := flag.Bool("setup-cloud-qr", false, "configure the plug using local browser QR login")
	validate := flag.Bool("validate-config", false, "validate device config without LAN access")
	region := flag.String("region", "", "Xiaomi cloud region for QR setup (default: ask, cn)")
	noBrowser := flag.Bool("no-browser", false, "print the local QR URL without opening a browser")
	jsonMode := flag.Bool("json", false, "print newline-delimited JSON readings")
	watch := flag.Bool("watch", false, "keep one process running and poll continuously")
	requestTimeout := flag.Duration("timeout", 0, "override the timeout for each LAN request attempt")
	interval := flag.Duration("interval", defaultTick, "poll interval when using --watch")
	count := flag.Int("count", 0, "stop after this many watch readings (0 runs until interrupted)")
	flag.Parse()
	if *setup {
		if err := setupCloudQR(*region, *noBrowser); err != nil {
			fmt.Fprintln(os.Stderr, localText("扫码配置失败：", "QR setup failed:"), err)
			return 1
		}
		return 0
	}
	if *validate {
		if _, err := loadConfig(configPath()); err != nil {
			fmt.Fprintln(os.Stderr, localText("配置缺失或无效，请运行 --setup-cloud-qr。", "Config missing or invalid; run --setup-cloud-qr."))
			return 1
		}
		return 0
	}

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
	configuredTimeout := time.Duration(cfg.Timeout) * time.Second
	if *requestTimeout < 0 || *requestTimeout > 60*time.Second {
		return startupFailure(*jsonMode, "invalid request timeout", "request timeout must be between 1ms and 60s")
	}
	if *requestTimeout > 0 {
		configuredTimeout = *requestTimeout
	}
	// Ensure credentials stay private, including configs copied from the Python setup.
	if info, err := os.Lstat(path); err != nil || info.Mode()&os.ModeSymlink != 0 {
		return startupFailure(*jsonMode, "cannot secure config permissions", "config file must be a regular file, not a symbolic link")
	}
	if err := os.Chmod(path, 0o600); err != nil {
		return startupFailure(*jsonMode, "cannot secure config permissions", "cannot secure config file permissions")
	}
	if err := os.Chmod(filepath.Dir(path), 0o700); err != nil {
		return startupFailure(*jsonMode, "cannot secure config permissions", "cannot secure config directory permissions")
	}

	client, err := miio.New(cfg.IP, cfg.Token, miio.WithTimeout(configuredTimeout), miio.WithRetries(1))
	if err != nil {
		return startupFailure(*jsonMode, "cannot create LAN client", "cannot create LAN client: "+err.Error())
	}
	defer client.Close()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	requestBudget := configuredTimeout * 3
	readCtx, cancel := context.WithTimeout(ctx, requestBudget)
	if err := client.Handshake(readCtx); err != nil {
		cancel()
		return startupFailure(*jsonMode, "LAN handshake failed; check IP, token, and LAN access", "LAN handshake failed; check IP, token, and LAN access: "+err.Error())
	}
	var ticker *time.Ticker
	if *watch {
		ticker = time.NewTicker(*interval)
		defer ticker.Stop()
	}

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
		readCtx, cancel = context.WithTimeout(ctx, requestBudget)
		power, readErr = readPower(readCtx, client)
		cancel()
		if readErr != nil {
			hadReadError = true
			// Refresh the device clock after transient packet loss or a long-running session.
			handshakeCtx, handshakeCancel := context.WithTimeout(ctx, configuredTimeout*2)
			_ = client.Handshake(handshakeCtx)
			handshakeCancel()
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
