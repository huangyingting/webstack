variable "subscription_id" {
  type        = string
  description = "Global Azure subscription ID."
  validation {
    condition     = can(regex("^[0-9a-fA-F-]{36}$", var.subscription_id))
    error_message = "Supply your Azure subscription UUID."
  }
}

variable "prefix" {
  type        = string
  description = "Unique deployment name, 3-16 lowercase letters/digits/hyphens."
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,14}[a-z0-9]$", var.prefix))
    error_message = "Use a 3-16 character lowercase resource prefix."
  }
}

variable "resource_group_name" {
  type        = string
  description = "Exact Azure application resource group name (1-83 characters). Defaults to <prefix>-rg when null; the backup resource group appends -backup."
  default     = null
  nullable    = true
  validation {
    condition = var.resource_group_name == null ? true : (
      length(var.resource_group_name) >= 1 &&
      length(var.resource_group_name) <= 83 &&
      can(regex("^[A-Za-z0-9_().-]*[A-Za-z0-9_()-]$", var.resource_group_name))
    )
    error_message = "Use a 1-83 character Azure resource group name containing only letters, digits, underscores, parentheses, hyphens, or periods; it cannot end with a period. The derived <name>-backup resource group must fit Azure's 90-character limit."
  }
}

variable "location" {
  type    = string
  default = "southeastasia"
}

variable "vm_size" {
  type    = string
  default = "Standard_D2as_v5"
}

variable "vm_name" {
  type        = string
  description = "Azure VM resource name. Defaults to <prefix>-vm when null."
  default     = null
  nullable    = true
  validation {
    condition = var.vm_name == null || can(regex(
      "^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,62}[A-Za-z0-9_])?$",
      var.vm_name
    ))
    error_message = "Use a 1-64 character Azure VM name without whitespace or a trailing hyphen/period."
  }
}

variable "disk_size_gb" {
  type    = number
  default = 64
  validation {
    condition     = var.disk_size_gb >= 64 && var.disk_size_gb <= 4096 && floor(var.disk_size_gb) == var.disk_size_gb
    error_message = "The OS disk must be an integer between 64 and 4096 GB."
  }
}

variable "data_disk_count" {
  type        = number
  description = "Number of managed disks in the RAID-0 /data array."
  default     = 4
  validation {
    condition     = var.data_disk_count >= 2 && var.data_disk_count <= 4 && floor(var.data_disk_count) == var.data_disk_count
    error_message = "Use 2-4 data disks; the default VM size supports at most four."
  }
}

variable "data_disk_size_gb" {
  type        = number
  description = "Size of each managed data disk; four default disks provide 128GB total."
  default     = 32
  validation {
    condition     = var.data_disk_size_gb >= 32 && var.data_disk_size_gb <= 4096 && floor(var.data_disk_size_gb) == var.data_disk_size_gb
    error_message = "Each data disk must be an integer between 32 and 4096 GB."
  }
}

variable "admin_username" {
  type    = string
  default = "azadmin"
  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]{0,31}$", var.admin_username)) && var.admin_username != "root"
    error_message = "Use a Linux username of 1-32 lowercase characters, digits, underscores, or hyphens; root is not allowed."
  }
}

variable "ssh_port" {
  type        = number
  description = "TCP port used by OpenSSH and allowed from admin_cidr."
  default     = 22222
  validation {
    condition     = var.ssh_port >= 1024 && var.ssh_port <= 65535 && floor(var.ssh_port) == var.ssh_port
    error_message = "Use an unprivileged SSH port between 1024 and 65535."
  }
}

variable "ssh_public_key_path" {
  type        = string
  description = "Fallback path to an existing OpenSSH public key when ssh_public_key is null."
  default     = "~/.ssh/id_ed25519.pub"
}

variable "ssh_public_key" {
  type        = string
  description = "OpenSSH public key text supplied directly at deployment; private keys must never enter Terraform."
  default     = null
  nullable    = true
  validation {
    condition = var.ssh_public_key == null || can(regex(
      "^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)) [A-Za-z0-9+/]+={0,3}( .*)?$",
      trimspace(var.ssh_public_key)
    ))
    error_message = "ssh_public_key must be a supported OpenSSH public key."
  }
}

variable "admin_cidr" {
  type        = string
  description = "IPv4 CIDR allowed to use SSH; 0.0.0.0/0 permits SSH from all IPv4 addresses."
  validation {
    condition     = can(cidrnetmask(var.admin_cidr))
    error_message = "Supply a valid IPv4 CIDR such as 203.0.113.10/32 or 0.0.0.0/0."
  }
}

variable "acme_email" {
  type        = string
  description = "Email used for Let's Encrypt registration."
  validation {
    condition     = can(regex("^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$", var.acme_email))
    error_message = "Supply a valid email address."
  }
}

variable "backup_time_zone" {
  type    = string
  default = "Asia/Shanghai"
  validation {
    condition     = can(regex("^[A-Za-z_/+-]+$", var.backup_time_zone))
    error_message = "Use an IANA timezone such as Asia/Shanghai or UTC."
  }
}

variable "github_repositories" {
  type        = set(string)
  default     = []
  description = "Lowercase owner/repo names allowed to deploy via production-environment OIDC."
  validation {
    condition = length(var.github_repositories) <= 20 && alltrue([
      for repo in var.github_repositories : can(regex("^[a-z0-9_.-]+/[a-z0-9_.-]+$", repo))
    ])
    error_message = "Supply at most 20 lowercase owner/repo names."
  }
}

variable "github_repository_ids" {
  type = map(object({
    owner         = string
    repository    = string
    owner_id      = string
    repository_id = string
  }))
  default     = {}
  description = "Canonical GitHub names and immutable IDs for every repository in github_repositories."
  validation {
    condition = (
      length(var.github_repository_ids) == length(var.github_repositories) &&
      alltrue([
        for repo in var.github_repositories :
        contains(keys(var.github_repository_ids), repo)
      ]) &&
      alltrue([
        for repo, ids in var.github_repository_ids :
        contains(var.github_repositories, repo) &&
        can(regex("^[A-Za-z0-9_.-]+$", ids.owner)) &&
        can(regex("^[A-Za-z0-9_.-]+$", ids.repository)) &&
        lower("${ids.owner}/${ids.repository}") == repo &&
        can(regex("^[1-9][0-9]*$", ids.owner_id)) &&
        can(regex("^[1-9][0-9]*$", ids.repository_id))
      ])
    )
    error_message = "Provide canonical owner/repository names and numeric immutable IDs for every github_repositories entry; lowercase canonical names must match the map key."
  }
}
