// SPDX-License-Identifier: GPL-3.0-only
// Xiaomi cloud protocol adapted from Xiaomi-cloud-tokens-extractor (MIT).
// See THIRD_PARTY_NOTICES.md for attribution and license.
package main

import (
	"context"
	"crypto/rand"
	"crypto/rc4" // Required by Xiaomi's wire protocol; HTTPS protects transport.
	"crypto/sha1"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const cloudLimit = 8 << 20

type cloudClient struct {
	http         *http.Client
	userID       string
	security     string
	serviceToken string
	agent        string
}

func trustedCloudURL(raw string) bool {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.User != nil || (u.Port() != "" && u.Port() != "443") {
		return false
	}
	host := strings.ToLower(u.Hostname())
	return host == "xiaomi.com" || strings.HasSuffix(host, ".xiaomi.com") || host == "mi.com" || strings.HasSuffix(host, ".mi.com")
}

func newCloudClient() (*cloudClient, error) {
	jar, err := cookiejar.New(nil)
	if err != nil {
		return nil, err
	}
	random := make([]byte, 16)
	if _, err := rand.Read(random); err != nil {
		return nil, err
	}
	client := &http.Client{Jar: jar, Timeout: 20 * time.Second, CheckRedirect: func(req *http.Request, via []*http.Request) error {
		if len(via) >= 8 || !trustedCloudURL(req.URL.String()) {
			return errors.New("rejected cloud redirect")
		}
		return nil
	}}
	return &cloudClient{http: client, agent: hex.EncodeToString(random) + " APP/com.xiaomi.mihome APPV/10.5.201"}, nil
}

func (c *cloudClient) request(ctx context.Context, method, raw string, form url.Values, cookies bool) ([]byte, error) {
	if !trustedCloudURL(raw) {
		return nil, errors.New("untrusted cloud URL")
	}
	var body io.Reader
	if form != nil {
		body = strings.NewReader(form.Encode())
	}
	req, err := http.NewRequestWithContext(ctx, method, raw, body)
	if err != nil {
		return nil, errors.New("invalid cloud request")
	}
	req.Header.Set("User-Agent", c.agent)
	req.Header.Set("Accept-Encoding", "identity")
	if form != nil {
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	if cookies {
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		req.Header.Set("MIOT-ENCRYPT-ALGORITHM", "ENCRYPT-RC4")
		req.Header.Set("x-xiaomi-protocal-flag-cli", "PROTOCAL-HTTP2")
		for name, value := range map[string]string{"userId": c.userID, "serviceToken": c.serviceToken, "yetAnotherServiceToken": c.serviceToken, "locale": "en_GB", "timezone": "GMT+00:00", "is_daylight": "0", "dst_offset": "0", "channel": "MI_APP_STORE"} {
			req.AddCookie(&http.Cookie{Name: name, Value: value})
		}
	}
	response, err := c.http.Do(req)
	if err != nil {
		return nil, errors.New("cloud network request failed or timed out")
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("cloud HTTP status %d", response.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, cloudLimit+1))
	if err != nil || len(data) > cloudLimit {
		return nil, errors.New("invalid or oversized cloud response")
	}
	// serviceToken is issued during the STS redirect chain; never print it.
	for _, cookie := range response.Cookies() {
		if cookie.Name == "serviceToken" {
			c.serviceToken = cookie.Value
		}
	}
	for _, cookie := range c.http.Jar.Cookies(response.Request.URL) {
		if cookie.Name == "serviceToken" {
			c.serviceToken = cookie.Value
		}
	}
	return data, nil
}

func decodeCloud(data []byte, target any) error {
	data = []byte(strings.TrimPrefix(strings.TrimSpace(string(data)), "&&&START&&&"))
	if err := json.Unmarshal(data, target); err != nil {
		return errors.New("invalid cloud JSON response")
	}
	return nil
}

type qrChallenge struct {
	Image   string `json:"qr"`
	Poll    string `json:"lp"`
	Timeout int    `json:"timeout"`
}

func (c *cloudClient) challenge(ctx context.Context) (qrChallenge, []byte, error) {
	var q qrChallenge
	params := url.Values{"_qrsize": {"480"}, "qs": {"%3Fsid%3Dxiaomiio%26_json%3Dtrue"}, "callback": {"https://sts.api.io.mi.com/sts"}, "_hasLogo": {"false"}, "sid": {"xiaomiio"}, "serviceParam": {""}, "_locale": {"en_GB"}, "_dc": {strconv.FormatInt(time.Now().UnixMilli(), 10)}}
	data, err := c.request(ctx, "GET", "https://account.xiaomi.com/longPolling/loginUrl?"+params.Encode(), nil, false)
	if err != nil {
		return q, nil, err
	}
	if err = decodeCloud(data, &q); err != nil {
		return q, nil, err
	}
	if !trustedCloudURL(q.Image) || !trustedCloudURL(q.Poll) {
		return q, nil, errors.New("invalid QR challenge URLs")
	}
	image, err := c.request(ctx, "GET", q.Image, nil, false)
	if err != nil {
		return q, nil, err
	}
	return q, image, nil
}

func (c *cloudClient) awaitLogin(ctx context.Context, q qrChallenge) error {
	seconds := q.Timeout
	if seconds <= 0 || seconds > 300 {
		seconds = 180
	}
	ctx, cancel := context.WithTimeout(ctx, time.Duration(seconds)*time.Second)
	defer cancel()
	for ctx.Err() == nil {
		pollCtx, stop := context.WithTimeout(ctx, 15*time.Second)
		data, err := c.request(pollCtx, "GET", q.Poll, nil, false)
		stop()
		if err == nil {
			var result struct {
				UserID   json.RawMessage `json:"userId"`
				Security string          `json:"ssecurity"`
				Location string          `json:"location"`
			}
			if err = decodeCloud(data, &result); err != nil {
				return err
			}
			uid, err := cloudID(result.UserID)
			if err != nil || result.Security == "" || !trustedCloudURL(result.Location) {
				return errors.New("QR expired or login was not approved")
			}
			c.userID = uid
			c.security = result.Security
			if _, err = c.request(ctx, "GET", result.Location, nil, false); err != nil {
				return err
			}
			if c.serviceToken == "" {
				return errors.New("Xiaomi did not issue a service token")
			}
			return nil
		}
		select {
		case <-ctx.Done():
		case <-time.After(time.Second):
		}
	}
	return errors.New("QR login expired or was cancelled")
}

func cloudID(raw json.RawMessage) (string, error) {
	value := strings.Trim(string(raw), "\"")
	if value == "" {
		return "", errors.New("missing cloud ID")
	}
	for _, r := range value {
		if r < '0' || r > '9' {
			return "", errors.New("invalid cloud ID")
		}
	}
	return value, nil
}

type cloudField struct{ key, value string }

func cloudSignature(path, key string, fields []cloudField) string {
	parts := []string{"POST", strings.TrimPrefix(path, "/app")}
	for _, f := range fields {
		parts = append(parts, f.key+"="+f.value)
	}
	parts = append(parts, key)
	sum := sha1.Sum([]byte(strings.Join(parts, "&")))
	return base64.StdEncoding.EncodeToString(sum[:])
}
func cloudRC4(key, data []byte) ([]byte, error) {
	cipher, err := rc4.NewCipher(key)
	if err != nil {
		return nil, errors.New("invalid cloud cipher key")
	}
	discard := make([]byte, 1024)
	cipher.XORKeyStream(discard, discard)
	result := make([]byte, len(data))
	cipher.XORKeyStream(result, data)
	return result, nil
}
func cloudForm(path, security string, payload, nonce []byte) (url.Values, []byte, error) {
	secret, err := base64.StdEncoding.DecodeString(security)
	if err != nil || len(secret) == 0 {
		return nil, nil, errors.New("invalid cloud session key")
	}
	digest := sha256.Sum256(append(secret, nonce...))
	key := digest[:]
	encoded := base64.StdEncoding.EncodeToString(key)
	fields := []cloudField{{"data", string(payload)}}
	fields = append(fields, cloudField{"rc4_hash__", cloudSignature(path, encoded, fields)})
	form := url.Values{}
	for i, f := range fields {
		encrypted, err := cloudRC4(key, []byte(f.value))
		if err != nil {
			return nil, nil, err
		}
		fields[i].value = base64.StdEncoding.EncodeToString(encrypted)
		form.Set(f.key, fields[i].value)
	}
	form.Set("signature", cloudSignature(path, encoded, fields))
	form.Set("ssecurity", security)
	form.Set("_nonce", base64.StdEncoding.EncodeToString(nonce))
	return form, key, nil
}
func (c *cloudClient) api(ctx context.Context, region, path string, payload any, target any) error {
	data, err := json.Marshal(payload)
	if err != nil {
		return errors.New("invalid cloud payload")
	}
	nonce := make([]byte, 12)
	if _, err = rand.Read(nonce[:8]); err != nil {
		return err
	}
	binary.BigEndian.PutUint32(nonce[8:], uint32(time.Now().Unix()/60))
	form, key, err := cloudForm(path, c.security, data, nonce)
	if err != nil {
		return err
	}
	host := "api.io.mi.com"
	if region != "cn" {
		host = region + "." + host
	}
	// Xiaomi's reference client sends the encrypted fields in the query string.
	raw, err := c.request(ctx, "POST", "https://"+host+path+"?"+form.Encode(), nil, true)
	if err != nil {
		return err
	}
	encrypted, err := base64.StdEncoding.DecodeString(string(raw))
	if err != nil {
		return errors.New("invalid encrypted cloud response")
	}
	decoded, err := cloudRC4(key, encrypted)
	if err != nil {
		return err
	}
	var envelope struct {
		Code   int             `json:"code"`
		Result json.RawMessage `json:"result"`
	}
	if err = decodeCloud(decoded, &envelope); err != nil {
		return err
	}
	if envelope.Code != 0 || len(envelope.Result) == 0 || string(envelope.Result) == "null" {
		return errors.New("Xiaomi rejected device-list request")
	}
	if err = json.Unmarshal(envelope.Result, target); err != nil {
		return errors.New("invalid device-list response")
	}
	return nil
}

type cloudDevice struct {
	ID     string `json:"did"`
	Name   string `json:"name"`
	Model  string `json:"model"`
	IP     string `json:"localip"`
	Token  string `json:"token"`
	Region string `json:"-"`
}

func (c *cloudClient) devices(ctx context.Context, region string) ([]cloudDevice, error) {
	var homes struct {
		Homes []struct {
			ID json.RawMessage `json:"id"`
		} `json:"homelist"`
	}
	if err := c.api(ctx, region, "/app/v2/homeroom/gethome", map[string]any{"fg": true, "fetch_share": true, "fetch_share_dev": true, "limit": 300, "app_ver": 7}, &homes); err != nil {
		return nil, err
	}
	type home struct{ id, owner string }
	list := []home{}
	for _, h := range homes.Homes {
		id, err := cloudID(h.ID)
		if err != nil {
			return nil, err
		}
		list = append(list, home{id, c.userID})
	}
	var shared struct {
		Share struct {
			Families []struct {
				ID    json.RawMessage `json:"home_id"`
				Owner json.RawMessage `json:"home_owner"`
			} `json:"share_family"`
		} `json:"share"`
	}
	if err := c.api(ctx, region, "/app/v2/user/get_device_cnt", map[string]bool{"fetch_own": true, "fetch_share": true}, &shared); err != nil {
		return nil, err
	}
	for _, h := range shared.Share.Families {
		id, e1 := cloudID(h.ID)
		owner, e2 := cloudID(h.Owner)
		if e1 != nil || e2 != nil {
			return nil, errors.New("invalid shared home ID")
		}
		list = append(list, home{id, owner})
	}
	result := []cloudDevice{}
	seen := map[string]bool{}
	for _, h := range list {
		if seen[h.id+":"+h.owner] {
			continue
		}
		seen[h.id+":"+h.owner] = true
		var devices struct {
			Devices []cloudDevice `json:"device_info"`
			More    bool          `json:"has_more"`
			MaxID   string        `json:"max_did"`
		}
		if err := c.api(ctx, region, "/app/v2/home/home_device_list", map[string]any{"home_owner": json.Number(h.owner), "home_id": json.Number(h.id), "limit": 200, "get_split_device": true, "support_smart_home": true}, &devices); err != nil {
			return nil, err
		}
		// Do not silently pretend an explicitly truncated list is complete.
		if devices.More {
			return nil, errors.New("device list is paginated; use a smaller home or configure the plug manually")
		}
		for _, d := range devices.Devices {
			if d.Model == model {
				d.Region = region
				result = append(result, d)
			}
		}
	}
	return result, nil
}
