package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"time"

	"helm.sh/helm/v3/pkg/action"
	"helm.sh/helm/v3/pkg/chart/loader"
	"helm.sh/helm/v3/pkg/chartutil"
	"helm.sh/helm/v3/pkg/cli"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
)

type provisioner struct {
	cfg config
}

func newProvisioner(cfg config) *provisioner {
	return &provisioner{cfg: cfg}
}

func (p *provisioner) Provision(ctx context.Context, store *Store, subdomain, adminPassword string) error {
	chartObj, err := loader.Load(p.cfg.ChartPath)
	if err != nil {
		return fmt.Errorf("load chart: %w", err)
	}

	baseVals := map[string]interface{}{}
	if p.cfg.BaseValuesFile != "" {
		if values, err := chartutil.ReadValuesFile(p.cfg.BaseValuesFile); err == nil {
			baseVals = values.AsMap()
		}
	}

	secrets := map[string]interface{}{
		"mysqlRootPassword": randomString(24),
		"mysqlPassword":     randomString(24),
		"wpAdminPassword":   adminPassword,
	}

	ingressClass := p.resolveIngressClass(ctx)
	ingressNamespace := p.resolveIngressNamespace(ingressClass)

	overrides := map[string]interface{}{
		"engine": store.Engine,
		"ingress": map[string]interface{}{
			"enabled":   true,
			"className": ingressClass,
			"hosts": []interface{}{
				map[string]interface{}{
					"host": fmt.Sprintf("%s.%s", subdomain, p.cfg.BaseDomain),
					"paths": []interface{}{
						map[string]interface{}{
							"path":     "/",
							"pathType": "Prefix",
						},
					},
				},
			},
		},
		"admin": map[string]interface{}{
			"username": p.cfg.AdminUser,
			"email":    p.cfg.AdminEmail,
		},
		"secrets": secrets,
	}
	if ingressNamespace != "" {
		overrides["networkPolicy"] = map[string]interface{}{
			"allowIngressFromNamespace": ingressNamespace,
		}
	}

	storageClass := p.cfg.StorageClass
	if storageClass == "" {
		if detected, err := p.detectDefaultStorageClass(ctx); err == nil && detected != "" {
			storageClass = detected
		}
	}

	if storageClass == "" {
		return fmt.Errorf("no default StorageClass found; set STORAGE_CLASS env var")
	}

	if storageClass != "" {
		overrides["wordpress"] = map[string]interface{}{
			"persistence": map[string]interface{}{
				"storageClass": storageClass,
			},
		}
		overrides["mysql"] = map[string]interface{}{
			"persistence": map[string]interface{}{
				"storageClass": storageClass,
			},
		}
	}

	vals := mergeMaps(baseVals, overrides)

	actionConfig, err := p.newActionConfig(store.Namespace)
	if err != nil {
		return fmt.Errorf("init helm: %w", err)
	}

	if err := p.ensureNamespaceReady(ctx, store.Namespace); err != nil {
		return err
	}

	install := action.NewInstall(actionConfig)
	install.ReleaseName = p.releaseName(store.ID)
	install.Namespace = store.Namespace
	install.CreateNamespace = true
	install.Wait = true
	install.WaitForJobs = true
	install.Timeout = 15 * time.Minute

	_, err = install.Run(chartObj, vals)
	if err != nil {
		return fmt.Errorf("helm install: %w", err)
	}
	return nil
}

func (p *provisioner) resolveIngressClass(ctx context.Context) string {
	clientset, err := p.getClientset()
	if err != nil {
		return p.cfg.IngressClass
	}
	list, err := clientset.NetworkingV1().IngressClasses().List(ctx, metav1.ListOptions{})
	if err != nil {
		return p.cfg.IngressClass
	}
	if len(list.Items) == 0 {
		return p.cfg.IngressClass
	}

	exists := map[string]struct{}{}
	defaultClass := ""
	for _, item := range list.Items {
		exists[item.Name] = struct{}{}
		if item.Annotations["ingressclass.kubernetes.io/is-default-class"] == "true" {
			defaultClass = item.Name
		}
	}

	if p.cfg.IngressClass != "" {
		if _, ok := exists[p.cfg.IngressClass]; ok {
			return p.cfg.IngressClass
		}
	}

	if defaultClass != "" {
		return defaultClass
	}

	for _, preferred := range []string{"nginx", "traefik"} {
		if _, ok := exists[preferred]; ok {
			return preferred
		}
	}

	return list.Items[0].Name
}

