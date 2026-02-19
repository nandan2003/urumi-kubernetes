// Orchestrator HTTP API and background reconciler for store lifecycle.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func main() {
	cfg := loadConfig()
	storeManager := newStoreManager(cfg.StoreFile)
	if err := storeManager.Load(); err != nil {
		log.Fatalf("failed to load store data: %v", err)
	}

	provisioner := newProvisioner(cfg)
	orchestrator := newOrchestrator(storeManager, provisioner, cfg)
	orchestrator.startBackgroundSync()

	router := gin.New()
	router.Use(gin.Logger(), gin.Recovery(), corsMiddleware())
	router.Use(orchestrator.rateLimitMiddleware())

	router.GET("/healthz", orchestrator.handleHealth)
	router.GET("/api/stores", orchestrator.handleListStores)
	router.GET("/api/metrics", orchestrator.handleMetrics)
	router.POST("/api/stores", orchestrator.handleCreateStore)
	router.GET("/api/stores/:id", orchestrator.handleGetStore)
	router.DELETE("/api/stores/:id", orchestrator.handleDeleteStore)
	router.GET("/api/activity", orchestrator.handleActivity)

	log.Printf("orchestrator listening on %s", cfg.ListenAddr)
	if err := router.Run(cfg.ListenAddr); err != nil {
		log.Fatalf("server failed: %v", err)
	}
}

type config struct {
	ListenAddr            string
	ChartPath             string
	BaseValuesFile        string
	BaseDomain            string
	IngressClass          string
	StorageClass          string
	AdminUser             string
	AdminEmail            string
	AdminPassword         string
	StoreFile             string
	ProvisionTimeout      time.Duration
	MaxConcurrentJobs     int
	MaxStoresTotal        int
	MaxStoresPerIP        int
	RateLimitMax          int
	RateLimitWindow       time.Duration
	AuditLogFile          string
	ActivityLogFile       string
	MaxProvisionRetries   int
	ProvisionRetryBackoff time.Duration
	AutoInstallPlugins     bool
	Plugins                string
	PluginsFile            string
}

func loadConfig() config {
	cwd, _ := os.Getwd()
	defaultStoreFile := filepath.Join(cwd, "data", "stores.json")
	cfg := config{
		ListenAddr:            getEnv("ORCH_ADDR", ":8080"),
		ChartPath:             getEnv("CHART_PATH", filepath.Join(cwd, "..", "charts", "ecommerce-store")),
		BaseValuesFile:        getEnv("VALUES_FILE", filepath.Join(cwd, "..", "charts", "ecommerce-store", "values-local.yaml")),
		BaseDomain:            getEnv("STORE_BASE_DOMAIN", "127.0.0.1.nip.io"),
		IngressClass:          getEnv("INGRESS_CLASS", "nginx"),
		StorageClass:          getEnv("STORAGE_CLASS", ""),
		AdminUser:             getEnv("WP_ADMIN_USER", "admin"),
		AdminEmail:            getEnv("WP_ADMIN_EMAIL", "admin@example.com"),
		AdminPassword:         getEnv("WP_ADMIN_PASSWORD", ""),
		StoreFile:             getEnv("STORE_FILE", defaultStoreFile),
		ProvisionTimeout:      getEnvDuration("PROVISION_TIMEOUT", 8*time.Minute),
		MaxConcurrentJobs:     getEnvInt("MAX_CONCURRENT_PROVISIONS", 2),
		MaxStoresTotal:        getEnvInt("MAX_STORES_TOTAL", 20),
		MaxStoresPerIP:        getEnvInt("MAX_STORES_PER_IP", 5),
		RateLimitMax:          getEnvInt("RATE_LIMIT_MAX", 15),
		RateLimitWindow:       getEnvDuration("RATE_LIMIT_WINDOW", time.Minute),
		AuditLogFile:          getEnv("AUDIT_LOG_FILE", filepath.Join(cwd, "data", "audit.log")),
		ActivityLogFile:       getEnv("ACTIVITY_LOG_FILE", filepath.Join(cwd, "data", "activity.log")),
		MaxProvisionRetries:   getEnvInt("MAX_PROVISION_RETRIES", 1),
		ProvisionRetryBackoff: getEnvDuration("PROVISION_RETRY_BACKOFF", 10*time.Second),
		AutoInstallPlugins:    getEnvBool("AUTO_INSTALL_PLUGINS", false),
		Plugins:               getEnv("PLUGINS", ""),
		PluginsFile:           getEnv("PLUGINS_FILE", ""),
	}
	return cfg
}

