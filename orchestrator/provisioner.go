// Provisioner handles Helm install and shared Kubernetes helpers.
package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"strings"
	"time"

	"helm.sh/helm/v3/pkg/action"
	"helm.sh/helm/v3/pkg/chart/loader"
	"helm.sh/helm/v3/pkg/chartutil"
	"helm.sh/helm/v3/pkg/cli"
	corev1 "k8s.io/api/core/v1"
	rbacv1 "k8s.io/api/rbac/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
)

type provisioner struct {
	cfg config
}

const (
	orchestratorNamespaceRoleName = "urumi-orchestrator-ns"
	orchestratorRoleBindingName   = "urumi-orchestrator"
	orchestratorServiceAccount    = "orchestrator"
	orchestratorNamespace         = "urumi-system"
)

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

	if plugins := p.storePlugins(); len(plugins) > 0 {
		overrides["wpcli"] = map[string]interface{}{
			"autoInstallPlugins": true,
			"plugins":            strings.Join(plugins, ","),
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
	if err := p.ensureNamespaceExists(ctx, store.Namespace); err != nil {
		return fmt.Errorf("ensure namespace: %w", err)
	}
	if err := p.ensureNamespaceAccess(ctx, store.Namespace); err != nil {
		return fmt.Errorf("ensure namespace rbac: %w", err)
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

func (p *provisioner) storePlugins() []string {
	if !p.cfg.AutoInstallPlugins {
		return nil
	}
	plugins := []string{}
	if p.cfg.PluginsFile != "" {
		if data, err := os.ReadFile(p.cfg.PluginsFile); err == nil {
			lines := strings.Split(string(data), "\n")
			for _, line := range lines {
				entry := strings.TrimSpace(line)
				if entry == "" || strings.HasPrefix(entry, "#") {
					continue
				}
				if idx := strings.Index(entry, "#"); idx >= 0 {
					entry = strings.TrimSpace(entry[:idx])
				}
				if entry != "" {
					plugins = append(plugins, entry)
				}
			}
		}
	}
	if len(plugins) == 0 && p.cfg.Plugins != "" {
		for _, entry := range strings.Split(p.cfg.Plugins, ",") {
			item := strings.TrimSpace(entry)
			if item != "" {
				plugins = append(plugins, item)
			}
		}
	}
	return plugins
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

func (p *provisioner) ensureNamespaceExists(ctx context.Context, namespace string) error {
	clientset, err := p.getClientset()
	if err != nil {
		return err
	}
	_, err = clientset.CoreV1().Namespaces().Get(ctx, namespace, metav1.GetOptions{})
	if err == nil {
		return nil
	}
	if !apierrors.IsNotFound(err) {
		return err
	}
	_, err = clientset.CoreV1().Namespaces().Create(ctx, &corev1.Namespace{
		ObjectMeta: metav1.ObjectMeta{
			Name: namespace,
		},
	}, metav1.CreateOptions{})
	if apierrors.IsAlreadyExists(err) {
		return nil
	}
	return err
}

func (p *provisioner) ensureNamespaceAccess(ctx context.Context, namespace string) error {
	// Ensure the orchestrator has a RoleBinding in store namespaces.
	if !strings.HasPrefix(namespace, "store-") {
		return nil
	}
	clientset, err := p.getClientset()
	if err != nil {
		return err
	}
	if _, err := clientset.CoreV1().Namespaces().Get(ctx, namespace, metav1.GetOptions{}); err != nil {
		if apierrors.IsNotFound(err) {
			return nil
		}
		return err
	}

	desired := &rbacv1.RoleBinding{
		ObjectMeta: metav1.ObjectMeta{
			Name:      orchestratorRoleBindingName,
			Namespace: namespace,
		},
		RoleRef: rbacv1.RoleRef{
			APIGroup: "rbac.authorization.k8s.io",
			Kind:     "ClusterRole",
			Name:     orchestratorNamespaceRoleName,
		},
		Subjects: []rbacv1.Subject{
			{
				Kind:      "ServiceAccount",
				Name:      orchestratorServiceAccount,
				Namespace: orchestratorNamespace,
			},
		},
	}

	existing, err := clientset.RbacV1().RoleBindings(namespace).Get(ctx, orchestratorRoleBindingName, metav1.GetOptions{})
	if apierrors.IsNotFound(err) {
		_, err = clientset.RbacV1().RoleBindings(namespace).Create(ctx, desired, metav1.CreateOptions{})
		return err
	}
	if err != nil {
		return err
	}
	if roleBindingMatches(existing, desired) {
		return nil
	}
	existing.RoleRef = desired.RoleRef
	existing.Subjects = desired.Subjects
	_, err = clientset.RbacV1().RoleBindings(namespace).Update(ctx, existing, metav1.UpdateOptions{})
	return err
}

func roleBindingMatches(existing, desired *rbacv1.RoleBinding) bool {
	if existing.RoleRef.APIGroup != desired.RoleRef.APIGroup ||
		existing.RoleRef.Kind != desired.RoleRef.Kind ||
		existing.RoleRef.Name != desired.RoleRef.Name {
		return false
	}
	if len(existing.Subjects) != len(desired.Subjects) {
		return false
	}
	for i, subj := range desired.Subjects {
		if i >= len(existing.Subjects) {
			return false
		}
		if existing.Subjects[i] != subj {
			return false
		}
	}
	return true
}
