package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"image"
	"image/png"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func testQR(t *testing.T) []byte {
	t.Helper()
	var b bytes.Buffer
	if err := png.Encode(&b, image.NewGray(image.Rect(0, 0, 32, 32))); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}

func TestCloudCryptoIndependentVector(t *testing.T) {
	// Generated independently with Python hashlib and PyCryptodome ARC4, drop=1024.
	nonce := []byte{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11}
	form, _, err := cloudForm("/app/v2/homeroom/gethome", base64.StdEncoding.EncodeToString([]byte("0123456789abcdef")), []byte(`{"limit":300}`), nonce)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]string{"data": "5bC6qyaikiAgehVXqQ==", "rc4_hash__": "xqPijzqKt05RHhAkgYda+oiw/pyWEhaGM4mphQ==", "signature": "cjqYjoDOywEV1GgeB+FPzIfxvH4="}
	for k, v := range want {
		if form.Get(k) != v {
			t.Fatalf("incorrect %s", k)
		}
	}
}

func TestCloudURLsRejectUntrustedDestinations(t *testing.T) {
	for _, raw := range []string{"http://account.xiaomi.com/pass", "https://xiaomi.com.evil.test/", "https://account.xiaomi.com@evil.test/", "https://127.0.0.1/", "https://account.xiaomi.com:123/"} {
		if trustedCloudURL(raw) {
			t.Fatalf("accepted %s", raw)
		}
	}
	if !trustedCloudURL("https://account.xiaomi.com/pass") {
		t.Fatal("rejected cloud URL")
	}
}
func TestQRPageIsPrivateAndCloses(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	address, closePage, err := serveQR(ctx, testQR(t))
	if err != nil {
		t.Fatal(err)
	}
	defer closePage()
	response, err := http.Get(address)
	if err != nil {
		t.Fatal(err)
	}
	data, _ := io.ReadAll(response.Body)
	response.Body.Close()
	if response.StatusCode != 200 || response.Header.Get("Cache-Control") != "no-store" || !bytes.Contains(data, []byte("/qr")) {
		t.Fatal("invalid QR page")
	}
	for _, suffix := range []string{"/wrong", "/qr/extra"} {
		r, e := http.Get(address + suffix)
		if e != nil {
			t.Fatal(e)
		}
		r.Body.Close()
		if r.StatusCode != 404 {
			t.Fatal("unguarded path")
		}
	}
	req, _ := http.NewRequest("GET", address, nil)
	req.Host = "evil.test"
	response, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != 404 {
		t.Fatal("accepted foreign host")
	}
	closePage()
	if r, e := http.Get(address); e == nil {
		r.Body.Close()
		t.Fatal("QR server still running")
	}
}
func TestSaveSetupConfigProtectsExistingData(t *testing.T) {
	path := filepath.Join(t.TempDir(), "private", "config.json")
	original := config{Model: model, IP: "192.0.2.1", Token: strings.Repeat("a", 32), Timeout: 5}
	if err := saveSetupConfig(path, original); err != nil {
		t.Fatal(err)
	}
	bad := original
	bad.Token = "invalid"
	if err := saveSetupConfig(path, bad); err == nil {
		t.Fatal("invalid config saved")
	}
	actual, err := loadConfig(path)
	if err != nil || actual != original {
		t.Fatal("old config damaged")
	}
	for name, mode := range map[string]os.FileMode{path: 0600, filepath.Dir(path): 0700} {
		info, err := os.Stat(name)
		if err != nil || info.Mode().Perm() != mode {
			t.Fatal("unsafe config permissions")
		}
	}
	link := filepath.Join(t.TempDir(), "config.json")
	if err = os.Symlink(path, link); err != nil {
		t.Fatal(err)
	}
	if err = saveSetupConfig(link, original); err == nil {
		t.Fatal("followed config symlink")
	}
	entries, _ := os.ReadDir(filepath.Dir(path))
	if len(entries) != 1 {
		t.Fatal("temporary config leaked")
	}
}
func TestSelectMultiplePlugsWithoutLeakingToken(t *testing.T) {
	token := strings.Repeat("b", 32)
	reader, writer, _ := os.Pipe()
	original := os.Stdout
	os.Stdout = writer
	defer func() { os.Stdout = original }()
	cfg, err := selectPlug(context.Background(), bufio.NewScanner(strings.NewReader("9\n2\n192.0.2.2\n")), []cloudDevice{{ID: "1", Region: "cn", Name: "first", IP: "192.0.2.1", Token: strings.Repeat("a", 32)}, {ID: "2", Region: "cn", Name: "second", Token: token}})
	writer.Close()
	os.Stdout = original
	output, _ := io.ReadAll(reader)
	reader.Close()
	if err != nil || cfg.IP != "192.0.2.2" || cfg.Token != token {
		t.Fatal("wrong plug selected", err)
	}
	if bytes.Contains(output, []byte(token)) {
		t.Fatal("token leaked to terminal")
	}
}

type cloudTransport func(*http.Request) (*http.Response, error)