type orchestrator struct {
	stores      *storeManager
	provisioner *provisioner
	cfg         config
	sem         chan struct{}
	rateMu      sync.Mutex
	rateState   map[string]*rateBucket
}

func newOrchestrator(stores *storeManager, provisioner *provisioner, cfg config) *orchestrator {
	return &orchestrator{
		stores:      stores,
		provisioner: provisioner,
		cfg:         cfg,
		sem:         make(chan struct{}, cfg.MaxConcurrentJobs),
		rateState:   map[string]*rateBucket{},
	}
}

func (o *orchestrator) handleHealth(c *gin.Context) {
	c.JSON(200, gin.H{"status": "ok"})
}

func (o *orchestrator) handleListStores(c *gin.Context) {
	o.reconcileStores(c.Request.Context())
	c.JSON(200, o.stores.List())
}

func (o *orchestrator) handleGetStore(c *gin.Context) {
	id := strings.TrimSpace(c.Param("id"))
	if id == "" {
		c.JSON(404, gin.H{"error": "store not found"})
		return
	}
	store, ok := o.stores.Get(id)
	if !ok {
		c.JSON(404, gin.H{"error": "store not found"})
		return
	}
	c.JSON(200, store)
}

func (o *orchestrator) handleActivity(c *gin.Context) {
	lines := getEnvInt("ACTIVITY_LIMIT", 50)
	if lines <= 0 {
		lines = 50
	}
	events, err := readLastLines(o.cfg.ActivityLogFile, lines)
	if err != nil {
		c.JSON(200, gin.H{"events": []string{}})
		return
	}
	c.JSON(200, gin.H{"events": events})
}

func (o *orchestrator) handleMetrics(c *gin.Context) {
	stores := o.stores.List()
	total := len(stores)
	ready := 0
	provisioning := 0
	failed := 0
	var durations []float64

	for _, store := range stores {
		switch store.Status {
		case StatusReady:
			ready++
		case StatusFailed:
			failed++
		default:
			provisioning++
		}
		if !store.ProvisionedAt.IsZero() && !store.CreatedAt.IsZero() {
			seconds := store.ProvisionedAt.Sub(store.CreatedAt).Seconds()
			if seconds >= 0 {
				durations = append(durations, seconds)
			}
		}
	}

	avg := 0.0
	p95 := 0.0
	if len(durations) > 0 {
		sort.Float64s(durations)
		sum := 0.0
		for _, v := range durations {
			sum += v
		}
		avg = sum / float64(len(durations))
		idx := int(math.Ceil(0.95*float64(len(durations)))) - 1
		if idx < 0 {
			idx = 0
		}
		if idx >= len(durations) {
			idx = len(durations) - 1
		}
		p95 = durations[idx]
	}

	c.JSON(200, gin.H{
		"totalStores":        total,
		"readyStores":        ready,
		"provisioningStores": provisioning,
		"failedStores":       failed,
		"provisioningSeconds": gin.H{
			"avg": avg,
			"p95": p95,
		},
	})
}

type createStoreRequest struct {
	Name      string `json:"name"`
	Engine    string `json:"engine"`
	Subdomain string `json:"subdomain"`
}

func (o *orchestrator) handleCreateStore(c *gin.Context) {
	var req createStoreRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(400, gin.H{"error": "invalid request body"})
		o.auditEvent("create_store", "", "rejected", err.Error(), c)
		return
	}

	engine := strings.TrimSpace(strings.ToLower(req.Engine))
	if engine == "" {
		engine = "woocommerce"
	}
	if engine != "woocommerce" && engine != "medusa" {
		c.JSON(400, gin.H{"error": "engine must be woocommerce or medusa"})
		o.auditEvent("create_store", "", "rejected", "invalid engine", c)
		return
	}

	name := strings.TrimSpace(req.Name)
	if name == "" {
		c.JSON(400, gin.H{"error": "name is required"})
		o.auditEvent("create_store", "", "rejected", "missing name", c)
		return
	}

	slug := slugify(name)
	if slug == "" {
		c.JSON(400, gin.H{"error": "name must contain alphanumeric characters"})
		o.auditEvent("create_store", "", "rejected", "invalid name", c)
		return
	}
	id := o.stores.EnsureUniqueID(slug)

	subdomain := slugify(req.Subdomain)
	if subdomain == "" {
		subdomain = id
	}

	clientIP := c.ClientIP()
	if !o.checkQuota(clientIP) {
		c.JSON(429, gin.H{"error": "store quota exceeded"})
		o.auditEvent("create_store", id, "rejected", "quota exceeded", c)
		return
	}

	adminPassword := ""
	if engine == "woocommerce" {
		adminPassword = o.cfg.AdminPassword
		if adminPassword == "" {
			adminPassword = randomString(20)
		}
	}

	store := &Store{
		ID:        id,
		Name:      name,
		Engine:    engine,
		Namespace: "store-" + id,
		Status:    StatusProvisioning,
		URLs:      []string{fmt.Sprintf("http://%s.%s", subdomain, o.cfg.BaseDomain)},
		CreatedAt: time.Now().UTC(),
		UpdatedAt: time.Now().UTC(),
		CreatedBy: clientIP,
	}

	if err := o.stores.Add(store); err != nil {
		c.JSON(409, gin.H{"error": err.Error()})
		o.auditEvent("create_store", id, "rejected", err.Error(), c)
		return
	}

	go o.provisionAsync(store, subdomain, adminPassword)
	resp := gin.H{"store": store}
	if adminPassword != "" {
		resp["adminPassword"] = adminPassword
		resp["passwordSource"] = "k8s-secret"
	}
	c.JSON(202, resp)
	o.auditEvent("create_store", id, "accepted", "", c)
	o.activityEvent("created", store, "")
}

