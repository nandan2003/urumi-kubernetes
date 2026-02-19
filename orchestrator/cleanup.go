// Cleanup logic for uninstalling releases and deleting namespaces.
package main

import (
	"context"
	"fmt"
	"log"
	"time"

	"helm.sh/helm/v3/pkg/action"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func (p *provisioner) Delete(ctx context.Context, store *Store) error {
	// Best-effort cleanup; logs failures but continues.
	actionConfig, err := p.newActionConfig(store.Namespace)
	if err != nil {
		return fmt.Errorf("init helm: %w", err)
	}

	if err := p.ensureNamespaceAccess(ctx, store.Namespace); err != nil {
		log.Printf("namespace rbac ensure failed: %v", err)
	}

	uninstall := action.NewUninstall(actionConfig)
	uninstall.Timeout = p.cfg.ProvisionTimeout
	if _, err := uninstall.Run(p.releaseName(store.ID)); err != nil {
		log.Printf("helm uninstall failed: %v", err)
	}

	clientset, err := p.getClientset()
	if err != nil {
		return fmt.Errorf("kube client: %w", err)
	}

	// Force delete all pods in the namespace to prevent stuck Terminating pods
	if pods, err := clientset.CoreV1().Pods(store.Namespace).List(ctx, metav1.ListOptions{}); err == nil {
		grace := int64(0)
		deletePolicy := metav1.DeletePropagationBackground
		for _, pod := range pods.Items {
			log.Printf("Force deleting pod %s/%s", store.Namespace, pod.Name)
			if err := clientset.CoreV1().Pods(store.Namespace).Delete(ctx, pod.Name, metav1.DeleteOptions{
				GracePeriodSeconds: &grace,
				PropagationPolicy:  &deletePolicy,
			}); err != nil {
				log.Printf("pod force delete failed: %v", err)
			}
		}
	}

	if pvcs, err := clientset.CoreV1().PersistentVolumeClaims(store.Namespace).List(ctx, metav1.ListOptions{}); err == nil {
		for _, pvc := range pvcs.Items {
			pvc.Finalizers = nil
			if _, err := clientset.CoreV1().PersistentVolumeClaims(store.Namespace).Update(ctx, &pvc, metav1.UpdateOptions{}); err != nil {
				log.Printf("pvc finalizer update failed: %v", err)
			}
			if err := clientset.CoreV1().PersistentVolumeClaims(store.Namespace).Delete(ctx, pvc.Name, metav1.DeleteOptions{}); err != nil {
				log.Printf("pvc delete failed: %v", err)
			}
		}
	}

	if err := clientset.CoreV1().Namespaces().Delete(ctx, store.Namespace, metav1.DeleteOptions{}); err != nil {
		log.Printf("namespace delete failed: %v", err)
	}

	// Force-remove namespace finalizers if it's stuck terminating.
	if err := p.finalizeNamespace(ctx, store.Namespace); err != nil {
		log.Printf("namespace finalize failed: %v", err)
	}

	if pvs, err := clientset.CoreV1().PersistentVolumes().List(ctx, metav1.ListOptions{}); err == nil {
		for _, pv := range pvs.Items {
			if pv.Spec.ClaimRef == nil || pv.Spec.ClaimRef.Namespace != store.Namespace {
				continue
			}
			pv.Finalizers = nil
			if _, err := clientset.CoreV1().PersistentVolumes().Update(ctx, &pv, metav1.UpdateOptions{}); err != nil {
				log.Printf("pv finalizer update failed: %v", err)
			}
			if err := clientset.CoreV1().PersistentVolumes().Delete(ctx, pv.Name, metav1.DeleteOptions{}); err != nil {
				log.Printf("pv delete failed: %v", err)
			}
		}
	}

	return nil
}

func (p *provisioner) cleanupRelease(ctx context.Context, store *Store) {
	actionConfig, err := p.newActionConfig(store.Namespace)
	if err != nil {
		log.Printf("cleanup release init failed: %v", err)
		return
	}

	uninstall := action.NewUninstall(actionConfig)
	uninstall.Timeout = 2 * time.Minute
	if _, err := uninstall.Run(p.releaseName(store.ID)); err != nil {
		log.Printf("cleanup release failed: %v", err)
	}
}

func (p *provisioner) finalizeNamespace(ctx context.Context, namespace string) error {
	clientset, err := p.getClientset()
	if err != nil {
		return err
	}
	ns, err := clientset.CoreV1().Namespaces().Get(ctx, namespace, metav1.GetOptions{})
	if err != nil {
		if apierrors.IsNotFound(err) {
			return nil
		}
		return err
	}
	
	// Remove finalizers from Spec
	if len(ns.Spec.Finalizers) > 0 {
		ns.Spec.Finalizers = []corev1.FinalizerName{}
		if _, err := clientset.CoreV1().Namespaces().Update(ctx, ns, metav1.UpdateOptions{}); err != nil {
			log.Printf("namespace spec update failed: %v", err)
		}
	}

	// Remove finalizers from Status/ObjectMeta (if any)
	if len(ns.Finalizers) > 0 {
		ns.Finalizers = []string{}
		// This uses the finalize subresource
		if _, err := clientset.CoreV1().Namespaces().Finalize(ctx, ns, metav1.UpdateOptions{}); err != nil {
			log.Printf("namespace finalize failed: %v", err)
		}
	}
	return nil
}
