package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
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

	router.GET("/healthz", orchestrator.handleHealth)
	router.GET("/api/stores", orchestrator.handleListStores)
	router.POST("/api/stores", orchestrator.handleCreateStore)
	router.GET("/api/stores/:id", orchestrator.handleGetStore)
	router.DELETE("/api/stores/:id", orchestrator.handleDeleteStore)

	log.Printf("orchestrator listening on %s", cfg.ListenAddr)
	if err := router.Run(cfg.ListenAddr); err != nil {
		log.Fatalf("server failed: %v", err)
	}
}

type config struct {
	ListenAddr        string
	ChartPath         string
	BaseValuesFile    string
	BaseDomain        string
	IngressClass      string
	StorageClass      string
	AdminUser         string
	AdminEmail        string
	AdminPassword     string
	StoreFile         string
	ProvisionTimeout  time.Duration
	MaxConcurrentJobs int
}

func loadConfig() config {
	cwd, _ := os.Getwd()
	defaultStoreFile := filepath.Join(cwd, "data", "stores.json")
	cfg := config{
		ListenAddr:        getEnv("ORCH_ADDR", ":8080"),
		ChartPath:         getEnv("CHART_PATH", filepath.Join(cwd, "..", "charts", "ecommerce-store")),
		BaseValuesFile:    getEnv("VALUES_FILE", filepath.Join(cwd, "..", "charts", "ecommerce-store", "values-local.yaml")),
		BaseDomain:        getEnv("STORE_BASE_DOMAIN", "127.0.0.1.nip.io"),
		IngressClass:      getEnv("INGRESS_CLASS", "nginx"),
		StorageClass:      getEnv("STORAGE_CLASS", ""),
		AdminUser:         getEnv("WP_ADMIN_USER", "admin"),
		AdminEmail:        getEnv("WP_ADMIN_EMAIL", "admin@example.com"),
		AdminPassword:     getEnv("WP_ADMIN_PASSWORD", "password"),
		StoreFile:         getEnv("STORE_FILE", defaultStoreFile),
		ProvisionTimeout:  getEnvDuration("PROVISION_TIMEOUT", 8*time.Minute),
		MaxConcurrentJobs: getEnvInt("MAX_CONCURRENT_PROVISIONS", 2),
	}
	return cfg
}

type orchestrator struct {
	stores      *storeManager
	provisioner *provisioner
	cfg         config
	sem         chan struct{}
}

func newOrchestrator(stores *storeManager, provisioner *provisioner, cfg config) *orchestrator {
	return &orchestrator{
		stores:      stores,
		provisioner: provisioner,
		cfg:         cfg,
		sem:         make(chan struct{}, cfg.MaxConcurrentJobs),
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

type createStoreRequest struct {
	Name      string `json:"name"`
	Engine    string `json:"engine"`
	Subdomain string `json:"subdomain"`
}

func (o *orchestrator) handleCreateStore(c *gin.Context) {
	var req createStoreRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(400, gin.H{"error": "invalid request body"})
		return
	}

	engine := strings.TrimSpace(strings.ToLower(req.Engine))
	if engine == "" {
		engine = "woocommerce"
	}
	if engine != "woocommerce" && engine != "medusa" {
		c.JSON(400, gin.H{"error": "engine must be woocommerce or medusa"})
		return
	}

	name := strings.TrimSpace(req.Name)
	if name == "" {
		c.JSON(400, gin.H{"error": "name is required"})
		return
	}

	slug := slugify(name)
	if slug == "" {
		c.JSON(400, gin.H{"error": "name must contain alphanumeric characters"})
		return
	}
	id := o.stores.EnsureUniqueID(slug)

	subdomain := slugify(req.Subdomain)
	if subdomain == "" {
		subdomain = id
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
	}

	if err := o.stores.Add(store); err != nil {
		c.JSON(409, gin.H{"error": err.Error()})
		return
	}

	go o.provisionAsync(store, subdomain)
	c.JSON(202, store)
}

func (o *orchestrator) handleDeleteStore(c *gin.Context) {
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
	if store.Status == StatusDeleting {
		c.JSON(202, store)
		return
	}

	store.Status = StatusDeleting
	store.UpdatedAt = time.Now().UTC()
	o.stores.Update(store)

	go o.deleteAsync(store)
	c.JSON(202, store)
}

func (o *orchestrator) provisionAsync(store *Store, subdomain string) {
	o.sem <- struct{}{}
	defer func() { <-o.sem }()

	ctx, cancel := context.WithTimeout(context.Background(), o.cfg.ProvisionTimeout)
	defer cancel()

	if err := o.waitForKubeUntil(ctx); err != nil {
		store.Status = StatusFailed
		store.Error = fmt.Sprintf("kubernetes API not ready: %v", err)
		store.UpdatedAt = time.Now().UTC()
		o.stores.Update(store)
		return
	}

	err := o.provisioner.Provision(ctx, store, subdomain)
	if err != nil {
		store.Status = StatusFailed
		store.Error = err.Error()
	} else {
		store.Status = StatusReady
		store.Error = ""
	}
	store.UpdatedAt = time.Now().UTC()
	o.stores.Update(store)
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
		if status == store.Status && errMsg == store.Error {
			continue
		}
		store.Status = status
		store.Error = errMsg
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
		return
	}

	o.stores.Remove(store.ID)
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