func (o *orchestrator) handleDeleteStore(c *gin.Context) {
	id := strings.TrimSpace(c.Param("id"))
	if id == "" {
		c.JSON(404, gin.H{"error": "store not found"})
		o.auditEvent("delete_store", "", "rejected", "missing id", c)
		return
	}
	store, ok := o.stores.Get(id)
	if !ok {
		c.JSON(404, gin.H{"error": "store not found"})
		o.auditEvent("delete_store", id, "rejected", "not found", c)
		return
	}
	if store.Status == StatusDeleting {
		c.JSON(202, store)
		o.auditEvent("delete_store", id, "accepted", "already deleting", c)
		return
	}

	store.Status = StatusDeleting
	store.UpdatedAt = time.Now().UTC()
	o.stores.Update(store)

	go o.deleteAsync(store)
	c.JSON(202, store)
	o.auditEvent("delete_store", id, "accepted", "", c)
}

func (o *orchestrator) provisionAsync(store *Store, subdomain, adminPassword string) {
	o.sem <- struct{}{}
	defer func() { <-o.sem }()

	ctx, cancel := context.WithTimeout(context.Background(), o.cfg.ProvisionTimeout)
	defer cancel()

	maxAttempts := o.cfg.MaxProvisionRetries + 1
	if maxAttempts < 1 {
		maxAttempts = 1
	}

	for attempt := 1; attempt <= maxAttempts; attempt++ {
		store.ProvisionAttempts = attempt
		if err := o.waitForKubeUntil(ctx); err != nil {
			store.Status = StatusFailed
			store.Error = fmt.Sprintf("kubernetes API not ready: %v", err)
			store.UpdatedAt = time.Now().UTC()
			o.stores.Update(store)
			o.activityEvent("provision_failed", store, store.Error)
			return
		}

		err := o.provisioner.Provision(ctx, store, subdomain, adminPassword)
		if err == nil {
			store.Status = StatusReady
			store.Error = ""
			store.WasReady = true
			if store.ProvisionedAt.IsZero() {
				store.ProvisionedAt = time.Now().UTC()
			}
			store.UpdatedAt = time.Now().UTC()
			o.stores.Update(store)
			o.activityEvent("provision_ready", store, "")
			return
		}

		if attempt < maxAttempts && ctx.Err() == nil {
			store.Status = StatusProvisioning
			store.Error = fmt.Sprintf("retrying (%d/%d): %v", attempt, maxAttempts, err)
			store.UpdatedAt = time.Now().UTC()
			o.stores.Update(store)
			o.activityEvent("provision_retry", store, store.Error)
			o.provisioner.cleanupRelease(ctx, store)
			time.Sleep(o.cfg.ProvisionRetryBackoff)
			continue
		}

		store.Status = StatusFailed
		store.Error = err.Error()
		store.UpdatedAt = time.Now().UTC()
		o.stores.Update(store)
		o.activityEvent("provision_failed", store, store.Error)
		return
	}
}

func (o *orchestrator) startBackgroundSync() {
	go func() {
		for {
			if err := o.waitForKube(); err == nil {
				break
			}
			time.Sleep(2 * time.Second)
		}

		ticker := time.NewTicker(30 * time.Second)
		defer ticker.Stop()

		for {
			ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
			_ = o.syncWithCluster(ctx)
			_ = o.cleanupZombieNamespaces(ctx)
			cancel()
			<-ticker.C
		}
	}()
}

