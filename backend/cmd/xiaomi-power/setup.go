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
	"sync"
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

// The browser receives lifecycle labels only, never cloud session data.
type qrPageState struct {
	mu        sync.RWMutex
	stage     string
	delivered chan struct{}
	once      sync.Once
}

func newQRPageState() *qrPageState {
	return &qrPageState{stage: "waiting", delivered: make(chan struct{})}
}
func (s *qrPageState) set(stage string) { s.mu.Lock(); s.stage = stage; s.mu.Unlock() }
func (s *qrPageState) snapshot() map[string]any {
	s.mu.RLock()
	stage := s.stage
	s.mu.RUnlock()
	title, detail := localText("米家扫码登录", "Mi Home QR sign-in"), localText("请用手机米家 App 扫码并确认。", "Scan and approve with Mi Home on your phone.")
	switch stage {
	case "authenticated":
		title = localText("登录成功", "Signed in successfully")
		detail = localText("正在读取插座列表。请按 Alt+Tab 返回安装终端，继续选择插座。", "Loading plugs. Press Alt+Tab to return to the installation terminal and select your plug.")
	case "done":
		title = localText("配置完成", "Configuration complete")
		detail = localText("插座 token 已安全保存到本机。请按 Alt+Tab 返回终端查看后续安装结果，可以关闭此页面。", "The plug token was saved privately. Press Alt+Tab to return to the terminal for the remaining installation steps. You may close this page.")
	case "failed":
		title = localText("登录未完成", "Sign-in not completed")
		detail = localText("二维码可能已过期，或登录已取消。请返回终端查看原因并重试。", "The QR code may have expired or sign-in was cancelled. Return to the terminal for details and retry.")
	case "config-failed":
		title = localText("已登录，配置未完成", "Signed in; configuration incomplete")
		detail = localText("账号登录已成功，但设备读取或保存未完成。请返回终端查看原因。", "Account sign-in succeeded, but device discovery or saving did not finish. Return to the terminal for details.")
	}
	return map[string]any{"stage": stage, "title": title, "detail": detail, "final": stage == "done" || stage == "failed" || stage == "config-failed"}
}
func (s *qrPageState) waitForDisplay(ctx context.Context) {
	// Bound shutdown even if the browser was closed or never opened.
	timer := time.NewTimer(2 * time.Second)
	defer timer.Stop()
	select {
	case <-s.delivered:
	case <-timer.C:
	case <-ctx.Done():
	}
}

// The only HTTP listener is loopback, with an unguessable path and no writes.
// No cloud session credentials or device tokens are sent to the browser.
func serveQR(ctx context.Context, picture []byte, states ...*qrPageState) (string, func(), error) {
	state := newQRPageState()
	if len(states) > 0 {
		state = states[0]
	}
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
		w.Header().Set("Content-Security-Policy", "default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; script-src 'nonce-"+hex.EncodeToString(secret)+"'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'")
		if r.Host != host || r.Method != "GET" || (r.URL.Path != path && r.URL.Path != path+"/qr" && r.URL.Path != path+"/status" && r.URL.Path != path+"/result") {
			http.NotFound(w, r)
			return
		}
		status := state.snapshot()
		if r.URL.Path == path+"/status" {
			w.Header().Set("Content-Type", "application/json")
			if err := json.NewEncoder(w).Encode(status); err == nil && status["final"] == true {
				if f, ok := w.(http.Flusher); ok {
					f.Flush()
				}
				state.once.Do(func() { close(state.delivered) })
			}
			return
		}
		if r.URL.Path == path+"/qr" {
			if status["stage"] != "waiting" {
				w.WriteHeader(http.StatusGone)
				return
			}
			w.Header().Set("Content-Type", media)
			_, _ = w.Write(picture)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		fmt.Fprintf(w, `<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Mi Power Monitor</title><body style="font-family:system-ui;text-align:center;color-scheme:light dark;padding:2rem"><div id="mark" hidden style="font-size:3rem" aria-hidden="true">✓</div><h1 id="title">%s</h1><p id="detail" role="status" aria-live="polite">%s</p><img id="qr" width="320" height="320" style="max-width:80vw;height:auto" alt="QR code" src="%s/qr"><noscript>%s</noscript><script nonce="%s">
const base=%q;
async function update(){
 try {
  const response=await fetch(base+'/status',{cache:'no-store'});
  if(!response.ok) throw new Error('unavailable');
  const s=await response.json();
  document.getElementById('title').textContent=s.title;
  document.getElementById('detail').textContent=s.detail;
  document.title=s.title+' — Mi Power Monitor';
  document.getElementById('qr').hidden=s.stage!=='waiting';
  document.getElementById('mark').hidden=!['authenticated','done'].includes(s.stage);
  if(s.stage!=='waiting') history.replaceState(null,'',base+'/result');
  if(!s.final) setTimeout(update,400);
 } catch(e) {
  document.getElementById('qr').hidden=true;
  document.getElementById('detail').textContent=%q;
 }
}
update();
</script></body></html>`, localText("米家扫码登录", "Mi Home QR sign-in"), localText("请用手机米家 App 扫码并确认。", "Scan and approve with Mi Home on your phone."), path, localText("请启用 JavaScript 查看登录结果，或返回终端查看进度。", "Enable JavaScript for sign-in status, or return to the terminal."), hex.EncodeToString(secret), path, localText("本机登录页面已结束，请返回终端确认结果；这不代表登录失败。", "The local sign-in page has ended. Return to the terminal to confirm the result; this does not mean sign-in failed."))
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

func setupCloudQR(region string, noBrowser bool) (resultErr error) {
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
	pageState := newQRPageState()
	authenticated := false
	address, closePage, err := serveQR(ctx, picture, pageState)
	if err != nil {
		return err
	}
	defer func() {
		if resultErr != nil {
			if authenticated {
				pageState.set("config-failed")
			} else {
				pageState.set("failed")
			}
		}
		pageState.waitForDisplay(ctx)
		closePage()
	}()
	setupMessage("请在本机浏览器打开下方网址，用手机米家 App 扫码并确认。", "Open this local URL, then scan and approve with Mi Home on your phone.")
	fmt.Println(address)
	if !noBrowser {
		go openQRBrowser(ctx, address)
	}
	if err = client.awaitLogin(ctx, challenge); err != nil {
		return fmt.Errorf("%s: %w", localText("扫码登录失败或已过期，请重试", "QR login failed or expired; please retry"), err)
	}
	authenticated = true
	pageState.set("authenticated")
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
	pageState.set("done")
	setupMessage("插座配置已安全保存；token 仅保存在本机，不会显示。", "Plug configuration saved privately; the token is stored locally and never displayed.")
	return nil
}
