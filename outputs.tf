output "deployment" {
  value = {
    AZURE_SUBSCRIPTION_ID  = var.subscription_id
    AZURE_TENANT_ID        = data.azurerm_client_config.current.tenant_id
    AZURE_RESOURCE_GROUP   = azurerm_resource_group.apps.name
    AZURE_VM_NAME          = azurerm_linux_virtual_machine.apps.name
    BACKUP_RESOURCE_GROUP  = azurerm_resource_group.backups.name
    BACKUP_STORAGE_ACCOUNT = azurerm_storage_account.backups.name
    BACKUP_CONTAINER       = azurerm_storage_container.backups.name
    IMPORT_STORAGE_ACCOUNT = azurerm_storage_account.backups.name
    IMPORT_CONTAINER       = azurerm_storage_container.imports.name
    PUBLIC_IP              = azurerm_public_ip.apps.ip_address
    SSH_USER               = var.admin_username
    SSH_PORT               = var.ssh_port
    DATA_MOUNT             = "/data"
    DATA_DISK_TOTAL_GB     = var.data_disk_count * var.data_disk_size_gb
    GITHUB_CLIENT_IDS      = { for repo, identity in azurerm_user_assigned_identity.github : repo => identity.client_id }
    GITHUB_DEPLOYMENTS = {
      for repo, identity in azurerm_user_assigned_identity.github : repo => {
        AZURE_CLIENT_ID = identity.client_id
        OIDC_SUBJECT    = azurerm_federated_identity_credential.github[repo].subject
      }
    }
  }
}

output "bootstrap_config" {
  value = local.backup_config
}