func (o *orchestrator) waitForKube() error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	clientset, err := o.provisioner.getClientset()
	if err != nil {
		return err
	}
	_, err = clientset.CoreV1().Namespaces().List(ctx, metav1.ListOptions{})
	return err
}

func (o *orchestrator) waitForKubeUntil(ctx context.Context) error {
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()

	for {
		if err := o.waitForKube(); err == nil {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
		}
	}
}

func (o *orchestrator) syncWithCluster(ctx context.Context) error {
	clientset, err := o.provisioner.getClientset()
	if err != nil {
		return err
	}
	nsList, err := clientset.CoreV1().Namespaces().List(ctx, metav1.ListOptions{})
	if err != nil {
		return err
	}

	clusterNamespaces := map[string]struct{}{}
	for _, ns := range nsList.Items {
		if !strings.HasPrefix(ns.Name, "store-") {
			continue
		}
		if ns.DeletionTimestamp != nil {
			continue
		}
		clusterNamespaces[ns.Name] = struct{}{}
		id := strings.TrimPrefix(ns.Name, "store-")
		if _, ok := o.stores.Get(id); ok {
			continue
		}
		now := time.Now().UTC()
		store := &Store{
			ID:        id,
			Name:      id,
			Engine:    "woocommerce",
			Namespace: ns.Name,
			Status:    StatusProvisioning,
			URLs:      []string{fmt.Sprintf("http://%s.%s", id, o.cfg.BaseDomain)},
			CreatedAt: now,
			UpdatedAt: now,
		}
		_ = o.stores.Add(store)
	}

	for _, store := range o.stores.List() {
		if _, ok := clusterNamespaces[store.Namespace]; !ok {
			o.stores.Remove(store.ID)
		}
	}
	return nil
}

func (o *orchestrator) cleanupZombieNamespaces(ctx context.Context) error {
	clientset, err := o.provisioner.getClientset()
	if err != nil {
		return err
	}
	nsList, err := clientset.CoreV1().Namespaces().List(ctx, metav1.ListOptions{})
	if err != nil {
		return err
	}
	now := time.Now()
	for _, ns := range nsList.Items {
		if !strings.HasPrefix(ns.Name, "store-") {
			continue
		}
		if ns.DeletionTimestamp == nil {
			continue
		}
		if now.Sub(ns.DeletionTimestamp.Time) < 2*time.Minute {
			continue
		}
		ns.Finalizers = []string{}
		ns.Spec.Finalizers = []corev1.FinalizerName{}
		_, _ = clientset.CoreV1().Namespaces().Finalize(ctx, &ns, metav1.UpdateOptions{})
	}
	return nil
}

func (o *orchestrator) reconcileStores(ctx context.Context) {
	for _, store := range o.stores.List() {
		if store.Status == StatusDeleting {
			continue
		}
		status, errMsg, err := o.provisioner.reconcileStore(ctx, store)
		if err != nil {
			continue
		}
		if status == StatusFailed && errMsg == "namespace not found" {
			o.stores.Remove(store.ID)
			continue
		}
		if store.Status == StatusFailed && status == StatusProvisioning {
			continue
		}
		if status == store.Status && errMsg == store.Error {
			continue
		}
		store.Status = status
		store.Error = errMsg
		if status == StatusReady {
			store.WasReady = true
			if store.ProvisionedAt.IsZero() {
				store.ProvisionedAt = time.Now().UTC()
			}
		}
		store.UpdatedAt = time.Now().UTC()
		o.stores.Update(store)
	}
}

func (o *orchestrator) deleteAsync(store *Store) {
	ctx, cancel := context.WithTimeout(context.Background(), o.cfg.ProvisionTimeout)
	defer cancel()

	if err := o.provisioner.Delete(ctx, store); err != nil {
		store.Status = StatusFailed
		store.Error = err.Error()
		store.UpdatedAt = time.Now().UTC()
		o.stores.Update(store)
		o.auditEvent("delete_store", store.ID, "failed", err.Error(), nil)
		o.activityEvent("delete_failed", store, err.Error())
		return
	}

	o.stores.Remove(store.ID)
	o.auditEvent("delete_store", store.ID, "deleted", "", nil)
	o.activityEvent("deleted", store, "")
}

func corsMiddleware() gin.HandlerFunc {
	return func(c *gin.Context) {
		headers := c.Writer.Header()
		headers.Set("Access-Control-Allow-Origin", "*")
		headers.Set("Access-Control-Allow-Methods", "GET,POST,DELETE,OPTIONS")
		headers.Set("Access-Control-Allow-Headers", "Content-Type")
		if c.Request.Method == "OPTIONS" {
			c.AbortWithStatus(204)
			return
		}
		c.Next()
	}
}

