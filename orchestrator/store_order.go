// Store ordering helpers.
package main

import "sort"

func (sm *storeManager) List() []*Store {
	sm.mu.RLock()
	defer sm.mu.RUnlock()

	items := make([]*Store, 0, len(sm.stores))
	for _, store := range sm.stores {
		items = append(items, store)
	}
	sort.Slice(items, func(i, j int) bool {
		if !items[i].CreatedAt.Equal(items[j].CreatedAt) {
			return items[i].CreatedAt.Before(items[j].CreatedAt)
		}
		return items[i].ID < items[j].ID
	})
	return items
}
