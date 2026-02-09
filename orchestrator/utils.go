package main

import (
	"crypto/rand"
	"encoding/hex"
	"os"
	"strconv"
	"strings"
	"time"
)

func getEnv(key, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(key)); value != "" {
		return value
	}
	return fallback
}

func getEnvInt(key string, fallback int) int {
	if value := strings.TrimSpace(os.Getenv(key)); value != "" {
		if parsed, err := strconv.Atoi(value); err == nil {
			return parsed
		}
	}
	return fallback
}

func getEnvDuration(key string, fallback time.Duration) time.Duration {
	if value := strings.TrimSpace(os.Getenv(key)); value != "" {
		if parsed, err := time.ParseDuration(value); err == nil {
			return parsed
		}
	}
	return fallback
}

func slugify(input string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(input) {
		if r >= 'a' && r <= 'z' || r >= '0' && r <= '9' {
			b.WriteRune(r)
			continue
		}
		if r == '-' || r == '_' || r == ' ' {
			if b.Len() > 0 && b.String()[b.Len()-1] != '-' {
				b.WriteRune('-')
			}
		}
	}
	slug := strings.Trim(b.String(), "-")
	return slug
}

func randomString(length int) string {
	if length <= 0 {
		return ""
	}
	bytes := make([]byte, length)
	if _, err := rand.Read(bytes); err != nil {
		return hex.EncodeToString(bytes)[:length]
	}
	const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	for i := range bytes {
		bytes[i] = alphabet[int(bytes[i])%len(alphabet)]
	}
	return string(bytes)
}

func mergeMaps(dst, src map[string]interface{}) map[string]interface{} {
	if dst == nil {
		dst = map[string]interface{}{}
	}
	for key, value := range src {
		if existing, ok := dst[key]; ok {
			existingMap, okExisting := existing.(map[string]interface{})
			valueMap, okValue := value.(map[string]interface{})
			if okExisting && okValue {
				dst[key] = mergeMaps(existingMap, valueMap)
				continue
			}
		}
		dst[key] = value
	}
	return dst
}
