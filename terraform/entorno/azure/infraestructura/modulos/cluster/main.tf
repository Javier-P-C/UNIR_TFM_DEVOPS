# Clúster AKS en una subred existente, con Azure CNI superpuesto, OIDC issuer y Workload Identity,
# sin claves SSH, y con permiso para descargar imágenes del ACR de la capa base.
#
# ignore_changes sobre tags["ejecucion"]: ver el módulo de red.

terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm" }
  }
}

resource "azurerm_kubernetes_cluster" "cluster" {
  name                = var.nombre
  resource_group_name = var.grupo_recursos
  location            = var.ubicacion
  dns_prefix          = var.nombre
  sku_tier            = var.nivel
  # Versión menor fija: sin ella AKS elige la predeterminada de la región, que cambia con el tiempo
  kubernetes_version = var.version_kubernetes

  default_node_pool {
    name                 = "nodepool1"
    node_count           = var.nodos.cantidad
    vm_size              = var.nodos.tamano
    vnet_subnet_id       = var.subred_id
    orchestrator_version = var.version_kubernetes
    # AKS etiqueta el conjunto de escalado de los nodos con las etiquetas del grupo, no con las del clúster
    tags = var.etiquetas

    upgrade_settings {
      max_surge = "10%"
    }
  }

  node_provisioning_profile {
    mode = "Manual"
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    pod_cidr            = var.red_kubernetes.pod_cidr
    service_cidr        = var.red_kubernetes.service_cidr
    dns_service_ip      = var.red_kubernetes.dns_service_ip
  }

  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  tags = var.etiquetas

  lifecycle {
    ignore_changes = [tags["ejecucion"], default_node_pool[0].tags["ejecucion"]]
  }
}

# Equivale a --attach-acr: la identidad del kubelet descarga imágenes sin secretos de registro.
resource "azurerm_role_assignment" "acr_pull" {
  scope                            = var.acr_id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_kubernetes_cluster.cluster.kubelet_identity[0].object_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

# La identidad del clúster gestiona recursos de red en la subred de los nodos. 
resource "azurerm_role_assignment" "red_cluster" {
  scope                            = var.subred_id
  role_definition_name             = "Network Contributor"
  principal_id                     = azurerm_kubernetes_cluster.cluster.identity[0].principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}
