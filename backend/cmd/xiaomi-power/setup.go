// SPDX-License-Identifier: GPL-3.0-only
package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	_ "image/jpeg"
	_ "image/png"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode"
)

func localText(zh, en string) string {
	locale := os.Getenv("LC_ALL")
	if locale == "" {
		locale = os.Getenv("LC_CTYPE")
	}
	if locale == "" {
		locale = os.Getenv("LANG")
	}
	locale = strings.ToUpper(locale)
	if locale != "" && !strings.Contains(locale, "UTF-8") && !strings.Contains(locale, "UTF8") {
		return en
	}
	return zh
}
func setupMessage(zh, en string) { fmt.Println(localText(zh, en)) }

// The only HTTP listener is loopback, with an unguessable path and no writes.
// No cloud session credentials or device tokens are sent to the browser.
func serveQR(ctx context.Context, picture []byte) (string, func(), error) {
	cfg, format, err := image.DecodeConfig(bytes.NewReader(picture))
	if err != nil || cfg.Width < 1 || cfg.Height < 1 || cfg.Width > 2048 || cfg.Height > 2048 {
		return "", nil, errors.New("invalid QR image")
	}
	media := "image/png"
	if format == "jpeg" {
		media = "image/jpeg"
	} else if format != "png" {
		return "", nil, errors.New("unsupported QR image")
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return "", nil, errors.New("cannot open local QR page")
	}
	secret := make([]byte, 24)
	if _, err = rand.Read(secret); err != nil {
		listener.Close()
		return "", nil, err
	}
	path := "/" + hex.EncodeToString(secret)
	host := listener.Addr().String()
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Content-Security-Policy", "default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'")
		if r.Host != host || r.Method != "GET" || (r.URL.Path != path && r.URL.Path != path+"/qr") {
			http.NotFound(w, r)
			return
		}
		if r.URL.Path == path+"/qr" {
			w.Header().Set("Content-Type", media)
			_, _ = w.Write(picture)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		fmt.Fprintf(w, `<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Mi Power Monitor</title><body style="font-family:system-ui;text-align:center"><h1>%s</h1><p>%s</p><img width="320" height="320" alt="QR code" src="%s/qr"><p>%s</p></body></html>`, localText("米家扫码登录", "Mi Home QR sign-in"), localText("请使用手机米家 App 扫码并确认登录。", "Scan with Mi Home on your phone and approve sign-in."), path, localText("完成后返回终端选择插座。页面到期后请重新运行安装命令。", "Return to the terminal to select a plug. Rerun setup if this page expires."))
	})
	server := &http.Server{Handler: mux, ReadHeaderTimeout: 3 * time.Second, ReadTimeout: 5 * time.Second, WriteTimeout: 5 * time.Second, IdleTimeout: 5 * time.Second, MaxHeaderBytes: 8192}
	done := make(chan struct{})
	go func() { defer close(done); _ = server.Serve(listener) }()
	go func() {
		select {
		case <-ctx.Done():
			_ = server.Close()
		case <-done:
		}
	}()
	return "http://" + host + path, func() { _ = server.Close() }, nil
}

func openQRBrowser(ctx context.Context, address string) {
	// Shell-free invocation; no inherited output, no token-bearing cloud URL.
	browserCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	command := exec.CommandContext(browserCtx, "xdg-open", address)
	command.Stdout = io.Discard
	command.Stderr = io.Discard
	_ = command.Run()
}

func saveSetupConfig(path string, cfg config) error {
	dir := filepath.Dir(path)
	if info, err := os.Lstat(dir); err == nil && info.Mode()&os.ModeSymlink != 0 {
		return errors.New("config directory must not be a symbolic link")
	}
	if err := os.MkdirAll(dir, 0700); err != nil {
		return errors.New("cannot create config directory")
	}
	if err := os.Chmod(dir, 0700); err != nil {
		return errors.New("cannot secure config directory")
	}
	if info, err := os.Lstat(path); err == nil && (!info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0) {
		return errors.New("config destination must be a regular file")
	}
	file, err := os.CreateTemp(dir, ".config-*")
	if err != nil {
		return errors.New("cannot create config temporary file")
	}
	temporary := file.Name()
	defer os.Remove(temporary)
	defer file.Close()
	if err = file.Chmod(0600); err != nil {
		return err
	}
	if err = json.NewEncoder(file).Encode(cfg); err != nil {
		return errors.New("cannot encode config")
	}
	// Share the exact validator used by normal LAN reads.
	if _, err = loadConfig(temporary); err != nil {
		return errors.New("invalid selected device configuration")
	}
	if err = file.Sync(); err != nil {
		return errors.New("cannot sync config")
	}
	if err = file.Close(); err != nil {
		return errors.New("cannot close config")
	}
	if err = os.Rename(temporary, path); err != nil {
		return errors.New("cannot atomically replace config")
	}
	directory, err := os.Open(dir)
	if err != nil {
		return errors.New("config saved but directory sync failed")
	}
	defer directory.Close()
	if err = directory.Sync(); err != nil {
		return errors.New("config saved but directory sync failed")
	}
	return nil
}

var cloudRegions = []string{"cn", "de", "us", "ru", "tw", "sg", "in", "i2"}

