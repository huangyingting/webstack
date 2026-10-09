data "azurerm_client_config" "current" {}

locals {
  vm_name = coalesce(var.vm_name, "${var.prefix}-vm")
  tags = {
    managed-by = "azure-webstack"
    deployment = var.prefix
  }
  storage_name = "bk${substr(replace(var.prefix, "-", ""), 0, 10)}${substr(sha256("${var.subscription_id}/${var.prefix}"), 0, 12)}"
  backup_config = {
    storage_account    = azurerm_storage_account.backups.name
    container          = azurerm_storage_container.backups.name
    identity_client_id = azurerm_user_assigned_identity.backup.client_id
    time_zone          = var.backup_time_zone
    acme_email         = var.acme_email
    data_disk_count    = var.data_disk_count
  }
  host_files = [
    { source = "backup.py", destination = "/usr/local/sbin/webstack-backup" },
    { source = "create-app.py", destination = "/usr/local/sbin/webstack-create-app" },
    { source = "deploy-app.sh", destination = "/usr/local/sbin/webstack-deploy" },
    { source = "bootstrap.sh", destination = "/etc/webstack/bootstrap.sh" },
  ]
}

resource "azurerm_resource_group" "apps" {
  name     = "${var.prefix}-rg"
  location = var.location
  tags     = local.tags
}

resource "azurerm_resource_group" "backups" {
  name     = "${var.prefix}-backup-rg"
  location = var.location
  tags     = local.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_storage_account" "backups" {
  name                            = local.storage_name
  resource_group_name             = azurerm_resource_group.backups.name
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  access_tier                     = "Hot"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false
  default_to_oauth_authentication = true
  public_network_access_enabled   = false
  tags                            = local.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_storage_container" "backups" {
  name                  = "pg-backups"
  storage_account_id    = azurerm_storage_account.backups.id
  container_access_type = "private"

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_storage_management_policy" "backups" {
  storage_account_id = azurerm_storage_account.backups.id

  dynamic "rule" {
    for_each = { daily = 7, weekly = 112 }
    content {
      name    = "expire-${rule.key}"
      enabled = true
      filters {
        prefix_match = ["${azurerm_storage_container.backups.name}/${rule.key}/"]
        blob_types   = ["blockBlob"]
      }
      actions {
        base_blob {
          delete_after_days_since_modification_greater_than = rule.value
        }
      }
    }
  }
}

resource "azurerm_user_assigned_identity" "backup" {
  name                = "${var.prefix}-backup"
  resource_group_name = azurerm_resource_group.apps.name
  location            = var.location
  tags                = local.tags
}

resource "azurerm_role_assignment" "backup" {
  scope                = azurerm_storage_container.backups.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.backup.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_virtual_network" "apps" {
  name                = "${var.prefix}-vnet"
  address_space       = ["10.42.0.0/16"]
  location            = var.location
  resource_group_name = azurerm_resource_group.apps.name
  tags                = local.tags
}

resource "azurerm_subnet" "apps" {
  name                              = "apps"
  resource_group_name               = azurerm_resource_group.apps.name
  virtual_network_name              = azurerm_virtual_network.apps.name
  address_prefixes                  = ["10.42.1.0/24"]
  private_endpoint_network_policies = "Disabled"
}

resource "azurerm_private_dns_zone" "blob" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.apps.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "blob" {
  name                  = "${var.prefix}-blob-dns-link"
  resource_group_name   = azurerm_resource_group.apps.name
  private_dns_zone_name = azurerm_private_dns_zone.blob.name
  virtual_network_id    = azurerm_virtual_network.apps.id
  registration_enabled  = false
  tags                  = local.tags
}

resource "azurerm_network_security_group" "apps" {
  name                = "${var.prefix}-nsg"
  location            = var.location
  resource_group_name = azurerm_resource_group.apps.name
  tags                = local.tags
}

resource "azurerm_network_security_rule" "web" {
  name                        = "web"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_ranges     = ["80", "443"]
  source_address_prefix       = "Internet"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.apps.name
  network_security_group_name = azurerm_network_security_group.apps.name
}

resource "azurerm_network_security_rule" "ssh" {
  name                        = "admin-ssh"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = var.admin_cidr
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.apps.name
  network_security_group_name = azurerm_network_security_group.apps.name
}

resource "azurerm_network_security_rule" "deny_other" {
  name                        = "deny-other-inbound"
  priority                    = 120
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.apps.name
  network_security_group_name = azurerm_network_security_group.apps.name
}

resource "azurerm_public_ip" "apps" {
  name                = "${var.prefix}-ip"
  resource_group_name = azurerm_resource_group.apps.name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags

  lifecycle {
    ignore_changes = [ip_tags, zones]
  }
}

resource "azurerm_network_interface" "apps" {
  name                = "${var.prefix}-nic"
  location            = var.location
  resource_group_name = azurerm_resource_group.apps.name
  tags                = local.tags
  ip_configuration {
    name                          = "apps"
    subnet_id                     = azurerm_subnet.apps.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.apps.id
  }
}

