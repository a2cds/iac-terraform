# GLOBAL CONFIG ##############################################################################################################
locals {
    domain = "iac4all.ml"
    prefix = "Treinamento_Azure"
    user   = "treinamento"
    lxhost = "treinamentoazure-iac4allml.iac4all.ml"
}

variable "client_secret" {
}

provider "azurerm" {
  # Whilst version is optional, we /strongly recommend/ using it to pin the version of the Provider being used
  version = "=2.21.0"

  tenant_id       = "6ddad5a1-4a06-4ca2-8793-280616a2b8c6"
  subscription_id = "da28adc6-3f74-4ed3-a6e7-94cf2c48bbd9"
  client_id       = "fd2a530a-e7a2-4118-ba5c-6c234272dce0" # app.application_id
  client_secret   = var.client_secret

  features {}
}

data "azurerm_resource_group" "resgrp" {
  name = local.prefix
}

# LOCAL CONFIG ##############################################################################################################
locals {
    ###################
    person       = "P13"
    ###################
    location     = "westus2"
    sku          = {
        tier     = "Standard"
        size     = "S1"
    }
    plan_kind       = "Linux"
    plan_reserved   = true
    site_config     = {
        always_on   = true
        fx_version  = "DOCKER|nginxdemos/hello:latest"
    }
}

# SERVICES ##############################################################################################################

resource "azurerm_app_service_plan" "plan" {
  name                = local.person
  location            = local.location
  resource_group_name = data.azurerm_resource_group.resgrp.name
  kind                = local.plan_kind
  reserved            = local.plan_reserved

  sku {
    tier = local.sku["tier"]
    size = local.sku["size"]
  }
}

resource "azurerm_app_service" "app" {
  name                = join("",[local.person, "app"])
  location            = local.location
  resource_group_name = data.azurerm_resource_group.resgrp.name
  app_service_plan_id = azurerm_app_service_plan.plan.id

  site_config {
    always_on           = local.site_config["always_on"]
    linux_fx_version    = local.site_config["fx_version"]

    cors {
        allowed_origins = ["*"]
    }
  }
  
  app_settings = {
  }

  identity {
    type = "SystemAssigned"
  }
}

# Solve Message="A TXT record pointing from asuid.p1.iac4all.ml to a251e9dbe7006bce517296167fbe43b0a161ef5abca2025a8b0869d87ecc35a3 was not found.
resource "azurerm_dns_txt_record" "txt" {
  zone_name           = local.domain
  name                = join(".",["asuid", lower(local.person)])
  resource_group_name = data.azurerm_resource_group.resgrp.name
  ttl                 = 300

  record {
    value = "a251e9dbe7006bce517296167fbe43b0a161ef5abca2025a8b0869d87ecc35a3" # <domain-verification-id-from-your-app>
  }
}

resource "azurerm_app_service_custom_hostname_binding" "hostname_binding" {
  hostname            = join(".",[local.person, local.domain])
  app_service_name    = azurerm_app_service.app.name
  resource_group_name = data.azurerm_resource_group.resgrp.name
}

resource "azurerm_dns_a_record" "alias" {
  name                = lower(local.person)
  zone_name           = local.domain
  resource_group_name = data.azurerm_resource_group.resgrp.name
  ttl                 = 300
  records             = split(",", azurerm_app_service.app.outbound_ip_addresses)
}


# CONFIG FILES ##############################################################################################################
data "template_file" "ansible_inventory" {
  template = <<EOF
[web]
$${host} ansible_user=$${user} ansible_become=yes

[web:vars]
ansible_python_interpreter=/usr/bin/python2.7
  EOF

  vars = {
    host  = local.lxhost
    user  = local.user
  }
}

resource "local_file" "ansible_inventory" {
  content     = data.template_file.ansible_inventory.rendered
  filename = "./ansible-inventory.yaml"

  depends_on = [data.template_file.ansible_inventory]
}

data "template_file" "nginx_configuration" {
    template = <<EOF
---
- hosts: all
  tasks:
    - name: Create conf.d
      copy:
        dest: "/etc/nginx/default.d/$${person}.conf"
        content: |
          location /p13 {
            alias /usr/share/nginx/html/$${person};
          }
    - name: Create a directory if it does not exist
      file:
        path: "/usr/share/nginx/html/$${person}"
        state: directory
        mode: '0755'
    - name: Create page
      copy:
        dest: "/usr/share/nginx/html/$${person}/index.html"
        content: |
          <h4>hello $${person}</h4>
    - name: reload nginx
      service:
        name: nginx
        state: reloaded
  EOF

  vars = {
    person  = lower(local.person)
  }
}

resource "local_file" "nginx_configuration" {
  content     = data.template_file.nginx_configuration.rendered
  filename = "./nginx-config.yml"

  depends_on = [data.template_file.nginx_configuration]
}

# ANSIBLE EXEC ##############################################################################################################
### for linux guest version
#resource "null_resource" "configure_nginx" {
#  provisioner "local-exec" {
#    command = "ansible-playbook -i ${local_file.ansible_inventory.filename} --private-key ./vms ${local_file.nginx_configuration.filename}"
#  }
#
#  depends_on = [local_file.ansible_inventory, local_file.nginx_configuration]
#}
### end linux version

### for windows guest version
resource "null_resource" "configure_nginx_sendinv" {
  provisioner "local-exec" {
    command = "scp -i ./vms ${local_file.ansible_inventory.filename} ${local.user}@${local.lxhost}:/home/treinamento"
  }

  depends_on = [local_file.ansible_inventory, local_file.nginx_configuration]
}

resource "null_resource" "configure_nginx_sendyml" {
  provisioner "local-exec" {
    command = "scp -i ./vms ${local_file.nginx_configuration.filename} ${local.user}@${local.lxhost}:/home/treinamento/${local.person}.yml"
  }

  depends_on = [local_file.ansible_inventory, local_file.nginx_configuration]
}

resource "null_resource" "configure_nginx_execute" {
  provisioner "local-exec" {
    command = "ssh -i ./vms ${local.user}@${local.lxhost} ansible-playbook -i /home/treinamento/${local.person}.yml --private-key ./vms ${local_file.nginx_configuration.filename}"
  }

  depends_on = [null_resource.configure_nginx_sendinv, null_resource.configure_nginx_sendyml]
}
### end windows version