func validRegion(value string) bool {
	if value == "all" {
		return true
	}
	for _, r := range cloudRegions {
		if r == value {
			return true
		}
	}
	return false
}
func terminalName(raw string) string {
	var result []rune
	for _, r := range raw {
		if unicode.IsPrint(r) && !unicode.IsControl(r) {
			result = append(result, r)
		}
		if len(result) >= 80 {
			break
		}
	}
	return string(result)
}
func setupInput(ctx context.Context, scanner *bufio.Scanner) (string, error) {
	done := make(chan bool, 1)
	go func() { done <- scanner.Scan() }()
	var scanned bool
	select {
	case <-ctx.Done():
		return "", errors.New("setup cancelled or timed out")
	case scanned = <-done:
	}
	if !scanned {
		return "", errors.New("input closed; run setup in an interactive terminal")
	}
	return strings.TrimSpace(scanner.Text()), nil
}
func selectPlug(ctx context.Context, scanner *bufio.Scanner, devices []cloudDevice) (config, error) {
	var result config
	if len(devices) == 0 {
		return result, errors.New("no cuco.plug.v3 found; check the selected Xiaomi region and account")
	}
	// Region is part of the key; show ambiguous multi-region results explicitly.
	seen := map[string]bool{}
	unique := []cloudDevice{}
	for _, d := range devices {
		key := d.Region + ":" + d.ID
		if d.ID == "" {
			key = d.Region + ":" + d.IP
		}
		if !seen[key] {
			seen[key] = true
			unique = append(unique, d)
		}
	}
	setupMessage("请选择插座（不会显示 token）：", "Select a plug (tokens are never displayed):")
	for i, d := range unique {
		fmt.Printf("%d. %s  %s  [%s]\n", i+1, terminalName(d.Name), terminalName(d.IP), d.Region)
	}
	chosen := 0
	if len(unique) > 1 {
		for {
			fmt.Print(localText("输入序号：", "Number: "))
			text, err := setupInput(ctx, scanner)
			if err != nil {
				return result, err
			}
			index, err := strconv.Atoi(text)
			if err == nil && index > 0 && index <= len(unique) {
				chosen = index - 1
				break
			}
			setupMessage("请输入列表中的有效序号。", "Enter a valid number from the list.")
		}
	}
	d := unique[chosen]
	ip := strings.TrimSpace(d.IP)
	if net.ParseIP(ip) == nil {
		fmt.Print(localText("云端没有有效 IP，请输入此插座的局域网 IP：", "No valid cloud IP; enter the plug's LAN IP: "))
		var err error
		ip, err = setupInput(ctx, scanner)
		if err != nil {
			return result, err
		}
	}
	token, err := hex.DecodeString(d.Token)
	if err != nil || len(token) != 16 {
		return result, errors.New("selected plug has no valid LAN token; check device ownership")
	}
	if net.ParseIP(ip) == nil {
		return result, errors.New("invalid plug IP")
	}
	return config{Model: model, IP: ip, Token: d.Token, Timeout: 5}, nil
}

func setupCloudQR(region string, noBrowser bool) error {
	if os.Geteuid() == 0 {
		return errors.New("run QR setup as the desktop user, not root")
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	ctx, cancel := context.WithTimeout(ctx, 10*time.Minute)
	defer cancel()
	scanner := bufio.NewScanner(os.Stdin)
	if region == "" {
		fmt.Print(localText("小米服务器 cn/de/us/ru/tw/sg/in/i2/all [cn]：", "Xiaomi region cn/de/us/ru/tw/sg/in/i2/all [cn]: "))
		var err error
		region, err = setupInput(ctx, scanner)
		if err != nil {
			return err
		}
		if region == "" {
			region = "cn"
		}
	}
	if !validRegion(region) {
		return errors.New("unsupported Xiaomi region")
	}
	client, err := newCloudClient()
	if err != nil {
		return errors.New("cannot initialize cloud login")
	}
	setupMessage("正在向小米申请二维码（无需下载登录工具）……", "Requesting a QR code from Xiaomi (no login tool download)...")
	challenge, picture, err := client.challenge(ctx)
	if err != nil {
		return fmt.Errorf("%s: %w", localText("申请二维码失败，请检查小米网络连接", "QR request failed; check Xiaomi connectivity"), err)
	}
	address, closePage, err := serveQR(ctx, picture)
	if err != nil {
		return err
	}
	defer closePage()
	setupMessage("请在本机浏览器打开下方网址，用手机米家 App 扫码并确认。", "Open this local URL, then scan and approve with Mi Home on your phone.")
	fmt.Println(address)
	if !noBrowser {
		go openQRBrowser(ctx, address)
	}
	if err = client.awaitLogin(ctx, challenge); err != nil {
		return fmt.Errorf("%s: %w", localText("扫码登录失败或已过期，请重试", "QR login failed or expired; please retry"), err)
	}
	closePage()
	setupMessage("登录成功，正在读取插座列表……", "Signed in; loading plugs...")
	regions := []string{region}
	if region == "all" {
		regions = cloudRegions
	}
	devices := []cloudDevice{}
	for _, r := range regions {
		fmt.Printf("%s %s\n", localText("检查服务器：", "Checking region:"), r)
		list, err := client.devices(ctx, r)
		if err != nil {
			if region == "all" {
				fmt.Fprintf(os.Stderr, "%s %s: %v\n", localText("跳过暂不可用的服务器", "Skipping unavailable region"), r, err)
				continue
			}
			return fmt.Errorf("%s %s: %w", localText("读取设备失败，服务器", "Device-list request failed for"), r, err)
		}
		devices = append(devices, list...)
	}
	cfg, err := selectPlug(ctx, scanner, devices)
	if err != nil {
		return err
	}
	if err = saveSetupConfig(configPath(), cfg); err != nil {
		return err
	}
	setupMessage("插座配置已安全保存；token 仅保存在本机，不会显示。", "Plug configuration saved privately; the token is stored locally and never displayed.")
	return nil
}