func (f cloudTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func cloudResponse(req *http.Request, data []byte) *http.Response {
	return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(bytes.NewReader(data)), Request: req}
}
func TestMockCloudLoginAndDeviceDiscovery(t *testing.T) {
	c, err := newCloudClient()
	if err != nil {
		t.Fatal(err)
	}
	security := base64.StdEncoding.EncodeToString([]byte("0123456789abcdef"))
	token := strings.Repeat("c", 32)
	apiCount := 0
	c.http.Transport = cloudTransport(func(req *http.Request) (*http.Response, error) {
		switch req.URL.Path {
		case "/longPolling/loginUrl":
			return cloudResponse(req, []byte(`{"qr":"https://account.xiaomi.com/image","lp":"https://account.xiaomi.com/poll","timeout":60}`)), nil
		case "/image":
			return cloudResponse(req, testQR(t)), nil
		case "/poll":
			return cloudResponse(req, []byte(`&&&START&&&{"userId":123,"ssecurity":"`+security+`","location":"https://sts.api.io.mi.com/sts"}`)), nil
		case "/sts":
			response := cloudResponse(req, []byte("ok"))
			response.Header.Add("Set-Cookie", "serviceToken=test-session; Path=/; Secure")
			return response, nil
		}
		apiCount++
		if req.Method != "POST" || req.Header.Get("MIOT-ENCRYPT-ALGORITHM") != "ENCRYPT-RC4" {
			t.Fatal("wrong cloud API headers")
		}
		cookie, e := req.Cookie("serviceToken")
		if e != nil || cookie.Value != "test-session" {
			t.Fatal("missing cloud session cookie")
		}
		nonce, e := base64.StdEncoding.DecodeString(req.URL.Query().Get("_nonce"))
		if e != nil {
			t.Fatal(e)
		}
		_, key, e := cloudForm(req.URL.Path, security, []byte("{}"), nonce)
		if e != nil {
			t.Fatal(e)
		}
		data, e := base64.StdEncoding.DecodeString(req.URL.Query().Get("data"))
		if e != nil {
			t.Fatal(e)
		}
		plain, e := cloudRC4(key, data)
		if e != nil || !json.Valid(plain) {
			t.Fatal("bad device-list payload")
		}
		result := ""
		switch req.URL.Path {
		case "/app/v2/homeroom/gethome":
			result = `{"homelist":[{"id":1}]}`
		case "/app/v2/user/get_device_cnt":
			result = `{"share":{"share_family":[]}}`
		case "/app/v2/home/home_device_list":
			result = `{"device_info":[{"did":"d1","model":"cuco.plug.v3","localip":"192.0.2.10","token":"` + token + `"},{"model":"other.model"}]}`
		default:
			t.Fatalf("unexpected API %s", req.URL.Path)
		}
		encrypted, e := cloudRC4(key, []byte(`{"code":0,"result":`+result+`}`))
		if e != nil {
			t.Fatal(e)
		}
		return cloudResponse(req, []byte(base64.StdEncoding.EncodeToString(encrypted))), nil
	})
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	q, picture, err := c.challenge(ctx)
	if err != nil || len(picture) == 0 {
		t.Fatal("QR challenge failed", err)
	}
	if err = c.awaitLogin(ctx, q); err != nil {
		t.Fatal(err)
	}
	devices, err := c.devices(ctx, "cn")
	if err != nil || len(devices) != 1 || devices[0].Token != token || apiCount != 3 {
		t.Fatal("device discovery failed", err)
	}
}
func TestCloudCancellationAndNoCredentialErrors(t *testing.T) {
	c, _ := newCloudClient()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := c.awaitLogin(ctx, qrChallenge{Timeout: 60, Poll: "https://account.xiaomi.com/poll?ticket=private-secret"}); err == nil || strings.Contains(err.Error(), "private-secret") {
		t.Fatal("bad cancellation error")
	}
}

func TestQRPageTransitionsAndFinalDelivery(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	state := newQRPageState()
	address, closePage, err := serveQR(ctx, testQR(t), state)
	if err != nil {
		t.Fatal(err)
	}
	defer closePage()
	for _, stage := range []string{"waiting", "authenticated", "config-failed", "done"} {
		state.set(stage)
		response, err := http.Get(address + "/status")
		if err != nil {
			t.Fatal(err)
		}
		var result map[string]any
		err = json.NewDecoder(response.Body).Decode(&result)
		response.Body.Close()
		if err != nil || result["stage"] != stage {
			t.Fatal("wrong browser stage", err)
		}
		if len(result) != 4 {
			t.Fatal("unexpected browser data; status must contain labels only")
		}
		if result["final"] != (stage == "done" || stage == "config-failed") {
			t.Fatal("incorrect completion state")
		}
	}
	start := time.Now()
	state.waitForDisplay(ctx)
	if time.Since(start) > time.Second {
		t.Fatal("final status was delivered but shutdown still waited")
	}
	response, err := http.Get(address + "/qr")
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusGone {
		t.Fatal("old QR still served after login")
	}
	response, err = http.Get(address + "/result")
	if err != nil {
		t.Fatal(err)
	}
	data, _ := io.ReadAll(response.Body)
	response.Body.Close()
	if response.StatusCode != 200 || !bytes.Contains(data, []byte("history.replaceState")) || !strings.Contains(response.Header.Get("Content-Security-Policy"), "script-src 'nonce-") {
		t.Fatal("missing result navigation or script CSP")
	}
}

func TestQRPageWaitStopsOnCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	state := newQRPageState()
	start := time.Now()
	state.waitForDisplay(ctx)
	if time.Since(start) > time.Second {
		t.Fatal("cancelled setup delayed exit")
	}
}
