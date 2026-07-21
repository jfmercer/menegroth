terraform {
  required_version = ">= 1.15.0"

  # State-only backend: the HCP Terraform workspace must have its execution
  # mode set to "Local" so plans/applies run in GitHub Actions, not HCP.
  # The organization comes from the TF_CLOUD_ORGANIZATION environment
  # variable (a GitHub Actions repository variable in CI).
  cloud {
    # organization intentionally omitted — sourced from TF_CLOUD_ORGANIZATION
    # (CI repo variable; bootstrap.env locally). Keeps the org out of source.
    workspaces {
      name = "menegroth"
    }
  }

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.50"
    }
  }
}

# Authentication: the provider reads the HCLOUD_TOKEN environment variable,
# which CI pulls from Infisical (/ci/HCLOUD_TOKEN). Never put the token in
# a tfvars file.
provider "hcloud" {}