resource "azurerm_network_interface_security_group_association" "apps" {
  network_interface_id      = azurerm_network_interface.apps.id
  network_security_group_id = azurerm_network_security_group.apps.id
}

resource "azurerm_private_endpoint" "blob" {
  name                = "${var.prefix}-blob-private-endpoint"
  location            = var.location
  resource_group_name = azurerm_resource_group.apps.name
  subnet_id           = azurerm_subnet.apps.id
  tags                = local.tags

  private_service_connection {
    name                           = "${var.prefix}-blob-connection"
    private_connection_resource_id = azurerm_storage_account.backups.id
    is_manual_connection           = false
    subresource_names              = ["blob"]
  }

  private_dns_zone_group {
    name                 = "blob"
    private_dns_zone_ids = [azurerm_private_dns_zone.blob.id]
  }
}

resource "azurerm_managed_disk" "data" {
  count                = var.data_disk_count
  name                 = "${var.prefix}-data-${format("%02d", count.index + 1)}"
  location             = var.location
  resource_group_name  = azurerm_resource_group.apps.name
  storage_account_type = "StandardSSD_LRS"
  create_option        = "Empty"
  disk_size_gb         = var.data_disk_size_gb
  tags                 = local.tags

  lifecycle {
    prevent_destroy = true
  }
}

data "cloudinit_config" "apps" {
  gzip          = true
  base64_encode = true
  part {
    content_type = "text/cloud-config"
    content = "#cloud-config\n${yamlencode({
      write_files = concat(
        [{
          path        = "/etc/webstack/config.json"
          owner       = "root:root"
          permissions = "0600"
          content     = jsonencode(local.backup_config)
        }],
        [for entry in local.host_files : {
          path        = entry.destination
          owner       = "root:root"
          permissions = "0755"
          encoding    = "b64"
          content     = filebase64("${path.module}/${entry.source}")
        }]
      )
      runcmd = [["env", "WEBSTACK_CLOUD_INIT=1", "bash", "/etc/webstack/bootstrap.sh"]]
    })}"
  }
}

resource "azurerm_linux_virtual_machine" "apps" {
  name                            = local.vm_name
  resource_group_name             = azurerm_resource_group.apps.name
  location                        = var.location
  size                            = var.vm_size
  admin_username                  = var.admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.apps.id]
  custom_data                     = data.cloudinit_config.apps.rendered
  tags                            = local.tags

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key != null ? trimspace(var.ssh_public_key) : trimspace(file(pathexpand(var.ssh_public_key_path)))
  }
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.backup.id]
  }
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = var.disk_size_gb
  }
  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }
  boot_diagnostics {}
  depends_on = [
    azurerm_role_assignment.backup,
    azurerm_network_interface_security_group_association.apps,
    azurerm_network_security_rule.web,
    azurerm_network_security_rule.ssh,
    azurerm_network_security_rule.deny_other,
  ]

  lifecycle {
    prevent_destroy = true
    # Host configuration updates must never replace a VM containing PostgreSQL.
    ignore_changes = [custom_data, source_image_reference]
  }
}

resource "azurerm_virtual_machine_data_disk_attachment" "data" {
  count              = var.data_disk_count
  managed_disk_id    = azurerm_managed_disk.data[count.index].id
  virtual_machine_id = azurerm_linux_virtual_machine.apps.id
  lun                = count.index
  caching            = "None"
}

resource "azurerm_user_assigned_identity" "github" {
  for_each            = var.github_repositories
  name                = "${var.prefix}-gh-${substr(sha256(each.value), 0, 10)}"
  resource_group_name = azurerm_resource_group.apps.name
  location            = var.location
  tags                = local.tags
}

resource "azurerm_federated_identity_credential" "github" {
  for_each  = var.github_repositories
  name      = "github-production"
  parent_id = azurerm_user_assigned_identity.github[each.key].id
  audience  = ["api://AzureADTokenExchange"]
  issuer    = "https://token.actions.githubusercontent.com"
  subject   = "repo:${each.key}:environment:production"
}

resource "azurerm_role_definition" "github" {
  count       = length(var.github_repositories) > 0 ? 1 : 0
  name        = "${var.prefix} VM deployment"
  scope       = azurerm_resource_group.apps.id
  description = "Read this VM and invoke root-level Run Command for deployment."
  permissions {
    actions = [
      "Microsoft.Compute/virtualMachines/read",
      "Microsoft.Compute/virtualMachines/runCommand/action",
    ]
    not_actions = []
  }
  assignable_scopes = [azurerm_resource_group.apps.id]
}

resource "azurerm_role_assignment" "github" {
  for_each           = var.github_repositories
  scope              = azurerm_linux_virtual_machine.apps.id
  role_definition_id = azurerm_role_definition.github[0].role_definition_resource_id
  principal_id       = azurerm_user_assigned_identity.github[each.key].principal_id
  principal_type     = "ServicePrincipal"
}