func (p *provisioner) resolveIngressNamespace(ingressClass string) string {
	switch ingressClass {
	case "traefik":
		return "kube-system"
	case "nginx":
		return "ingress-nginx"
	default:
		return ""
	}
}

func (p *provisioner) ensureNamespaceReady(ctx context.Context, namespace string) error {
	clientset, err := p.getClientset()
	if err != nil {
		return fmt.Errorf("kube client: %w", err)
	}
	ns, err := clientset.CoreV1().Namespaces().Get(ctx, namespace, metav1.GetOptions{})
	if err != nil {
		if apierrors.IsNotFound(err) {
			return nil
		}
		return fmt.Errorf("get namespace: %w", err)
	}

	if ns.Status.Phase != corev1.NamespaceTerminating {
		return nil
	}

	ns.Spec.Finalizers = []corev1.FinalizerName{}
	ns.ObjectMeta.Finalizers = []string{}
	_, _ = clientset.CoreV1().Namespaces().Finalize(ctx, ns, metav1.UpdateOptions{})
	_ = clientset.CoreV1().Namespaces().Delete(ctx, namespace, metav1.DeleteOptions{})

	deadline := time.Now().Add(2 * time.Minute)
	for time.Now().Before(deadline) {
		_, err = clientset.CoreV1().Namespaces().Get(ctx, namespace, metav1.GetOptions{})
		if apierrors.IsNotFound(err) {
			return nil
		}
		time.Sleep(2 * time.Second)
	}

	return fmt.Errorf("namespace %s is terminating; delete in progress", namespace)
}

func (p *provisioner) Delete(ctx context.Context, store *Store) error {
	actionConfig, err := p.newActionConfig(store.Namespace)
	if err != nil {
		return fmt.Errorf("init helm: %w", err)
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
	if len(ns.Finalizers) == 0 && len(ns.Spec.Finalizers) == 0 {
		return nil
	}
	ns.Finalizers = []string{}
	ns.Spec.Finalizers = []corev1.FinalizerName{}
	_, err = clientset.CoreV1().Namespaces().Finalize(ctx, ns, metav1.UpdateOptions{})
	return err
}

func (p *provisioner) newActionConfig(namespace string) (*action.Configuration, error) {
	settings := cli.New()
	settings.SetNamespace(namespace)
	actionConfig := new(action.Configuration)
	if err := actionConfig.Init(settings.RESTClientGetter(), namespace, os.Getenv("HELM_DRIVER"), log.Printf); err != nil {
		return nil, err
	}
	return actionConfig, nil
}

func (p *provisioner) releaseName(id string) string {
	return "urumi-" + id
}

func (p *provisioner) releaseFullname(id string) string {
	return p.releaseName(id) + "-ecommerce-store"
}

func (p *provisioner) detectDefaultStorageClass(ctx context.Context) (string, error) {
	clientset, err := p.getClientset()
	if err != nil {
		return "", err
	}
	list, err := clientset.StorageV1().StorageClasses().List(ctx, metav1.ListOptions{})
	if err != nil {
		return "", err
	}
	for _, sc := range list.Items {
		if sc.Annotations["storageclass.kubernetes.io/is-default-class"] == "true" ||
			sc.Annotations["storageclass.beta.kubernetes.io/is-default-class"] == "true" {
			return sc.Name, nil
		}
	}
	return "", nil
}

func (p *provisioner) getClientset() (*kubernetes.Clientset, error) {
	restConfig, err := cli.New().RESTClientGetter().ToRESTConfig()
	if err != nil {
		return nil, err
	}
	return kubernetes.NewForConfig(restConfig)
}

func (p *provisioner) reconcileStore(ctx context.Context, store *Store) (string, string, error) {
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