type rateBucket struct {
	count   int
	resetAt time.Time
}

func (o *orchestrator) rateLimitMiddleware() gin.HandlerFunc {
	return func(c *gin.Context) {
		if o.cfg.RateLimitMax <= 0 || o.cfg.RateLimitWindow <= 0 {
			c.Next()
			return
		}
		if c.Request.Method != "POST" && c.Request.Method != "DELETE" {
			c.Next()
			return
		}
		if !strings.HasPrefix(c.Request.URL.Path, "/api/stores") {
			c.Next()
			return
		}
		ip := c.ClientIP()
		if ip == "" {
			ip = "unknown"
		}
		now := time.Now()
		o.rateMu.Lock()
		bucket, ok := o.rateState[ip]
		if !ok || now.After(bucket.resetAt) {
			bucket = &rateBucket{
				count:   0,
				resetAt: now.Add(o.cfg.RateLimitWindow),
			}
			o.rateState[ip] = bucket
		}
		if bucket.count >= o.cfg.RateLimitMax {
			o.rateMu.Unlock()
			c.JSON(429, gin.H{"error": "rate limit exceeded"})
			o.auditEvent("rate_limit", "", "rejected", "rate limit exceeded", c)
			return
		}
		bucket.count++
		o.rateMu.Unlock()
		c.Next()
	}
}

func (o *orchestrator) checkQuota(clientIP string) bool {
	stores := o.stores.List()
	total := 0
	perIP := 0
	for _, store := range stores {
		if store.Status == StatusDeleting {
			continue
		}
		total++
		if clientIP != "" && store.CreatedBy == clientIP {
			perIP++
		}
	}
	if o.cfg.MaxStoresTotal > 0 && total >= o.cfg.MaxStoresTotal {
		return false
	}
	if o.cfg.MaxStoresPerIP > 0 && perIP >= o.cfg.MaxStoresPerIP {
		return false
	}
	return true
}

func (o *orchestrator) auditEvent(action, storeID, status, detail string, c *gin.Context) {
	entry := map[string]string{
		"ts":     time.Now().UTC().Format(time.RFC3339),
		"action": action,
		"store":  storeID,
		"status": status,
	}
	if detail != "" {
		entry["detail"] = detail
	}
	if c != nil {
		entry["ip"] = c.ClientIP()
		entry["method"] = c.Request.Method
		entry["path"] = c.Request.URL.Path
		if ua := c.GetHeader("User-Agent"); ua != "" {
			entry["ua"] = ua
		}
	}
	data, err := json.Marshal(entry)
	if err != nil {
		log.Printf("audit log marshal failed: %v", err)
		return
	}
	if err := os.MkdirAll(filepath.Dir(o.cfg.AuditLogFile), 0o755); err != nil {
		log.Printf("audit log mkdir failed: %v", err)
		return
	}
	f, err := os.OpenFile(o.cfg.AuditLogFile, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		log.Printf("audit log open failed: %v", err)
		return
	}
	defer f.Close()
	if _, err := f.Write(append(data, '\n')); err != nil {
		log.Printf("audit log write failed: %v", err)
	}
}

func (o *orchestrator) activityEvent(event string, store *Store, detail string) {
	if store == nil {
		return
	}
	entry := map[string]string{
		"ts":     time.Now().UTC().Format(time.RFC3339),
		"event":  event,
		"store":  store.ID,
		"name":   store.Name,
		"status": store.Status,
	}
	if detail != "" {
		entry["detail"] = detail
	}
	data, err := json.Marshal(entry)
	if err != nil {
		log.Printf("activity log marshal failed: %v", err)
		return
	}
	if err := os.MkdirAll(filepath.Dir(o.cfg.ActivityLogFile), 0o755); err != nil {
		log.Printf("activity log mkdir failed: %v", err)
		return
	}
	f, err := os.OpenFile(o.cfg.ActivityLogFile, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		log.Printf("activity log open failed: %v", err)
		return
	}
	defer f.Close()
	if _, err := f.Write(append(data, '\n')); err != nil {
		log.Printf("activity log write failed: %v", err)
	}
}

func readLastLines(path string, limit int) ([]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	raw := strings.TrimSpace(string(data))
	if raw == "" {
		return []string{}, nil
	}
	lines := strings.Split(raw, "\n")
	if len(lines) > limit {
		lines = lines[len(lines)-limit:]
	}
	return lines, nil
}
