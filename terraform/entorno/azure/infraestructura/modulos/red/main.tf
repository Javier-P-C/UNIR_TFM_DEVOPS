# Red de un entorno: grupo de recursos, VNet, subred del clúster y subred delegada a PostgreSQL
# con un NSG que solo admite el puerto de la base desde la subred del clúster.
#
# ignore_changes sobre tags["ejecucion"]: la etiqueta registra la sesión que creó el recurso.
# Una sesión posterior trae otro valor, y sin esto el plan mostraría diferencias en todos los recursos
# y la detección de deriva dejaría de servir.

terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm" }
  }
}

resource "azurerm_resource_group" "entorno" {
  name     = var.grupo_recursos
  location = var.ubicacion
  tags     = var.etiquetas

  lifecycle { ignore_changes = [tags["ejecucion"]] }
}

resource "azurerm_virtual_network" "entorno" {
  name                = var.vnet_nombre
  resource_group_name = azurerm_resource_group.entorno.name
  location            = azurerm_resource_group.entorno.location
  address_space       = var.espacio_direcciones
  tags                = var.etiquetas

  lifecycle { ignore_changes = [tags["ejecucion"]] }
}

# Nodos del clúster. Con Azure CNI superpuesto los pods no toman IP de esta subred.
resource "azurerm_subnet" "cluster" {
  name                 = var.subred_cluster.nombre
  resource_group_name  = azurerm_resource_group.entorno.name
  virtual_network_name = azurerm_virtual_network.entorno.name
  address_prefixes     = [var.subred_cluster.prefijo]
}

resource "azurerm_subnet" "base_datos" {
  name                 = var.subred_base_datos.nombre
  resource_group_name  = azurerm_resource_group.entorno.name
  virtual_network_name = azurerm_virtual_network.entorno.name
  address_prefixes     = [var.subred_base_datos.prefijo]

  delegation {
    name = "postgresql"
    service_delegation {
      name = "Microsoft.DBforPostgreSQL/flexibleServers"
      # Azure añade esta acción al delegar; declararla evita diferencias en el plan
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# Las reglas por defecto de un NSG admiten todo el tráfico entrante desde la VNet (AllowVnetInBound, 65000).
# La regla de denegación, con más prioridad, la anula: solo queda el puerto de la base desde la subred del clúster.
resource "azurerm_network_security_group" "base_datos" {
  name                = "nsg-${var.subred_base_datos.nombre}"
  resource_group_name = azurerm_resource_group.entorno.name
  location            = azurerm_resource_group.entorno.location
  tags                = var.etiquetas

  security_rule {
    name                       = "permitir-postgresql-desde-cluster"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = var.subred_cluster.prefijo
    source_port_range          = "*"
    destination_address_prefix = var.subred_base_datos.prefijo
    destination_port_range     = tostring(var.puerto_base_datos)
  }

  security_rule {
    name                       = "denegar-resto-vnet"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_address_prefix      = "VirtualNetwork"
    source_port_range          = "*"
    destination_address_prefix = "*"
    destination_port_range     = "*"
  }

  lifecycle { ignore_changes = [tags["ejecucion"]] }
}

resource "azurerm_subnet_network_security_group_association" "base_datos" {
  subnet_id                 = azurerm_subnet.base_datos.id
  network_security_group_id = azurerm_network_security_group.base_datos.id
}
