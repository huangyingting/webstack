mock_provider "azurerm" {}
mock_provider "cloudinit" {}

variables {
  subscription_id     = "00000000-0000-0000-0000-000000000001"
  prefix              = "testapps"
  admin_cidr          = "0.0.0.0/0"
  acme_email          = "admin@example.com"
  ssh_public_key_path = "tests/test-key.pub"
  github_repositories = ["owner/app-a", "owner/app-b"]
}

run "infrastructure_contract" {
  command = plan

  variables {
    vm_name = null
  }

  assert {
    condition     = azurerm_linux_virtual_machine.apps.size == "Standard_D2as_v5"
    error_message = "The default must use the available 8GB D-series VM."
  }
  assert {
    condition     = azurerm_linux_virtual_machine.apps.name == "testapps-vm"
    error_message = "The VM name must default from the deployment prefix."
  }
  assert {
    condition     = azurerm_linux_virtual_machine.apps.admin_username == "azadmin"
    error_message = "The default Linux administrator must be azadmin."
  }
  assert {
    condition = (
      length(azurerm_managed_disk.data) == 4 &&
      alltrue([for disk in azurerm_managed_disk.data : disk.disk_size_gb == 32]) &&
      alltrue([for attachment in azurerm_virtual_machine_data_disk_attachment.data : attachment.caching == "None"])
    )
    error_message = "The default /data array must use four uncached 32GB managed disks."
  }
  assert {
    condition     = azurerm_linux_virtual_machine.apps.identity[0].type == "UserAssigned"
    error_message = "Backups must use managed identity."
  }
  assert {
    condition     = azurerm_storage_account.backups.shared_access_key_enabled == false && azurerm_storage_account.backups.allow_nested_items_to_be_public == false
    error_message = "Backups must not allow shared keys or anonymous access."
  }
  assert {
    condition     = azurerm_resource_group.apps.name != azurerm_resource_group.backups.name
    error_message = "Backups must be in a separate resource group."
  }
  assert {
    condition = (
      azurerm_network_security_rule.ssh.source_address_prefix == "0.0.0.0/0" &&
      azurerm_network_security_rule.ssh.destination_port_range == "22222" &&
      azurerm_network_security_rule.web.destination_port_ranges == toset(["80", "443"]) &&
      azurerm_network_security_rule.subnet_ssh.destination_port_range == "22222" &&
      azurerm_network_security_rule.subnet_web.destination_port_ranges == toset(["80", "443"]) &&
      azurerm_network_security_rule.deny_other.access == "Deny"
    )
    error_message = "Only explicit web and SSH ingress are permitted."
  }
  assert {
    condition = alltrue([
      for rule in azurerm_storage_management_policy.backups.rule :
      rule.actions[0].base_blob[0].delete_after_days_since_modification_greater_than == (rule.name == "expire-daily" ? 7 : 112)
    ])
    error_message = "Daily and weekly lifecycle expiry must be 7 and 112 days."
  }
  assert {
    condition     = length(azurerm_user_assigned_identity.github) == 2
    error_message = "Each repository must have a separate deployment identity."
  }
  assert {
    condition     = azurerm_federated_identity_credential.github["owner/app-a"].subject == "repo:owner/app-a:environment:production"
    error_message = "GitHub identity must be bound to the production environment."
  }
}

run "deployment_inputs" {
  command = plan

  variables {
    vm_name        = "customer-vm-01"
    ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGPkHryBsnZb2lAl6wS9STK8LOXU4DgC2rCsmJxRtJpM deploy@example.com"
  }

  assert {
    condition     = azurerm_linux_virtual_machine.apps.name == "customer-vm-01"
    error_message = "The caller must be able to set the exact Azure VM name."
  }
  assert {
    condition     = one(azurerm_linux_virtual_machine.apps.admin_ssh_key).public_key == "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGPkHryBsnZb2lAl6wS9STK8LOXU4DgC2rCsmJxRtJpM deploy@example.com"
    error_message = "A directly supplied SSH public key must be installed on the VM."
  }
}
