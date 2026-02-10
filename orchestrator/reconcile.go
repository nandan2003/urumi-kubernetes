// Reconcile logic for reporting store readiness.
package main

import (
	"context"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func (p *provisioner) reconcileStore(ctx context.Context, store *Store) (string, string, error) {
	_ = p.ensureNamespaceAccess(ctx, store.Namespace)
	clientset, err := p.getClientset()
	if err != nil {
		return StatusProvisioning, "", err
	}

	ns, err := clientset.CoreV1().Namespaces().Get(ctx, store.Namespace, metav1.GetOptions{})
	if err != nil {
		if apierrors.IsNotFound(err) {
			return StatusFailed, "namespace not found", nil
		}
		return StatusProvisioning, "", err
	}
	if ns.Status.Phase == corev1.NamespaceTerminating {
		return StatusFailed, "namespace terminating", nil
	}

	fullname := p.releaseFullname(store.ID)
	if store.Engine == "medusa" {
		medusaDeploy := fullname + "-medusa"
		deploy, err := clientset.AppsV1().Deployments(store.Namespace).Get(ctx, medusaDeploy, metav1.GetOptions{})
		if err != nil {
			if apierrors.IsNotFound(err) {
				return StatusProvisioning, "", nil
			}
			return StatusProvisioning, "", err
		}
		if deploy.Status.ReadyReplicas < 1 {
			return StatusProvisioning, "", nil
		}
		return StatusReady, "", nil
	}

	if store.Engine != "woocommerce" {
		return StatusProvisioning, "", nil
	}

	jobName := fullname + "-wpcli"
	deployName := fullname + "-wordpress"

	job, err := clientset.BatchV1().Jobs(store.Namespace).Get(ctx, jobName, metav1.GetOptions{})
	if err != nil && !apierrors.IsNotFound(err) {
		return StatusProvisioning, "", err
	}
	if err == nil {
		if job.Status.Failed > 0 && job.Status.Succeeded == 0 {
			return StatusFailed, "wpcli job failed", nil
		}
		if job.Status.Succeeded == 0 {
			return StatusProvisioning, "", nil
		}
	}

	deploy, err := clientset.AppsV1().Deployments(store.Namespace).Get(ctx, deployName, metav1.GetOptions{})
	if err != nil {
		if apierrors.IsNotFound(err) {
			return StatusProvisioning, "", nil
		}
		return StatusProvisioning, "", err
	}

	if deploy.Status.ReadyReplicas < 1 {
		return StatusProvisioning, "", nil
	}

	return StatusReady, "", nil
}
