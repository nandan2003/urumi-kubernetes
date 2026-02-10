package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	StatusProvisioning = "Provisioning"
	StatusReady        = "Ready"
	StatusFailed       = "Failed"
	StatusDeleting     = "Deleting"
)

type Store struct {
	ID                string    `json:"id"`
	Name              string    `json:"name"`
	Engine            string    `json:"engine"`
	Namespace         string    `json:"namespace"`
	Status            string    `json:"status"`
	URLs              []string  `json:"urls"`
	CreatedAt         time.Time `json:"createdAt"`
	UpdatedAt         time.Time `json:"updatedAt"`
	WasReady          bool      `json:"wasReady,omitempty"`
	ProvisionedAt     time.Time `json:"provisionedAt,omitempty"`
	CreatedBy         string    `json:"createdBy,omitempty"`
	ProvisionAttempts int       `json:"provisionAttempts,omitempty"`
	Error             string    `json:"error,omitempty"`
}

type storeManager struct {
	filePath string
	mu       sync.RWMutex
	stores   map[string]*Store
	order    []string
}

type storeFile struct {
	Stores map[string]*Store `json:"stores"`
	Order  []string          `json:"order"`
}

func newStoreManager(filePath string) *storeManager {
	return &storeManager{
		filePath: filePath,
		stores:   map[string]*Store{},
		order:    []string{},
	}
}

func (sm *storeManager) Load() error {
	sm.mu.Lock()
	defer sm.mu.Unlock()

	if err := os.MkdirAll(filepath.Dir(sm.filePath), 0o755); err != nil {
		return err
	}

	data, err := os.ReadFile(sm.filePath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}

	var sf storeFile
	if err := json.Unmarshal(data, &sf); err != nil {
		return err
	}
	if sf.Stores != nil {
		sm.stores = sf.Stores
	}
	if sf.Order != nil {
		sm.order = sf.Order
	}
	for _, store := range sm.stores {
		if store.Status == StatusReady && !store.WasReady {
			store.WasReady = true
		}
		if store.Status == StatusReady && store.ProvisionedAt.IsZero() && !store.UpdatedAt.IsZero() {
			store.ProvisionedAt = store.UpdatedAt
		}
	}
	if sm.reconcileOrderLocked() {
		_ = sm.Save()
	}
	return nil
}

func (sm *storeManager) Save() error {
	sf := storeFile{
		Stores: sm.stores,
		Order:  sm.order,
	}
	data, err := json.MarshalIndent(sf, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(sm.filePath, data, 0o644)
}

func (sm *storeManager) Add(store *Store) error {
	sm.mu.Lock()
	defer sm.mu.Unlock()

	if _, exists := sm.stores[store.ID]; exists {
		return errors.New("store already exists")
	}
	sm.stores[store.ID] = store
	sm.order = append(sm.order, store.ID)
	return sm.Save()
}

func (sm *storeManager) Update(store *Store) {
	sm.mu.Lock()
	defer sm.mu.Unlock()

	sm.stores[store.ID] = store
	_ = sm.Save()
}

func (sm *storeManager) Remove(id string) {
	sm.mu.Lock()
	defer sm.mu.Unlock()

	delete(sm.stores, id)
	filtered := sm.order[:0]
	for _, item := range sm.order {
		if item != id {
			filtered = append(filtered, item)
		}
	}
	sm.order = filtered
	_ = sm.Save()
}

func (sm *storeManager) Get(id string) (*Store, bool) {
	sm.mu.RLock()
	defer sm.mu.RUnlock()

	store, ok := sm.stores[id]
	return store, ok
}

func (sm *storeManager) List() []*Store {
	sm.mu.RLock()
	defer sm.mu.RUnlock()

	items := make([]*Store, 0, len(sm.stores))
	seen := make(map[string]bool, len(sm.stores))
	for _, id := range sm.order {
		if store, ok := sm.stores[id]; ok {
			items = append(items, store)
			seen[id] = true
		}
	}

	if len(items) < len(sm.stores) {
		missing := make([]string, 0, len(sm.stores))
		for id := range sm.stores {
			if !seen[id] {
				missing = append(missing, id)
			}
		}
		sort.Slice(missing, func(i, j int) bool {
			a := sm.stores[missing[i]]
			b := sm.stores[missing[j]]
			if a == nil || b == nil {
				return missing[i] < missing[j]
			}
			if !a.CreatedAt.IsZero() && !b.CreatedAt.IsZero() {
				return a.CreatedAt.Before(b.CreatedAt)
			}
			return missing[i] < missing[j]
		})
		for _, id := range missing {
			if store, ok := sm.stores[id]; ok {
				items = append(items, store)
			}
		}
	}

	if len(items) == 0 {
		for _, store := range sm.stores {
			items = append(items, store)
		}
		sort.Slice(items, func(i, j int) bool {
			return items[i].CreatedAt.Before(items[j].CreatedAt)
		})
	}
	return items
}

func (sm *storeManager) reconcileOrderLocked() bool {
	if len(sm.stores) == 0 {
		if len(sm.order) == 0 {
			return false
		}
		sm.order = []string{}
		return true
	}

	seen := make(map[string]bool, len(sm.stores))
	newOrder := make([]string, 0, len(sm.stores))
	for _, id := range sm.order {
		if _, ok := sm.stores[id]; !ok {
			continue
		}
		if seen[id] {
			continue
		}
		seen[id] = true
		newOrder = append(newOrder, id)
	}

	missing := make([]string, 0, len(sm.stores))
	for id := range sm.stores {
		if !seen[id] {
			missing = append(missing, id)
		}
	}
	sort.Slice(missing, func(i, j int) bool {
		a := sm.stores[missing[i]]
		b := sm.stores[missing[j]]
		if a == nil || b == nil {
			return missing[i] < missing[j]
		}
		if !a.CreatedAt.IsZero() && !b.CreatedAt.IsZero() {
			return a.CreatedAt.Before(b.CreatedAt)
		}
		return missing[i] < missing[j]
	})
	newOrder = append(newOrder, missing...)

	changed := len(newOrder) != len(sm.order)
	if !changed {
		for i := range newOrder {
			if sm.order[i] != newOrder[i] {
				changed = true
				break
			}
		}
	}
	if changed {
		sm.order = newOrder
	}
	return changed
}

func (sm *storeManager) EnsureUniqueID(base string) string {
	base = strings.ToLower(base)
	sm.mu.RLock()
	if _, ok := sm.stores[base]; !ok {
		sm.mu.RUnlock()
		return base
	}
	sm.mu.RUnlock()

	for {
		suffix := strings.ToLower(randomString(4))
		candidate := base + "-" + suffix
		sm.mu.RLock()
		_, exists := sm.stores[candidate]
		sm.mu.RUnlock()
		if !exists {
			return candidate
		}
	}
}
