// Store ordering helpers (list + order reconciliation).
package main

import "sort"

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
